#!/usr/bin/env bash
# ==============================================================================
# inject-linkerd.sh — Injeksi sidecar Linkerd ke SocialNetwork
# ==============================================================================
# JALANKAN DI SERVER KLASTER (10.160.4.43), bukan dari mesin lokal.
# Tidak butuh tunnel: kubectl langsung dipakai di server tsb.
#
# Yang dilakukan skrip ini:
#   1. Cek kubectl & kontrol plane Linkerd (namespace linkerd).
#   2. Annotate namespace cloud-dynamics: linkerd.io/inject=enabled.
#   3. Rollout restart semua deployment -> pod dibuat ulang + sidecar proxy.
#   4. Tunggu semua pod Running 2/2 (aplikasi + linkerd-proxy), maks 8 menit.
#   5. Verifikasi: metrik response_total mulai muncul di Prometheus.
#   6. Seeding ulang data pengguna (data emptyDir hilang saat restart).
#
# Idempoten: aman dijalankan berulang. Setelah sukses, jalankan dari mesin
# lokal:  ./scripts/run-linkerd-monitor.sh <replicate>
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)

export PATH="$REPO_ROOT/cloud2023/kubernetes/bin:$PATH"

# Resolusi kubeconfig (di server klaster biasanya ~/.kube/config hasil kind export)
if [ -z "${KUBECONFIG:-}" ]; then
    if [ -f "$HOME/.kube/config" ]; then
        export KUBECONFIG="$HOME/.kube/config"
    elif [ -f "$REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind/kubeconfig" ]; then
        export KUBECONFIG="$REPO_ROOT/cloud2023/kubernetes/setup-cluster/kind/kubeconfig"
    fi
else
    export KUBECONFIG
fi

. "$ROOT_DIR/config/experiment.env"
# Di server, ingress terjangkau via localhost (port 80/443 di-map kind)
HOST_IP=${HOST_IP:-10.160.4.43}
NAMESPACE=${NAMESPACE:-cloud-dynamics}

echo "=========================================================="
echo ">> Injeksi Sidecar Linkerd — namespace: $NAMESPACE"
echo "=========================================================="

# --- 1. Prasyarat -------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl tidak ada di PATH" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: API server tidak terjangkau. Jalankan skrip ini di server klaster," >&2
    echo "atau pastikan kubeconfig benar (KUBECONFIG=$KUBECONFIG)." >&2
    exit 1; }

echo ">> [1/6] Cek kontrol plane Linkerd..."
if ! kubectl get deploy -n linkerd destination >/dev/null 2>&1; then
    echo "ERROR: kontrol plane Linkerd tidak ditemukan di namespace 'linkerd'." >&2
    echo "Instal dulu (di server): https://linkerd.io/2/getting-started/" >&2
    echo "  linkerd install --crds | kubectl apply -f -" >&2
    echo "  linkerd install       | kubectl apply -f -" >&2
    echo "  linkerd check" >&2
    exit 1
fi
NOTREADY=$(kubectl get deploy -n linkerd --no-headers 2>/dev/null | awk '$2!=$4{n++} END{print n+0}')
if [ "$NOTREADY" -gt 0 ]; then
    echo ">> Kontrol plane belum semua selesai, menunggu..."
    kubectl wait --for=condition=Available deploy --all -n linkerd --timeout=300s || true
fi
echo "[OK ] Kontrol plane Linkerd siap"

echo ">> [2/6] Annotate namespace $NAMESPACE..."
kubectl annotate ns "$NAMESPACE" linkerd.io/inject=enabled --overwrite
echo "[OK ] linkerd.io/inject=enabled"

echo ">> [3/6] Rollout restart semua deployment di $NAMESPACE..."
DEPLOYMENTS=$(kubectl get deploy -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')
for d in $DEPLOYMENTS; do
    kubectl rollout restart deploy/"$d" -n "$NAMESPACE" >/dev/null
done
echo "[OK ] Direstart: $(echo "$DEPLOYMENTS" | wc -w) deployment"

echo ">> [4/6] Menunggu rollout selesai (maks 8 menit)..."
for d in $DEPLOYMENTS; do
    if ! kubectl rollout status deploy/"$d" -n "$NAMESPACE" --timeout=480s 2>/dev/null; then
        echo "warn: rollout $d belum selesai dalam 480s, lanjut..." >&2
    fi
done

# Tunggu semua pod Running dan 2/2 (aplikasi + linkerd-proxy)
WAIT_OK=0
for i in $(seq 1 96); do    # 96 x 5s = 8 menit
    TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c Running || true)
    READY22=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$2=="2/2"' | grep -c Running || true)
    TOTAL=${TOTAL:-0}; READY22=${READY22:-0}
    printf "\r   Running: %s | 2/2 (dengan sidecar): %s   " "$TOTAL" "$READY22"
    if [ "$TOTAL" -gt 0 ] && [ "$READY22" -eq "$TOTAL" ]; then
        WAIT_OK=1
        echo
        break
    fi
    sleep 5
done
echo
if [ "$WAIT_OK" -ne 1 ]; then
    echo "ERROR: tidak semua pod mencapai 2/2 dalam 8 menit. Pod bermasalah:" >&2
    kubectl get pods -n "$NAMESPACE" | awk '$2!="2/2" || $3!="Running"' >&2
    echo "Cek: kubectl describe pod <pod> -n $NAMESPACE (khususnya log linkerd-proxy)" >&2
    exit 1
fi
echo "[OK ] Semua pod Running 2/2 (aplikasi + linkerd-proxy)"

echo ">> [5/6] Verifikasi metrik proxy di Prometheus..."
# HOST_IP lokal: coba 127.0.0.1 dulu (di server), fallback ke HOST_IP config
PROM=""
for H in 127.0.0.1 "$HOST_IP"; do
    if curl -fsS -m 5 "http://prometheus.${H}.sslip.io/-/ready" >/dev/null 2>&1; then
        PROM="http://prometheus.${H}.sslip.io"
        break
    fi
done
if [ -n "$PROM" ]; then
    # Tunggu scrape pertama (biasanya <=1 menit)
    METRICS_OK=0
    for i in $(seq 1 12); do
        N=$(curl -fsS -m 5 -G "$PROM/api/v1/query" \
            --data-urlencode "query=count(response_total{namespace=\"$NAMESPACE\"}) or vector(0)" \
            | python3 -c 'import json,sys; print(int(float(json.load(sys.stdin)["data"]["result"][0]["value"][1])))' 2>/dev/null || echo 0)
        if [ "${N:-0}" -gt 0 ]; then
            METRICS_OK=1
            break
        fi
        sleep 5
    done
    if [ "$METRICS_OK" -eq 1 ]; then
        echo "[OK ] Metrik Linkerd (response_total) ter-scrape Prometheus ($N series)"
    else
        echo "warn: metrik response_total belum muncul di Prometheus dalam 60s." >&2
        echo "      Proxy sudah jalan; bisa jadi Prometheus belum scrape port 4191." >&2
        echo "      Jalankan ./scripts/run-linkerd-monitor.sh — skrip akan pre-check." >&2
    fi
else
    echo "warn: Prometheus tidak terjangkau dari server, verifikasi metrik dilewati." >&2
fi

echo ">> [6/6] Seeding ulang data pengguna & graf sosial..."
if HOST_IP=127.0.0.1 "$SCRIPT_DIR/2-init-data.sh"; then
    echo "[OK ] Seeding selesai"
else
    echo "warn: seeding gagal — jalankan manual: HOST_IP=127.0.0.1 ./scripts/2-init-data.sh" >&2
    exit 1
fi

# Smoke test
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
    "http://social-network.127.0.0.1.sslip.io/wrk2-api/home-timeline/read?user_id=1&start=0&stop=5" || echo 000)
echo
echo "=========================================================="
echo ">> INJEKSI SELESAI. Smoke test home-timeline: HTTP $CODE"
echo ">> Sekarang jalankan dari MESIN LOKAL:"
echo "     ./scripts/0-connect-remote.sh          # pastikan app & prom OK"
echo "     ./scripts/run-linkerd-monitor.sh 1     # skenario 13, replicate 1"
echo "=========================================================="
