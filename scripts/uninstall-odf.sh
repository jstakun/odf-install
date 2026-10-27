#!/usr/bin/env bash
set -euo pipefail

# Script to completely uninstall and wipe ODF and Local Storage
# for a clean reinstallation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

FORCE="${1:-}"

if [ "$FORCE" != "--force" ]; then
  echo "==================================================================="
  echo "WARNING: This script will completely uninstall ODF and Rook-Ceph,"
  echo "delete all storage data, wipe disks on all nodes, and clear /var/lib/rook."
  echo "==================================================================="
  read -rp "Type 'yes' to proceed with complete uninstallation: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "=== 1. Deleting StorageCluster ==="
if oc get storagecluster ocs-storagecluster -n openshift-storage &>/dev/null; then
  oc delete storagecluster ocs-storagecluster -n openshift-storage --wait=false || true
  echo "Waiting up to 60s for StorageCluster deletion..."
  for _ in {1..12}; do
    if ! oc get storagecluster ocs-storagecluster -n openshift-storage &>/dev/null; then
      break
    fi
    sleep 5
  done

  # Force-remove finalizers if still stuck
  if oc get storagecluster ocs-storagecluster -n openshift-storage &>/dev/null; then
    echo "Patching finalizers on stuck StorageCluster..."
    oc patch storagecluster ocs-storagecluster -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' || true
  fi
fi

# Remove finalizers on CephCluster if lingering
if oc get cephcluster ocs-storagecluster-cephcluster -n openshift-storage &>/dev/null; then
  echo "Patching finalizers on CephCluster..."
  oc patch cephcluster ocs-storagecluster-cephcluster -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' || true
  oc delete cephcluster ocs-storagecluster-cephcluster -n openshift-storage --wait=false || true
fi

# Remove finalizers on NooBaa resources if lingering
for cr in noobaa backingstore bucketclass; do
  for res in $(oc get "$cr" -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc patch "$cr" "$res" -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    oc delete "$cr" "$res" -n openshift-storage --wait=false 2>/dev/null || true
  done
done

# Remove finalizers on dependent Ceph and CSI-Addons resources
for crd in clientprofiles.csi.ceph.io csiaddonsnodes.csiaddons.openshift.io storageconsumers.ocs.openshift.io cephblockpools.ceph.rook.io cephfilesystems.ceph.rook.io cephblockpoolradosnamespaces.ceph.rook.io cephfilesystemsubvolumegroups.ceph.rook.io cephclients.ceph.rook.io; do
  for item in $(oc get "$crd" -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc patch "$crd" "$item" -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    oc delete "$crd" "$item" -n openshift-storage --wait=false 2>/dev/null || true
  done
done

# Strip lingering finalizers on storage configmaps and secrets
for res in configmaps secrets; do
  for item in $(oc get "$res" -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc patch "$res" "$item" -n openshift-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  done
done

# Delete ODF storage classes
oc delete sc ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs --ignore-not-found 2>/dev/null || true

echo "=== 2. Deleting ODF Operator ==="
oc delete subscription odf-operator -n openshift-storage 2>/dev/null || true
for csv in $(oc get csv -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  oc delete csv "$csv" -n openshift-storage || true
done
oc delete operatorgroup openshift-storage-operatorgroup -n openshift-storage 2>/dev/null || true

echo "=== 3. Deleting LocalVolumeSet and Local PVs ==="
if oc get localvolumeset odf-localvolumeset -n openshift-local-storage &>/dev/null; then
  oc delete localvolumeset odf-localvolumeset -n openshift-local-storage --wait=false || true
  sleep 5
  oc patch localvolumeset odf-localvolumeset -n openshift-local-storage --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
fi

for pv in $(oc get pv -l storage.openshift.com/local-volume-owner-name=odf-localvolumeset -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  oc patch pv "$pv" --type=json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
  oc delete pv "$pv" 2>/dev/null || true
done

echo "=== 4. Deleting Local Storage Operator ==="
oc delete subscription local-storage-operator -n openshift-local-storage 2>/dev/null || true
for csv in $(oc get csv -n openshift-local-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  oc delete csv "$csv" -n openshift-local-storage || true
done
oc delete operatorgroup local-operator-group -n openshift-local-storage 2>/dev/null || true

echo "=== 5. Deleting Namespaces ==="
oc delete ns openshift-storage --wait=false 2>/dev/null || true
oc delete ns openshift-local-storage --wait=false 2>/dev/null || true

echo "=== 6. Wiping Disks and /var/lib/rook on Storage Nodes ==="
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $NODES; do
  echo "--- Cleaning node: $node ---"
  oc debug "node/${node}" -- chroot /host /bin/bash -c '
    set -x
    # Identify 100G non-root disk (nvme1n1)
    TARGET_DEV="/dev/nvme1n1"
    if [ -b "$TARGET_DEV" ]; then
      DEV_SIZE=$(lsblk -b -n -o SIZE "$TARGET_DEV" | head -n1)
      # 100 GB is approx 107374182400 bytes
      if [ "$DEV_SIZE" -gt 90000000000 ] && [ "$DEV_SIZE" -lt 120000000000 ]; then
        echo "Wiping $TARGET_DEV ($DEV_SIZE bytes)..."
        sgdisk --zap-all "$TARGET_DEV" || true
        wipefs -a -f "$TARGET_DEV" || true
        dd if=/dev/zero of="$TARGET_DEV" bs=1M count=100 oflag=direct || true
      else
        echo "Skipping $TARGET_DEV: unexpected size $DEV_SIZE"
      fi
    else
      echo "Device $TARGET_DEV not found, checking sdb..."
      if [ -b "/dev/sdb" ]; then
        sgdisk --zap-all /dev/sdb || true
        wipefs -a -f /dev/sdb || true
        dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct || true
      fi
    fi

    # Clean host data dir
    echo "Clearing /var/lib/rook..."
    rm -rf /var/lib/rook/*
  '
done

echo ""
echo "=== Uninstallation and Disk Wipe Complete ==="
echo "The cluster is ready for a fresh ODF installation."
echo "Follow Steps 1-6 in README.md to reinstall."
