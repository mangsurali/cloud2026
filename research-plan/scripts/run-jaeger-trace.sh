#!/usr/bin/env bash
# ==============================================================================
# run-jaeger-trace.sh — Skenario 11: Distribusi latency per-hop via Jaeger
# ==============================================================================
# Jalankan beban konstan (mixed 25 RPS) sambil mengambil trace dari Jaeger,
# lalu ekspor:
#   traces.json  : trace mentah (service span, duration per hop)
#   traces-summary.csv : ringkasan per service (jumlah span, mean/p95/max ms)
#
# PRASYARAT:
#   - Kubectl harus bisa akses klaster (jalankan dulu:
#       REMOTE_SSH_HOST=<user>@<HOST_IP> ./scripts/0-connect-remote.sh tunnel
#     bila dari mesin remote).
#   - Port 16686 lokal bebas (dipakai port-forward ke Jaeger UI/API).
#
# Penggunaan:
#   ./scripts/run-jaeger-trace.sh [replicate]        # default replicate 1
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
TARGET_URL=${TARGET_URL:-http://social-network.${HOST_IP}.sslip.io}
REPLICATE=${1:-1}
DURATION=${DURATION:-60}
RPS=${RPS:-25}
JAEGER_LOCAL_PORT=${JAEGER_LOCAL_PORT:-16686}

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl tidak ada di PATH" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || {
    echo "ERROR: API server klaster tidak terjangkau." >&2
    echo "Buka tunnel dulu: REMOTE_SSH_HOST=<user>@$HOST_IP ./scripts/0-connect-remote.sh tunnel" >&2
    exit 1
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EXP_ID="jaeger-trace-mixed-${STAMP}-r${REPLICATE}"
OUT="$ROOT_DIR/results/$EXP_ID"
mkdir -p "$OUT"

echo "========================================================================"
echo ">> Skenario 11: Jaeger Trace (mixed ${RPS} RPS, ${DURATION}s)"
echo ">> Hasil: $OUT"
echo "========================================================================"

# 1. Port-forward ke service Jaeger
echo ">> Port-forward Jaeger (localhost:$JAEGER_LOCAL_PORT -> jaeger:16686)..."
kubectl -n "$NAMESPACE" port-forward svc/jaeger "$JAEGER_LOCAL_PORT:16686" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 15); do
    curl -s -m 2 "http://localhost:$JAEGER_LOCAL_PORT/api/services" >/dev/null 2>&1 && break
    sleep 1
done
curl -s -m 2 "http://localhost:$JAEGER_LOCAL_PORT/api/services" >/dev/null 2>&1 || {
    echo "ERROR: Jaeger API tidak terjangkau lewat port-forward" >&2; exit 1; }
echo "[OK ] Jaeger API aktif di localhost:$JAEGER_LOCAL_PORT"

# 2. Catat jumlah trace sebelum beban
TRACE_START_US=$(( $(date +%s) * 1000000 ))

# 3. Jalankan beban (warmup + measurement, format homelab) dengan durasi/RPS override
DURATION="$DURATION" RPS="$RPS" WORKLOAD_TYPE=mixed \
    "$SCRIPT_DIR/3-run-experiment.sh" "$ROOT_DIR/scenarios/research-01-baseline-mixed.env"
EXP_DIR=$(ls -td "$ROOT_DIR/results/"*/ | head -n 1)

TRACE_END_US=$(( $(date +%s) * 1000000 ))

# 4. Ekstrak trace dari semua service selama jendela pengukuran
echo ">> Mengambil trace Jaeger..."
SERVICES=$(curl -s "http://localhost:$JAEGER_LOCAL_PORT/api/services" \
    | python3 -c 'import json,sys; [print(s) for s in json.load(sys.stdin)["data"] if s != "jaeger"]')

python3 - "$EXP_DIR" "$JAEGER_LOCAL_PORT" "$TRACE_START_US" "$TRACE_END_US" <<'PY'
import csv, json, statistics, sys, urllib.request

exp_dir, port, t0, t1 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
services = urllib.request.urlopen(f"http://localhost:{port}/api/services", timeout=5).read()
services = [s for s in json.loads(services)["data"] if s != "jaeger"]

all_traces = []
for svc in services:
    url = (f"http://localhost:{port}/api/traces?service={svc}"
           f"&start={t0}&end={t1}&limit=50&lookback=custom")
    try:
        data = json.loads(urllib.request.urlopen(url, timeout=15).read())
        all_traces.extend(data.get("data", []))
    except Exception as e:
        print(f"  warn: {svc}: {e}", file=sys.stderr)

# Simpan trace mentah
with open(f"{exp_dir}/traces.json", "w") as f:
    json.dump(all_traces, f)

# Ringkasan per service: jumlah span, mean/p95/max durasi (ms)
by_svc = {}
for tr in all_traces:
    for sp in tr.get("spans", []):
        svc = sp["process"]["serviceName"]
        by_svc.setdefault(svc, []).append(sp["duration"] / 1000.0)  # us -> ms

def p95(v):
    s = sorted(v)
    return s[min(len(s)-1, max(0, int(0.95*len(s))-1))] if s else 0.0

with open(f"{exp_dir}/traces-summary.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["service", "spans", "mean_ms", "p95_ms", "max_ms"])
    for svc in sorted(by_svc, key=lambda s: -statistics.mean(by_svc[s])):
        v = by_svc[svc]
        w.writerow([svc, len(v), f"{statistics.mean(v):.2f}",
                    f"{p95(v):.2f}", f"{max(v):.2f}"])
    print(f"Trace: {len(all_traces)} trace, {sum(len(v) for v in by_svc.values())} span "
          f"-> {exp_dir}/traces-summary.csv")
PY

kill "$PF_PID" 2>/dev/null || true
trap - EXIT

echo
echo "========================================================================"
echo ">> SELESAI. Hasil:"
ls -lh "$EXP_DIR" | grep -E "traces|workload|combined|metadata" || ls -lh "$EXP_DIR"
echo ">> traces-summary.csv = kontribusi latency per microservice"
echo "========================================================================"
