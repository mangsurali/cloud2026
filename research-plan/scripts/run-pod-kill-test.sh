#!/usr/bin/env bash
# ==============================================================================
# run-pod-kill-test.sh — Skenario 12: Ketahanan arsitektur (fault injection)
# ==============================================================================
# Menjalankan beban konstan, mematikan 1 pod microservice di tengah jalan,
# lalu mencatat dampaknya (latency spike, error, waktu pemulihan).
#
# Output tambahan di folder hasil:
#   pod-kill.json : waktu kill, pod lama/baru, status sebelum & sesudah
#
# PRASYARAT:
#   - Kubectl akses klaster (buka tunnel dulu bila remote):
#       REMOTE_SSH_HOST=<user>@<HOST_IP> ./scripts/0-connect-remote.sh tunnel
#
# Penggunaan:
#   ./scripts/run-pod-kill-test.sh [service] [replicate]
#   Contoh:
#     ./scripts/run-pod-kill-test.sh                          # home-timeline-service, r1
#     ./scripts/run-pod-kill-test.sh compose-post-service 2   # service lain, r2
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$ROOT_DIR/.." && pwd)
export PATH="$REPO_ROOT/cloud2023/kubernetes/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-10.160.4.43}
NAMESPACE=${NAMESPACE:-cloud-dynamics}
TARGET_SERVICE=${1:-home-timeline-service}
REPLICATE=${2:-1}
DURATION=${DURATION:-90}
RPS=${RPS:-25}
KILL_AT=${KILL_AT:-30}   # detik ke berapa pod di-kill (setelah warmup)

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl tidak ada di PATH" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: API server klaster tidak terjangkau." >&2
    echo "Buka tunnel dulu: REMOTE_SSH_HOST=<user>@$HOST_IP ./scripts/0-connect-remote.sh tunnel" >&2
    exit 1
}

# Validasi service ada
POD=$(kubectl -n "$NAMESPACE" get pods -l "app=$TARGET_SERVICE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || {
    echo "ERROR: tidak ada pod dengan label app=$TARGET_SERVICE di namespace $NAMESPACE" >&2
    echo "Daftar pod:" >&2
    kubectl -n "$NAMESPACE" get pods --no-headers | awk '{print "  "$1}' >&2
    exit 1
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EXP_ID="pod-kill-${TARGET_SERVICE}-${STAMP}-r${REPLICATE}"
OUT="$ROOT_DIR/results/$EXP_ID"
mkdir -p "$OUT"

echo "========================================================================"
echo ">> Skenario 12: Pod-Kill — target: $TARGET_SERVICE (kill di detik ke-$KILL_AT)"
echo ">> Beban: mixed $RPS RPS, ${DURATION}s | Hasil: $OUT"
echo "========================================================================"

RESTARTS_BEFORE=$(kubectl -n "$NAMESPACE" get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)

# 1. Jalankan beban di background, hasil ke workload.csv
#    (warmup 10s terjadi sebelum measurement; kill dihitung dari awal measurement)
LOAD_PID=""
cleanup() { [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null || true; }
trap cleanup EXIT

python3 "$SCRIPT_DIR/loadgen-socialnetwork.py" \
    --url "$TARGET_URL" --profile constant --workload-type mixed \
    --duration "$DURATION" --rps "$RPS" \
    --timeout "${REQUEST_TIMEOUT:-5}" --sample-interval 1 \
    --max-users "${MAX_USER_INDEX:-50}" \
    --output "$OUT/workload.csv" &
LOAD_PID=$!

# 2. Tunggu sampai detik KILL_AT lalu matikan pod
sleep "$KILL_AT"
KILL_EPOCH=$(date +%s)
echo ">> Membunuh pod: $POD (epoch $KILL_EPOCH)..."
kubectl -n "$NAMESPACE" delete pod "$POD" --grace-period=5 --wait=false
rm -f "$OUT/pod-kill.json"
KILL_RECORD="{\"target_service\": \"$TARGET_SERVICE\", \"killed_pod\": \"$POD\", \"kill_epoch\": $KILL_EPOCH, \"restarts_before\": $RESTARTS_BEFORE, \"recovery\": ["

# 3. Pantau pod pengganti sampai Ready (maks 180s)
RECOVERY_OK=0
NEW_POD=""
for i in $(seq 1 60); do
    sleep 3
    NEW_POD=$(kubectl -n "$NAMESPACE" get pods -l "app=$TARGET_SERVICE" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | cut -d' ' -f1)
    READY=$(kubectl -n "$NAMESPACE" get pods -l "app=$TARGET_SERVICE" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].status.containerStatuses[0].ready}' 2>/dev/null | cut -d' ' -f1)
    if [ -n "$NEW_POD" ] && [ "$NEW_POD" != "$POD" ] && [ "$READY" = "true" ]; then
        READY_EPOCH=$(date +%s)
        RECOVERY_OK=1
        echo "[OK ] Pod pengganti Ready: $NEW_POD (pemulihan $((READY_EPOCH - KILL_EPOCH))s)"
        KILL_RECORD="${KILL_RECORD}{\"new_pod\": \"$NEW_POD\", \"ready_epoch\": $READY_EPOCH, \"recovery_seconds\": $((READY_EPOCH - KILL_EPOCH))}"
        break
    fi
done
KILL_RECORD="$KILL_RECORD]}"
[ "$RECOVERY_OK" -eq 1 ] || echo "warn: pod pengganti belum Ready dalam 180s" >&2

# 4. Tunggu beban selesai
wait "$LOAD_PID" || true
LOAD_PID=""
trap - EXIT

echo "$KILL_RECORD" > "$OUT/pod-kill.json"

# 5. metadata + metrik klaster
MEAS_START=$(( KILL_EPOCH - KILL_AT ))
MEAS_END=$(date +%s)
cat > "$OUT/measurement-window.env" <<EOF
EXPERIMENT_ID=$EXP_ID
MEASUREMENT_START_EPOCH=$MEAS_START
MEASUREMENT_END_EPOCH=$MEAS_END
SAMPLE_INTERVAL=1
EOF
python3 - "$OUT/metadata.json" "$EXP_ID" "$TARGET_URL" "$HOST_IP" "$REPLICATE" <<'PY'
import json, platform, sys
meta = {
  "experiment_id": sys.argv[2], "profile": "constant", "workload_type": "mixed-pod-kill",
  "target_url": sys.argv[3], "host_ip": sys.argv[4],
  "measurement_start_epoch": None, "measurement_end_epoch": None,
  "sample_interval_seconds": 1.0, "warmup_seconds": 0, "cooldown_seconds": 0,
  "replicate": int(sys.argv[5]),
  "application": {"name": "social-network", "architecture": "microservices-deathstarbench"},
  "fault_injection": {"service": "see pod-kill.json"},
  "runtime": {"python": platform.python_version(), "platform": platform.platform()}
}
import re
m = re.search(r"MEASUREMENT_START_EPOCH=(\d+)", open(sys.argv[1].replace("metadata.json","measurement-window.env")).read())
n = re.search(r"MEASUREMENT_END_EPOCH=(\d+)", open(sys.argv[1].replace("metadata.json","measurement-window.env")).read())
meta["measurement_start_epoch"] = int(m.group(1)); meta["measurement_end_epoch"] = int(n.group(1))
json.dump(meta, open(sys.argv[1], "w"), indent=2)
PY

echo ">> Mengumpulkan metrik Prometheus..."
"$SCRIPT_DIR/4-collect-metrics.sh" "$OUT"

echo
echo "========================================================================"
echo ">> SELESAI. Analisis:"
echo ">>  - Lihat baris workload.csv di sekitar detik ke-$KILL_AT (spike latency/error)"
echo ">>  - pod-kill.json berisi lama pemulihan"
ls -lh "$OUT"
echo "========================================================================"
