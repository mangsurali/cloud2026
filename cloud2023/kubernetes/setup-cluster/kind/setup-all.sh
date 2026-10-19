#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

SUPPORTING_DIR="${SCRIPT_DIR}/../supporting"

. "${SUPPORTING_DIR}/variables.sh"

CLUSTER_NAME="mylab99"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()
{
    echo
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN} Step $1: $2${NC}"
    echo "${GREEN}============================================================${NC}"
    echo
}

fail()
{
    echo "${RED}ERROR: $1${NC}" >&2
    exit 1
}

echo "${YELLOW}Checking prerequisites...${NC}"
for cmd in kind kubectl helm curl docker; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        fail "'${cmd}' not found in PATH"
    fi
done

if ! docker info >/dev/null 2>&1; then
    fail "Docker is not running"
fi

echo "All prerequisites OK."

# Step 1
step 1 "Create Kind cluster"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "${YELLOW}Cluster '${CLUSTER_NAME}' already exists, skipping.${NC}"
else
    sudo sysctl -w fs.inotify.max_user_instances=512 2>/dev/null || true
    sudo sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true
    kind create cluster --name "${CLUSTER_NAME}" --config cluster-config.yaml
fi

# Step 2
step 2 "Export kubeconfig"
kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig ./kubeconfig.cluster.yaml
cp ./kubeconfig.cluster.yaml kubeconfig
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
kubectl get nodes

# Step 3
step 3 "Install Nginx Ingress"
cd "${SUPPORTING_DIR}"
sh ./3-install-ingress.sh

# Step 4
step 4 "Wait for Ingress controller"
sh ./4-cek-ingress.sh

# Step 5
step 5 "Install Prometheus + Grafana"
sh ./5-install-prometheus.sh

# Step 6
step 6 "Install Linkerd + Viz"
sh ./6-install-linkerd.sh

cd "${SCRIPT_DIR}"

echo
echo "${GREEN}============================================================${NC}"
echo "${GREEN} Setup completed successfully!${NC}"
echo "${GREEN}============================================================${NC}"
