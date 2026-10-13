#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

. ./variables.sh

CLUSTER_NAME="mylab99"

# ============================================================
# Warna
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'


# ============================================================
# Konfirmasi
# ============================================================

echo "${YELLOW}This will DELETE cluster '${CLUSTER_NAME}' and all its data.${NC}"
echo

if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
    printf "Continue? [y/N] "
    read -r REPLY
    case "${REPLY}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi


# ============================================================
# Hapus cluster
# ============================================================

echo
echo "Deleting Kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "${GREEN}Cluster '${CLUSTER_NAME}' deleted.${NC}"
else
    echo "${YELLOW}Cluster '${CLUSTER_NAME}' not found, nothing to delete.${NC}"
fi


# ============================================================
# Bersihkan kubeconfig lokal
# ============================================================

echo
echo "Cleaning up local files..."

for f in kubeconfig kubeconfig.cluster.yaml; do
    if [ -f "${SCRIPT_DIR}/${f}" ]; then
        rm -f "${SCRIPT_DIR}/${f}"
        echo "  Removed ${f}"
    fi
done


# ============================================================
# Bersihkan Linkerd CLI config (opsional)
# ============================================================

if [ -d "${HOME}/.linkerd2" ]; then
    echo
    echo "${YELLOW}Linkerd CLI found at ~/.linkerd2${NC}"
    echo "  To also remove it: rm -rf ~/.linkerd2"
fi


# ============================================================
# Done
# ============================================================

echo
echo "${GREEN}============================================================${NC}"
echo "${GREEN} Reset completed!${NC}"
echo "${GREEN}============================================================${NC}"
echo
echo "To recreate the cluster:"
echo "  cd ${SCRIPT_DIR}"
echo "  sh setup-all.sh"
echo
