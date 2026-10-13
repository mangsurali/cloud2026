#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

. ./variables.sh

CLUSTER_NAME="mylab99"

# ============================================================
# Warna untuk output
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'


# ============================================================
# Helper
# ============================================================

step()
{
    STEP_NUM=$1
    STEP_NAME=$2
    echo
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN} Step ${STEP_NUM}: ${STEP_NAME}${NC}"
    echo "${GREEN}============================================================${NC}"
    echo
}


fail()
{
    echo "${RED}ERROR: $1${NC}" >&2
    exit 1
}


# ============================================================
# Cek prasyarat
# ============================================================

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


# ============================================================
# Step 1: Create cluster
# ============================================================

step 1 "Create Kind cluster"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "${YELLOW}Cluster '${CLUSTER_NAME}' already exists, skipping.${NC}"
else
    sudo sysctl -w fs.inotify.max_user_instances=512
    sudo sysctl -w fs.inotify.max_user_watches=524288

    kind create cluster \
        --name "${CLUSTER_NAME}" \
        --config cluster-config.yaml
fi


# ============================================================
# Step 2: Set kubeconfig
# ============================================================

step 2 "Export kubeconfig"

kind export kubeconfig \
    --name "${CLUSTER_NAME}" \
    --kubeconfig ./kubeconfig.cluster.yaml

cp ./kubeconfig.cluster.yaml kubeconfig
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"

echo "Nodes:"
kubectl get nodes


# ============================================================
# Step 3: Install nginx ingress
# ============================================================

step 3 "Install nginx ingress"

kubectl apply -f nginx-ingress.yaml


# ============================================================
# Step 4: Wait for ingress ready
# ============================================================

step 4 "Wait for ingress controller"

kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s

echo "${GREEN}Ingress controller is ready.${NC}"


# ============================================================
# Step 5: Install Prometheus
# ============================================================

step 5 "Install Prometheus + Grafana"

sh ./5-install-prometheus.sh


# ============================================================
# Step 6: Install Linkerd
# ============================================================

step 6 "Install Linkerd + Viz"

sh ./6-install-linkerd.sh


# ============================================================
# Summary
# ============================================================

echo
echo "${GREEN}============================================================${NC}"
echo "${GREEN} Setup completed!${NC}"
echo "${GREEN}============================================================${NC}"

HOST_IP="${HOST_IP:-127.0.0.1}"

cat <<EOF

Cluster:     ${CLUSTER_NAME}
Kubeconfig:  ${SCRIPT_DIR}/kubeconfig

URLs:
  Linkerd Viz:  http://linkerd.${HOST_IP}.sslip.io
  Prometheus:   http://prometheus.${HOST_IP}.sslip.io
  Grafana:      http://grafana.${HOST_IP}.sslip.io

Quick check:
  export KUBECONFIG=${SCRIPT_DIR}/kubeconfig
  kubectl get nodes
  kubectl get pods -A

EOF
