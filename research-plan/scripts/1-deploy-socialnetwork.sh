#!/usr/bin/env bash
# Deploy DeathStarBench SocialNetwork to Kubernetes homelab cluster
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)

# Add local kubernetes binaries to PATH if present
export PATH="$REPO_ROOT/cloud2023/kubernetes/bin:$PATH"

# Resolve KUBECONFIG: honor existing env var first, then look for the homelab
# Kind kubeconfig. If neither exists, try to regenerate it with `kind`.
if [ -z "${KUBECONFIG:-}" ]; then
    if [ -f "$REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind/kubeconfig" ]; then
        export KUBECONFIG="$REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind/kubeconfig"
    elif command -v kind >/dev/null 2>&1; then
        echo "NOTE: kubeconfig not found, exporting from kind cluster 'mylab99'..."
        kind export kubeconfig --name mylab99
    fi
else
    export KUBECONFIG
fi

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-127.0.0.1}
NAMESPACE=${NAMESPACE:-cloud-dynamics}
CHART_DIR="$REPO_ROOT/DeathStarBench/socialNetwork/helm-chart/socialnetwork"

echo "=== 1. Checking tools & cluster connectivity ==="
for cmd in kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' not found in PATH." >&2
        exit 1
    fi
done

if [ -z "${KUBECONFIG:-}" ] || [ ! -f "$KUBECONFIG" ]; then
    cat >&2 <<EOF
ERROR: kubeconfig tidak ditemukan.
kubectl akan mencoba koneksi ke localhost:8080 (default) sehingga muncul error
'dial tcp [::1]:8080: connect: connection refused'.

Solusi:
  1. Pastikan klaster Kind sudah dibuat di PC ini:
       cd $REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind
       ./setup-all.sh
  2. Atau export KUBECONFIG manual ke file kubeconfig klaster Anda:
       export KUBECONFIG=/path/ke/kubeconfig
  3. Lalu jalankan ulang skrip ini.

KUBECONFIG yang dicek: ${KUBECONFIG:-<belum di-set>}
EOF
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: tidak bisa terhubung ke cluster Kubernetes.
  KUBECONFIG : $KUBECONFIG
  Server     : $(grep -A1 'server:' "$KUBECONFIG" 2>/dev/null | head -n1 | tr -d ' ' || echo unknown)

Periksa:
  - Apakah klaster Kind masih berjalan?  (docker ps harus ada container 'mylab99-...')
  - Jika cluster pindah PC / IP berubah, jalankan ulang setup:
      cd $REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind && ./setup-all.sh
EOF
    exit 1
fi
echo "Cluster OK. Using KUBECONFIG=$KUBECONFIG"
kubectl cluster-info | head -n 2

echo "=== 2. Creating namespace: $NAMESPACE ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 3. Deploying SocialNetwork with Helm ==="
helm upgrade --install social-network "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --set global.nginx.resolverName="kube-dns.kube-system.svc.cluster.local"

echo "=== 4. Configuring Ingress ==="
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: social-network
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: social-network.${HOST_IP}.sslip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-thrift
            port:
              number: 8080
EOF

echo "=== 5. Waiting for Nginx Frontend to be Ready ==="
kubectl -n "$NAMESPACE" rollout status deployment/nginx-thrift --timeout=300s

echo
echo "=========================================================="
echo "SocialNetwork successfully deployed!"
echo "URL : http://social-network.${HOST_IP}.sslip.io/"
echo "=========================================================="
