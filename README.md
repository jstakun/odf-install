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
    └── verify-odf.sh                 # End-to-end health check and validation script
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
