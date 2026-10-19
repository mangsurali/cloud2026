#!/usr/bin/env bash
# Deploy DeathStarBench SocialNetwork to Kubernetes homelab cluster
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)

# Add local kubernetes binaries to PATH if present
export PATH="$REPO_ROOT/cloud2023/kubernetes/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind/kubeconfig}"

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-127.0.0.1}
NAMESPACE=${NAMESPACE:-cloud-dynamics}
CHART_DIR="$REPO_ROOT/DeathStarBench/socialNetwork/helm-chart/socialnetwork"

echo "=== 1. Checking tools ==="
for cmd in kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' not found in PATH." >&2
        exit 1
    fi
done

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
