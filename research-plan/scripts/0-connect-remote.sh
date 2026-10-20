#!/usr/bin/env bash
# ==============================================================================
# 0-connect-remote.sh — Cek konektivitas ke klaster remote (HOST_IP)
# ==============================================================================
# Jalankan sekali sebelum eksperimen lain. Script ini:
#   1. Mengecek app SocialNetwork & Prometheus via ingress (HTTP).
#   2. Mengecek akses kubectl ke API server klaster.
#   3. (Opsional) membuka SSH tunnel untuk API server klaster remote:
#        REMOTE_SSH_HOST=ali@10.160.4.43 ./scripts/0-connect-remote.sh tunnel
#      Agar perintah kubectl (deploy, jaeger trace, pod-kill) bisa dipakai
#      dari mesin ini. Kubeconfig kind menunjuk https://127.0.0.1:16443,
#      jadi tunnel memetakan port 16443 mesin klaster ke localhost sini.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)

export PATH="$REPO_ROOT/cloud2023/kubernetes/bin:$PATH"

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-10.160.4.43}
NAMESPACE=${NAMESPACE:-cloud-dynamics}
APP_URL="http://social-network.${HOST_IP}.sslip.io"
PROM_URL="http://prometheus.${HOST_IP}.sslip.io"
API_LOCAL_PORT=16443

MODE=${1:-check}

if [ "$MODE" = "tunnel" ]; then
    REMOTE_SSH_HOST=${REMOTE_SSH_HOST:-}
    if [ -z "$REMOTE_SSH_HOST" ]; then
        echo "ERROR: set REMOTE_SSH_HOST, contoh: REMOTE_SSH_HOST=ali@10.160.4.43 $0 tunnel" >&2
        exit 2
    fi
    echo ">> Membuka SSH tunnel: localhost:$API_LOCAL_PORT -> $REMOTE_SSH_HOST:$API_LOCAL_PORT"
    # Matikan tunnel lama bila ada
    pkill -f "ssh.*-L $API_LOCAL_PORT:localhost:$API_LOCAL_PORT" 2>/dev/null && sleep 1 || true
    ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -L "$API_LOCAL_PORT:localhost:$API_LOCAL_PORT" "$REMOTE_SSH_HOST"
    echo ">> Tunnel aktif. Kubeconfig (~/.kube/config, server https://127.0.0.1:16443) sekarang valid."
fi

echo "=========================================================="
echo " Cek Konektivitas Remote — HOST_IP=$HOST_IP"
echo "=========================================================="

FAIL=0

# 1. App SocialNetwork
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$APP_URL/" || echo 000)
if [ "$CODE" = "200" ]; then
    echo "[OK ] App          : $APP_URL (HTTP $CODE)"
else
    echo "[X ] App          : $APP_URL (HTTP $CODE) — cek ingress/pod di mesin klaster"
    FAIL=1
fi

# 2. Prometheus
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$PROM_URL/-/ready" || echo 000)
if [ "$CODE" = "200" ]; then
    echo "[OK ] Prometheus   : $PROM_URL (HTTP $CODE)"
else
    echo "[X ] Prometheus   : $PROM_URL (HTTP $CODE) — metrik tidak bisa ditarik"
    FAIL=1
fi

# 3. API server (kubectl)
if command -v kubectl >/dev/null 2>&1; then
    KCFG=${KUBECONFIG:-$HOME/.kube/config}
    if [ -f "$KCFG" ]; then
        export KUBECONFIG="$KCFG"
        if kubectl cluster-info >/dev/null 2>&1; then
            NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            echo "[OK ] Kubectl      : $KCFG ($NODES node terdaftar)"
        else
            echo "[-- ] Kubectl      : API server tidak terjangkau dari sini."
            echo "                     Untuk skenario deploy/jaeger/pod-kill, buka tunnel:"
            echo "                       REMOTE_SSH_HOST=<user>@$HOST_IP $0 tunnel"
            echo "                     Skenario load test & tarik metrik TIDAK butuh kubectl."
        fi
    else
        echo "[-- ] Kubectl      : kubeconfig tidak ditemukan ($KCFG)"
    fi
else
    echo "[-- ] Kubectl      : binary tidak tersedia di PATH"
fi

echo "=========================================================="
if [ "$FAIL" -eq 0 ]; then
    echo "Status: SIAP menjalankan eksperimen load test remote."
else
    echo "Status: Ada layanan yang belum terjangkau (lihat [X] di atas)."
    exit 1
fi
