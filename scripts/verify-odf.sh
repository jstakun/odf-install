#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration from .env if present
if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=== 1. Checking StorageCluster and CephCluster Status ==="
oc get storagecluster -n openshift-storage
echo ""
oc get cephcluster -n openshift-storage
echo ""

echo "=== 2. Checking Ceph Health ==="
ROOK_OPERATOR_POD=$(oc get pod -l app=rook-ceph-operator -n openshift-storage -o jsonpath='{.items[0].metadata.name}')
oc exec "$ROOK_OPERATOR_POD" -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring status
echo ""

echo "=== 3. Checking Ceph Network Settings ==="
oc exec "$ROOK_OPERATOR_POD" -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring config dump | grep network
echo ""

echo "=== 4. Checking OSD IP Addresses (Network Isolation) ==="
oc exec "$ROOK_OPERATOR_POD" -n openshift-storage -- ceph -c /var/lib/rook/openshift-storage/openshift-storage.config --keyring /var/lib/rook/openshift-storage/client.admin.keyring osd dump | grep ^osd
echo ""

echo "=== 5. Checking StorageClasses ==="
oc get sc | grep -E "ocs|odf"
echo ""

wait_for_pod_completion() {
  local pod_name="$1"
  local ns="$2"
  local timeout="${3:-60}"
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    phase=$(oc get pod "$pod_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

echo "=== 6. Running Verification Test (RBD & CephFS) ==="
oc apply -f "${REPO_ROOT}/manifests/05-test-pvc-rbd.yaml"
wait_for_pod_completion "test-rbd-pod" "default" 60 || true
oc logs test-rbd-pod -n default
oc delete -f "${REPO_ROOT}/manifests/05-test-pvc-rbd.yaml"

oc apply -f "${REPO_ROOT}/manifests/06-test-pvc-cephfs.yaml"
wait_for_pod_completion "test-cephfs-pod" "default" 60 || true
oc logs test-cephfs-pod -n default
oc delete -f "${REPO_ROOT}/manifests/06-test-pvc-cephfs.yaml"

echo "=== Verification Complete ==="
