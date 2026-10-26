#!/usr/bin/env bash
set -euo pipefail

# Infrastructure Preparation Script for ODF on AWS OpenShift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration from .env if present
if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
CLUSTER_INFRA_ID="${CLUSTER_INFRA_ID:?Error: CLUSTER_INFRA_ID must be set in .env or environment}"
VPC_ID="${VPC_ID:-}"
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

export AWS_PROFILE
export AWS_REGION
export KUBECONFIG

echo "=== 1. Finding Cluster Instances ==="
MASTER_0=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${CLUSTER_INFRA_ID}-master-0" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
MASTER_1=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${CLUSTER_INFRA_ID}-master-1" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
MASTER_2=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${CLUSTER_INFRA_ID}-master-2" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)

echo "Master 0: $MASTER_0"
echo "Master 1: $MASTER_1"
echo "Master 2: $MASTER_2"

echo "=== 2. Creating and Attaching 100GB gp3 EBS Volumes ==="
# Zone eu-central-1a
VOL_0=$(aws ec2 create-volume --availability-zone "${AWS_REGION}a" --volume-type gp3 --size 100 --encrypted --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${CLUSTER_INFRA_ID}-odf-vol-0},{Key=kubernetes.io/cluster/${CLUSTER_INFRA_ID},Value=owned}]" --query "VolumeId" --output text)
echo "Created volume $VOL_0 in ${AWS_REGION}a"
aws ec2 wait volume-available --volume-ids "$VOL_0"
aws ec2 attach-volume --volume-id "$VOL_0" --instance-id "$MASTER_0" --device /dev/sdb

# Zone eu-central-1b
VOL_1=$(aws ec2 create-volume --availability-zone "${AWS_REGION}b" --volume-type gp3 --size 100 --encrypted --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${CLUSTER_INFRA_ID}-odf-vol-1},{Key=kubernetes.io/cluster/${CLUSTER_INFRA_ID},Value=owned}]" --query "VolumeId" --output text)
echo "Created volume $VOL_1 in ${AWS_REGION}b"
aws ec2 wait volume-available --volume-ids "$VOL_1"
aws ec2 attach-volume --volume-id "$VOL_1" --instance-id "$MASTER_1" --device /dev/sdb

# Zone eu-central-1c
VOL_2=$(aws ec2 create-volume --availability-zone "${AWS_REGION}c" --volume-type gp3 --size 100 --encrypted --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${CLUSTER_INFRA_ID}-odf-vol-2},{Key=kubernetes.io/cluster/${CLUSTER_INFRA_ID},Value=owned}]" --query "VolumeId" --output text)
echo "Created volume $VOL_2 in ${AWS_REGION}c"
aws ec2 wait volume-available --volume-ids "$VOL_2"
aws ec2 attach-volume --volume-id "$VOL_2" --instance-id "$MASTER_2" --device /dev/sdb

echo "=== 3. Labeling Nodes in OpenShift ==="
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  oc label node "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite
  oc label node "$node" node-role.kubernetes.io/storage="" --overwrite
done

echo "Infrastructure preparation completed successfully."
