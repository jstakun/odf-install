# OpenShift Data Foundation (ODF) Installation on AWS with Dedicated Storage Network

This repository contains the architecture, step-by-step procedures, helper scripts, and Kubernetes manifests used to deploy **OpenShift Data Foundation (ODF 4.22)** on a 3-node compact OpenShift cluster running on AWS, isolating Ceph backend storage traffic to a dedicated Multus secondary network (`odf-network`).

---

## 1. Architecture Overview

### Cluster Topology
- **Cloud Provider**: AWS (`eu-central-1`)
- **AWS Profile**: `ocp4-rht`
- **Cluster Architecture**: 3-node compact cluster (control-plane and worker combined on each node)
- **Node Instance Type**: `m6i.2xlarge` (8 vCPU, 32 GiB RAM per node)
- **Nodes & Zones**:
  - `master-0` (`ip-10-0-19-191.eu-central-1.compute.internal` in `eu-central-1a`)
  - `master-1` (`ip-10-0-40-213.eu-central-1.compute.internal` in `eu-central-1b`)
  - `master-2` (`ip-10-0-82-237.eu-central-1.compute.internal` in `eu-central-1c`)

```
                          AWS VPC (10.0.0.0/16)
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      OpenShift Cluster (SDN 10.128.0.0/14)             │
 │                                                                        │
 │  Node 0 (eu-central-1a)      Node 1 (eu-central-1b)      Node 2 (eu-central-1c) │
 │  ┌───────────────────┐      ┌───────────────────┐      ┌───────────────────┐ │
 │  │ 100 GB EBS (sdb)  │      │ 100 GB EBS (sdb)  │      │ 100 GB EBS (sdb)  │ │
 │  │        │          │      │        │          │      │        │          │ │
 │  │  rook-ceph-osd-0  │      │  rook-ceph-osd-1  │      │  rook-ceph-osd-2  │ │
 │  └────────┬──────────┘      └────────┬──────────┘      └────────┬──────────┘ │
 │           │                          │                          │            │
 │           └──────────────────────────┼──────────────────────────┘            │
 │                                      ▼                                       │
 │              =================================================               │
 │                 odf-network: OVN Layer-2 Overlay (10.200.0.0/24)             │
 │                 (OSD Backend Data Replication, Heartbeat, Recovery)          │
 │              =================================================               │
 └────────────────────────────────────────────────────────────────────────┘
```

### Storage Backend
- **EBS gp3 Disks**: 3x 100 GB encrypted volumes attached to `/dev/sdb` (OS kernel device `/dev/nvme1n1`).
- **Local Storage Operator (LSO)**: Discovers `/dev/sdb` and exposes raw block PersistentVolumes with `StorageClass: odf-local-storage`.
- **Ceph OSDs**: 3 OSD daemons consuming the 3 local block PVs across the 3 availability zones.

### Network Architecture: `odf-network`
- **Secondary Network Plugin**: Multus with `ovn-k8s-cni-overlay` (Layer 2 topology, CIDR `10.200.0.0/24`).
- **Configuration in StorageCluster Manifest** ([`manifests/04-odf-storagecluster.yaml`](file:///home/jstakun/git/odf-install/manifests/04-odf-storagecluster.yaml)):
  ```yaml
  spec:
    network:
      provider: multus
      selectors:
        cluster: openshift-storage/odf-network
      addressRanges:
        cluster:
          - 10.200.0.0/24
        public:
          - 10.128.0.0/14
  ```

| Manifest Field | Ceph Config Directive | Target Network | Purpose |
|---|---|---|---|
| **`selectors.cluster`** | `k8s.v1.cni.cncf.io/networks` annotation | `openshift-storage/odf-network` | Instructs Rook to attach the secondary network interface (`net1`) to OSD pods via Multus. |
| **`addressRanges.cluster`** | `cluster_network` | `10.200.0.0/24` | Ceph binds its backend replication, backfill, recovery, and heartbeat listening ports (`6800`/`6801` on `net1`) exclusively to this subnet. |
| **`addressRanges.public`** | `public_network` | `10.128.0.0/14` *(OpenShift Pod SDN)* | Ceph binds client/frontend listening ports to the routable cluster SDN so host-level Ceph-CSI drivers and client pods can communicate with OSDs. |

> [!IMPORTANT]
> **Why `selectors.public` is omitted**:
> In cloud overlay networking (OVN-Kubernetes on AWS), a secondary overlay network (`ovn-k8s-cni-overlay`) creates interfaces only inside pod network namespaces. The EC2 host nodes themselves have no routing into `10.200.0.0/24`. 
> Because Ceph-CSI node drivers (`csi-rbdplugin`) run in the host network namespace to execute kernel-level volume mounts (`rbd map`), setting `selectors.public` to `odf-network` isolates OSD client ports onto an unreachable overlay subnet, causing `MountVolume.MountDevice` / `NodeStageVolume` timeout errors. Omitting `selectors.public` ensures that Ceph client endpoints remain on the routable cluster SDN while backend data replication is strictly isolated to `odf-network`.

---

## 2. Directory Structure

```
/home/jstakun/git/odf-install/
├── .env.example                  # Template for environment-specific variables
├── README.md
├── manifests/
│   ├── 00-odf-network.yaml           # Multus NetworkAttachmentDefinition (odf-network)
│   ├── 01-lso-operator.yaml          # Local Storage Operator Subscription & OperatorGroup
│   ├── 02-lso-localvolumeset.yaml    # LocalVolumeSet discovering 100 GB EBS disks
│   ├── 03-odf-operator.yaml          # ODF Operator Subscription & OperatorGroup
│   ├── 04-odf-storagecluster.yaml    # Production StorageCluster CR on odf-network
│   ├── 05-test-pvc-rbd.yaml          # Ceph RBD test PVC and consumer Pod
│   └── 06-test-pvc-cephfs.yaml       # CephFS test PVC (RWX) and consumer Pod
└── scripts/
    ├── prepare-aws-infrastructure.sh # AWS CLI automation for EBS volumes & node labeling
    ├── verify-odf.sh                 # End-to-end health check and validation script
    └── uninstall-odf.sh              # Teardown and disk wipe automation for clean reinstall
```

---

## 3. Step-by-Step Installation Procedure

### Step 0: Environment Configuration
Copy the sample environment file and adjust the parameters for your cluster:

```bash
cp .env.example .env
```

Edit `.env` to supply:
- `AWS_PROFILE`: AWS CLI profile with EC2 volume management permissions.
- `AWS_REGION`: AWS region of the cluster (e.g. `eu-central-1`).
- `CLUSTER_INFRA_ID`: OpenShift infrastructure ID (e.g. `ailabs-wkrxf`).
- `VPC_ID`: AWS VPC ID.
- `KUBECONFIG`: Absolute path to cluster kubeconfig.

### Step 1: AWS Infrastructure Preparation
Attach 100 GB EBS `gp3` volumes to each cluster node and label the nodes for storage:

```bash
# Automated via script:
./scripts/prepare-aws-infrastructure.sh
```

Or execute manually:
1. Create 3x 100 GB `gp3` volumes in `eu-central-1a`, `eu-central-1b`, and `eu-central-1c`.
2. Attach each volume to the respective master instance at device `/dev/sdb`.
3. Label all 3 nodes in OpenShift:
   ```bash
   oc label node <node-name> cluster.ocs.openshift.io/openshift-storage="" --overwrite
   oc label node <node-name> node-role.kubernetes.io/storage="" --overwrite
   ```

### Step 2: Deploy Dedicated Storage Network
Apply [`manifests/00-odf-network.yaml`](file:///home/jstakun/git/odf-install/manifests/00-odf-network.yaml) to configure the Multus secondary overlay network:

```bash
oc apply -f manifests/00-odf-network.yaml
```

### Step 3: Install Local Storage Operator (LSO)
Apply [`manifests/01-lso-operator.yaml`](file:///home/jstakun/git/odf-install/manifests/01-lso-operator.yaml) to install the Local Storage Operator in `openshift-local-storage`:

```bash
oc apply -f manifests/01-lso-operator.yaml
```

Wait until the CSV reaches `Succeeded`:
```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/local-storage-operator.openshift-local-storage -n openshift-local-storage --timeout=300s
```

### Step 4: Discover Local Disks & Create PVs
Apply [`manifests/02-lso-localvolumeset.yaml`](file:///home/jstakun/git/odf-install/manifests/02-lso-localvolumeset.yaml) to claim the 100 GB disks:

```bash
oc apply -f manifests/02-lso-localvolumeset.yaml
```

Verify that 3 local block PersistentVolumes have been created:
```bash
oc get pv -l storage.openshift.com/local-volume-owner-name=odf-localvolumeset
```

### Step 5: Install OpenShift Data Foundation Operator
Apply [`manifests/03-odf-operator.yaml`](file:///home/jstakun/git/odf-install/manifests/03-odf-operator.yaml) to install ODF in `openshift-storage`:

```bash
oc apply -f manifests/03-odf-operator.yaml
```

Wait until the ODF and Rook-Ceph CSVs reach `Succeeded`:
```bash
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/odf-operator.openshift-storage -n openshift-storage --timeout=300s
```

### Step 6: Deploy ODF StorageCluster
Apply [`manifests/04-odf-storagecluster.yaml`](file:///home/jstakun/git/odf-install/manifests/04-odf-storagecluster.yaml) to deploy Ceph and NooBaa:

```bash
oc apply -f manifests/04-odf-storagecluster.yaml
```

> [!NOTE]
> On a 3-node compact cluster, control-plane components and storage run co-located. The manifest tunes CPU requests (`osd: 500m`, `mds: 250m`, `mgr: 250m`, `mon: 250m`) to prevent scheduler CPU exhaustion while maintaining production reliability.

Wait until `StorageCluster` reaches `Ready`:
```bash
oc wait --for=jsonpath='{.status.phase}'=Ready storagecluster/ocs-storagecluster -n openshift-storage --timeout=600s
```

---

## 4. Verification and Health Checks

Execute the comprehensive automated verification script:
```bash
./scripts/verify-odf.sh
```

### 1. Ceph Status Check
```bash
oc exec $(oc get pod -l app=rook-ceph-operator -n openshift-storage -o jsonpath='{.items[0].metadata.name}') -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring status
```
**Expected Output:**
- `health: HEALTH_OK`
- `mon: 3 daemons, quorum a,b,c`
- `mgr: a(active), standbys: b`
- `mds: 1/1 daemons up, 1 hot standby`
- `osd: 3 osds: 3 up, 3 in`
- `volumes: 1/1 healthy`
- `pgs: 97 active+clean`

### 2. Ceph Network Configuration Verification
```bash
oc exec $(oc get pod -l app=rook-ceph-operator -n openshift-storage -o jsonpath='{.items[0].metadata.name}') -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring config dump | grep network
```
**Verified Output:**
```
global  advanced  cluster_network  10.200.0.0/24
global  advanced  public_network   10.128.0.0/14
```

### 3. OSD IP Network Isolation Verification
```bash
oc exec $(oc get pod -l app=rook-ceph-operator -n openshift-storage -o jsonpath='{.items[0].metadata.name}') -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring osd dump | grep ^osd
```
**Verified Output:**
```
osd.0 up in weight 1 ... [v2:10.130.1.2:6800,v1:10.130.1.2:6801] [v2:10.200.0.69:6800,v1:10.200.0.69:6801]
osd.1 up in weight 1 ... [v2:10.128.0.209:6800,v1:10.128.0.209:6801] [v2:10.200.0.71:6800,v1:10.200.0.71:6801]
osd.2 up in weight 1 ... [v2:10.129.0.224:6800,v1:10.129.0.224:6801] [v2:10.200.0.72:6800,v1:10.200.0.72:6801]
```
- First address: Public frontend port on cluster SDN (`10.128.0.0/14`).
- Second address: Dedicated backend cluster network on `odf-network` (`10.200.0.0/24`).

### 4. Dynamic Provisioning Test (RBD & CephFS)

#### Ceph RBD (Block / ReadWriteOnce)
```bash
oc apply -f manifests/05-test-pvc-rbd.yaml
oc wait --for=condition=Ready pod/test-rbd-pod -n default --timeout=60s
oc logs test-rbd-pod -n default
```
**Output:**
```
Writing test data to Ceph RBD...
Reading test data back:
ODF Verification - Ceph RBD on odf-network: Mon Oct 26 12:24:36 UTC 2026
RBD TEST SUCCESS
```

#### CephFS (Shared Filesystem / ReadWriteMany)
```bash
oc apply -f manifests/06-test-pvc-cephfs.yaml
oc wait --for=condition=Ready pod/test-cephfs-pod -n default --timeout=60s
oc logs test-cephfs-pod -n default
```
**Output:**
```
Writing test data to CephFS...
Reading test data back:
ODF Verification - CephFS on odf-network: Mon Oct 26 12:25:05 UTC 2026
CEPHFS TEST SUCCESS
```

---

## 5. Storage Classes Summary

| StorageClass Name | Provisioner | VolumeMode | AccessModes | Description |
|---|---|---|---|---|
| `ocs-storagecluster-ceph-rbd` | `openshift-storage.rbd.csi.ceph.com` | Filesystem, Block | ReadWriteOnce | Ceph Block Device for high-performance workloads |
| `ocs-storagecluster-cephfs` | `openshift-storage.cephfs.csi.ceph.com` | Filesystem | ReadWriteMany, ReadWriteOnce | Ceph Shared Filesystem for multi-pod access |
| `odf-local-storage` | `kubernetes.io/no-provisioner` | Block | ReadWriteOnce | Underlying 100 GB raw EBS volumes provisioned by LSO |
| `gp3-csi` | `ebs.csi.aws.com` | Filesystem | ReadWriteOnce | AWS EBS backing NooBaa Multi-Cloud Gateway PostgreSQL |

---

## 6. ODF Uninstallation & Reinstallation Guide

If you need to redeploy ODF from scratch, simply deleting the `StorageCluster` or uninstalling the operators is **insufficient**. Reinstallation requires a complete teardown and disk/node wipe:

> [!CAUTION]
> **Why Node, Disk, and CR Wiping is Mandatory Before Reinstalling:**
> 1. **Ceph BlueStore Signatures on EBS Disks**: Ceph writes proprietary metadata and signatures across raw block devices (`/dev/nvme1n1`). Standard `wipefs` and simple `dd` do not clear all internal BlueStore superblocks. OSD prepare jobs will detect previous metadata and fail with `belonging to a different ceph cluster`. Reliable removal requires `ceph-volume lvm zap --destroy <dev>` inside the cached RHCeph container.
> 2. **Cluster-Scoped `StorageClient` Resource**: In ODF 4.16+ / 4.22, the internal architecture uses a client-provider model. The `StorageClient` custom resource (`ocs-storagecluster`) is **cluster-scoped** (non-namespaced). It holds the UUID of the internal `StorageConsumer`. If this resource is not deleted during teardown, the newly installed `ocs-client-operator` attempts to contact the old cluster UUID, failing with `rpc error: code = Internal desc = failed to get StorageConsumer`, which prevents the creation of the `ocs-storagecluster-ceph-rbd` and `ocs-storagecluster-cephfs` StorageClasses.
> 3. **Monitor State in `/var/lib/rook`**: Host nodes retain Ceph monitor maps, keys, and old cluster FSIDs in `/var/lib/rook`. If this directory is not deleted, newly deployed MONs will attempt to join the old non-existent cluster and fail quorum.
> 4. **Kubernetes Finalizers & Leases**: Resources such as `StorageCluster`, `CephCluster`, `NooBaa`, and CSI coordination leases block namespace deletion or stall controller leader elections if daemons are terminated unexpectedly.

---

### Option A: Automated Teardown & Wipe

Run the automated uninstallation script ([`scripts/uninstall-odf.sh`](file:///home/jstakun/git/odf-install/scripts/uninstall-odf.sh)):

```bash
./scripts/uninstall-odf.sh
```

To run unattended without an interactive confirmation prompt:
```bash
./scripts/uninstall-odf.sh --force
```

This script automatically:
1. Deletes `StorageCluster`, `CephCluster`, and NooBaa resources (clearing any stuck finalizers).
2. Deletes the ODF operator, CSVs, and OperatorGroup in `openshift-storage`.
3. Deletes `LocalVolumeSet`, local PersistentVolumes, and the Local Storage Operator in `openshift-local-storage`.
4. Spawns debug sessions on each storage node to safely wipe `/dev/nvme1n1` (`sgdisk --zap-all`, `wipefs -a -f`, zeroing the first 100 MB) and removes `/var/lib/rook/*`.
5. Removes the `openshift-storage` and `openshift-local-storage` namespaces.

---

### Option B: Step-by-Step Manual Teardown & Wipe

If you prefer to perform each step manually:

#### 1. Delete Application PVCs
Ensure no consumer workloads or PVCs in user namespaces are using `ocs-storagecluster-ceph-rbd` or `ocs-storagecluster-cephfs`:
```bash
oc delete pvc test-rbd-pvc test-cephfs-pvc -n default --ignore-not-found
```

#### 2. Delete StorageCluster and Ceph Resources
```bash
oc delete storagecluster ocs-storagecluster -n openshift-storage --wait=false
```

If the deletion gets stuck on finalizers:
```bash
# Patch StorageCluster finalizer
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]'

# Patch CephCluster finalizer if present
oc patch cephcluster ocs-storagecluster-cephcluster -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]'

# Patch NooBaa finalizers if present
for cr in noobaa backingstore bucketclass; do
  for res in $(oc get "$cr" -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc patch "$cr" "$res" -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  done
done

# Strip finalizers and delete cluster-scoped StorageClient
for item in $(oc get storageclient -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  oc patch storageclient "$item" --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  oc delete storageclient "$item" --wait=false 2>/dev/null || true
done

# Strip lingering finalizers on storage configmaps, secrets, and leases
for res in configmaps secrets; do
  for item in $(oc get "$res" -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc patch "$res" "$item" -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  done
done
oc delete lease -n openshift-storage --all 2>/dev/null || true
oc delete sc ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs --ignore-not-found 2>/dev/null || true
```

#### 3. Uninstall ODF Operator
```bash
oc delete subscription odf-operator -n openshift-storage
for csv in $(oc get csv -n openshift-storage -o jsonpath='{.items[*].metadata.name}'); do
  oc delete csv "$csv" -n openshift-storage
done
oc delete operatorgroup openshift-storage-operatorgroup -n openshift-storage
```

#### 4. Delete LocalVolumeSet & Local PVs
```bash
oc delete localvolumeset odf-localvolumeset -n openshift-local-storage --wait=false
oc patch localvolumeset odf-localvolumeset -n openshift-local-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true

# Delete lingering local PVs
for pv in $(oc get pv -l storage.openshift.com/local-volume-owner-name=odf-localvolumeset -o jsonpath='{.items[*].metadata.name}'); do
  oc patch pv "$pv" --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  oc delete pv "$pv"
done
```

#### 5. Uninstall Local Storage Operator
```bash
oc delete subscription local-storage-operator -n openshift-local-storage
for csv in $(oc get csv -n openshift-local-storage -o jsonpath='{.items[*].metadata.name}'); do
  oc delete csv "$csv" -n openshift-local-storage
done
oc delete operatorgroup local-operator-group -n openshift-local-storage
```

#### 6. Delete Storage Namespaces
```bash
oc delete ns openshift-storage openshift-local-storage --wait=false
```

#### 7. Wipe Disks and Host Directories on All Nodes
Run the following wipe sequence across every storage node (`master-0`, `master-1`, `master-2`):

```bash
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== Wiping storage on $node ==="
  oc debug "node/${node}" -- chroot /host /bin/bash -c '
    TARGET_DEV="/dev/nvme1n1"
    if [ -b "$TARGET_DEV" ]; then
      # Completely zap Ceph BlueStore signatures using rhceph container
      CEPH_IMG=$(crictl images -o json 2>/dev/null | jq -r ".images[].repoTags[]? | select(test(\"rhceph\"))" | head -n1 || true)
      if [ -n "$CEPH_IMG" ]; then
        podman run --rm --privileged -v /dev:/dev -v /run/udev:/run/udev "$CEPH_IMG" ceph-volume lvm zap --destroy "$TARGET_DEV" || true
      fi
      sgdisk --zap-all "$TARGET_DEV" || true
      wipefs -a -f "$TARGET_DEV" || true
      dd if=/dev/zero of="$TARGET_DEV" bs=1M count=100 oflag=direct status=none || true
      DEV_BLOCKS=$(blockdev --getsz "$TARGET_DEV" 2>/dev/null || echo 0)
      if [ "$DEV_BLOCKS" -gt 204800 ]; then
        dd if=/dev/zero of="$TARGET_DEV" bs=512 seek=$((DEV_BLOCKS - 204800)) count=204800 oflag=direct status=none || true
      fi
    fi
    # Delete host rook data directory
    rm -rf /var/lib/rook/*
  '
done
```

---

### Step-by-Step Reinstallation Procedure

Once the teardown and wiping steps above are finished, the cluster is in a clean baseline state. Follow the standard installation sequence:

1. **Deploy Dedicated Network**:
   ```bash
   oc apply -f manifests/00-odf-network.yaml
   ```

2. **Deploy Local Storage Operator**:
   ```bash
   oc apply -f manifests/01-lso-operator.yaml
   oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/local-storage-operator.openshift-local-storage -n openshift-local-storage --timeout=300s
   ```

3. **Discover Disks & Create Local PVs**:
   ```bash
   oc apply -f manifests/02-lso-localvolumeset.yaml
   # Verify all 3 PVs appear in Available or Released state
   oc get pv -l storage.openshift.com/local-volume-owner-name=odf-localvolumeset
   ```

4. **Deploy ODF Operator**:
   ```bash
   oc apply -f manifests/03-odf-operator.yaml
   oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/odf-operator.openshift-storage -n openshift-storage --timeout=300s
   ```

5. **Deploy StorageCluster on `odf-network`**:
   ```bash
   oc apply -f manifests/04-odf-storagecluster.yaml
   oc wait --for=jsonpath='{.status.phase}'=Ready storagecluster/ocs-storagecluster -n openshift-storage --timeout=600s
   ```

6. **Validate Deployment**:
   ```bash
   ./scripts/verify-odf.sh
   ```
