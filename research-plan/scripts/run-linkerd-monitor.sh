#!/usr/bin/env bash
# ==============================================================================
# run-linkerd-monitor.sh — Skenario 13: Monitoring microservice via Linkerd
# ==============================================================================
# JALANKAN DI MESIN LOKAL (target klaster remote, default 10.160.4.43).
# Tidak butuh kubectl — hanya HTTP ke app & Prometheus via ingress.
#
# Prasyarat: sidecar Linkerd sudah diinjeksi ke pod SocialNetwork
# (sekali saja, jalankan inject-linkerd.sh DI SERVER klaster).
#
# Yang dijalankan: beban mixed 25 RPS 60s (format homelab: workload.csv,
# combined.csv dkk) + polling per detik metrik emas Linkerd per pod:
#   linkerd-metrics/request-rate.csv    — RPS inbound per microservice
#   linkerd-metrics/success-rate.csv    — rasio sukses per microservice
#   linkerd-metrics/latency-p95.csv     — p95 latency (ms) per microservice
#   linkerd-summary.csv                 — agregat akhir per microservice
#
# Penggunaan:
#   ./scripts/run-linkerd-monitor.sh [replicate]     # default 1
#   DURATION=120 RPS=50 ./scripts/run-linkerd-monitor.sh 2   # override beban
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

. "$ROOT_DIR/config/experiment.env"
HOST_IP=${HOST_IP:-10.160.4.43}
NAMESPACE=${NAMESPACE:-cloud-dynamics}
PROM_URL=${PROMETHEUS_URL:-http://prometheus.${HOST_IP}.sslip.io}
REPLICATE=${1:-1}
DURATION=${DURATION:-60}
RPS=${RPS:-25}
POLL_INTERVAL=${POLL_INTERVAL:-1}

echo "=========================================================="
echo ">> Skenario 13: Linkerd Service Mesh Monitor"
echo ">> Target: $TARGET_URL | Prometheus: $PROM_URL"
echo ">> Beban: mixed $RPS RPS, ${DURATION}s | replicate $REPLICATE"
echo "=========================================================="

# --- Pre-check 1: app & Prometheus terjangkau ---------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$TARGET_URL/" || echo 000)
[ "$CODE" = "200" ] || { echo "ERROR: app tidak terjangkau: $TARGET_URL (HTTP $CODE)" >&2; exit 1; }
CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$PROM_URL/-/ready" || echo 000)
[ "$CODE" = "200" ] || { echo "ERROR: Prometheus tidak terjangkau: $PROM_URL (HTTP $CODE)" >&2; exit 1; }
echo "[OK ] App & Prometheus terjangkau"

# --- Pre-check 2: metrik Linkerd ada (sidecar sudah ter-inject & ter-scrape) --
NL=$(curl -fsS -m 5 -G "$PROM_URL/api/v1/query" \
    --data-urlencode "query=count(response_total{namespace=\"$NAMESPACE\"}) or vector(0)" \
    | python3 -c 'import json,sys; print(int(float(json.load(sys.stdin)["data"]["result"][0]["value"][1])))' 2>/dev/null || echo 0)
if [ "${NL:-0}" -eq 0 ]; then
    cat >&2 <<EOF
ERROR: metrik Linkerd (response_total) kosong di namespace $NAMESPACE.
Sidecar proxy belum ter-inject atau belum ter-scrape. Solusi:
  1. Jalankan DI SERVER klaster:  ./scripts/inject-linkerd.sh
  2. Tunggu ~1 menit, cek ulang:  ./scripts/run-linkerd-monitor.sh
EOF
    exit 1
fi
echo "[OK ] Metrik Linkerd terdeteksi ($NL series)"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EXP_ID="linkerd-mixed-${STAMP}-r${REPLICATE}"
OUT="$ROOT_DIR/results/$EXP_ID"
mkdir -p "$OUT/linkerd-metrics"

# --- 3. Jalankan beban + polling metrik paralel -------------------------------
echo ">> Memulai beban & polling metrik Linkerd..."

# Poller: tarik metrik per pod tiap POLL_INTERVAL detik sampai STOP_FILE muncul
python3 - "$PROM_URL" "$NAMESPACE" "$OUT" "$DURATION" "$POLL_INTERVAL" "$OUT/.stop-poll" <<'PY' &
import csv, json, os, sys, time, urllib.parse, urllib.request

prom, ns, outdir, duration, interval, stopfile = sys.argv[1:7]
duration, interval = float(duration), float(interval)

QUERIES = {
    "request-rate.csv":  'sum by (pod) (rate(request_total{namespace="%s",direction="inbound"}[%s]))',
    "success-rate.csv":  'sum by (pod) (rate(response_total{namespace="%s",direction="inbound",classification="success"}[%s])) / sum by (pod) (rate(response_total{namespace="%s",direction="inbound"}[%s]))',
    "latency-p95.csv":   'histogram_quantile(0.95, sum by (pod,le) (rate(response_latency_us_bucket{namespace="%s",direction="inbound"}[%s]))) / 1000',
}
WIN = "1m"   # window rate pendek agar responsif terhadap perubahan beban

def query(q):
    url = f"{prom}/api/v1/query?" + urllib.parse.urlencode({"query": q})
    try:
        with urllib.request.urlopen(url, timeout=8) as r:
            data = json.loads(r.read())
        return data["data"]["result"]
    except Exception:
        return None

rows = {name: [] for name in QUERIES}   # name -> list[(ts, pod, value)]
pods_seen = set()
start = time.time()

while time.time() - start < duration:
    if os.path.exists(stopfile):
        break
    ts = time.time()
    for name, tmpl in QUERIES.items():
        if name == "success-rate.csv":
            q = tmpl % (ns, WIN, ns, WIN)
        else:
            q = tmpl % (ns, WIN)
        res = query(q)
        if res is None:
            continue
        for series in res:
            pod = series["metric"].get("pod", "?")
            val = float(series["value"][1])
            rows[name].append((ts, pod, val))
            pods_seen.add(pod)
    time.sleep(interval)

# Tulis CSV per metrik, format panjang: timestamp_epoch,pod,value
for name, data in rows.items():
    with open(os.path.join(outdir, "linkerd-metrics", name), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp_epoch", "pod", "value"])
        for ts, pod, val in data:
            w.writerow([f"{ts:.3f}", pod, f"{val:.6f}"])
print(f"poller: {len(pods_seen)} pod, {sum(len(v) for v in rows.values())} baris metrik")
PY
POLL_PID=$!

cleanup() {
    touch "$OUT/.stop-poll" 2>/dev/null || true
    wait "$POLL_PID" 2>/dev/null || true
    rm -f "$OUT/.stop-poll"
}
trap cleanup EXIT

# Beban (warmup + measurement; menghasilkan workload.csv, metadata.json, dst)
DURATION="$DURATION" RPS="$RPS" WORKLOAD_TYPE=mixed REPLICATE="$REPLICATE" \
    "$SCRIPT_DIR/3-run-experiment.sh" "$ROOT_DIR/scenarios/research-01-baseline-mixed.env"
EXP_DIR=$(ls -td "$ROOT_DIR/results/"*/ | head -n 1)

# Hentikan poller
touch "$OUT/.stop-poll"
wait "$POLL_PID" 2>/dev/null || true
trap - EXIT
rm -f "$OUT/.stop-poll"

# --- 4. Metrik klaster konvensional (combined.csv homelab) --------------------
"$SCRIPT_DIR/4-collect-metrics.sh" "$EXP_DIR"

# Pindahkan CSV linkerd ke folder eksperimen (poller menulis ke $OUT, folder
# yang sama bila STAMP identik; pastikan ada di EXP_DIR)
if [ -d "$OUT/linkerd-metrics" ] && [ "$OUT" != "$EXP_DIR" ]; then
    mv "$OUT/linkerd-metrics" "$EXP_DIR/" 2>/dev/null || true
    rmdir "$OUT" 2>/dev/null || true
fi

# --- 5. Ringkasan per microservice --------------------------------------------
python3 - "$EXP_DIR" <<'PY'
import csv, glob, os, statistics, sys

exp = sys.argv[1]
lm = os.path.join(exp, "linkerd-metrics")
files = {k: os.path.join(lm, k) for k in
         ("request-rate.csv", "success-rate.csv", "latency-p95.csv")}
if not all(os.path.exists(f) for f in files.values()):
    print("warn: CSV metrik Linkerd tidak lengkap, summary dilewati", file=sys.stderr)
    sys.exit(0)

def load(path):
    per_pod = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            per_pod.setdefault(row["pod"], []).append(float(row["value"]))
    return per_pod

req, succ, lat = (load(files[k]) for k in files)
pods = sorted(set(req) | set(succ) | set(lat))

def strip_replica(pod):
    # nama deployment dari pod: compose-post-service-xxxx-yyyy -> compose-post-service
    parts = pod.rsplit("-", 2)
    return parts[0] if len(parts) == 3 else pod

with open(os.path.join(exp, "linkerd-summary.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["service", "pods", "mean_rps_total", "mean_success_rate",
                "p95_latency_ms_max", "samples"])
    by_svc = {}
    for pod in pods:
        svc = strip_replica(pod)
        by_svc.setdefault(svc, {"r": [], "s": [], "l": [], "pods": set()})
        by_svc[svc]["pods"].add(pod)
        by_svc[svc]["r"] += req.get(pod, [])
        by_svc[svc]["s"] += succ.get(pod, [])
        by_svc[svc]["l"] += lat.get(pod, [])
    for svc in sorted(by_svc, key=lambda s: -sum(by_svc[s]["r"]) if by_svc[s]["r"] else 0):
        d = by_svc[svc]
        mean_rps = sum(d["r"]) if d["r"] else 0.0
        mean_succ = statistics.mean(d["s"]) if d["s"] else 0.0
        p95_max = max(d["l"]) if d["l"] else 0.0
        w.writerow([svc, len(d["pods"]), f"{mean_rps:.3f}",
                    f"{mean_succ:.4f}", f"{p95_max:.3f}", len(d["r"])])
    print(f"Summary: {len(by_svc)} service -> {exp}/linkerd-summary.csv")
PY

echo
echo "========================================================================"
echo ">> SELESAI. Hasil di: $EXP_DIR"
ls -lh "$EXP_DIR" | grep -E "workload|combined|metadata|linkerd" || ls -lh "$EXP_DIR"
echo ">> - linkerd-metrics/*.csv : time-series per pod (request, success, p95)"
echo ">> - linkerd-summary.csv   : tabel kontribusi per microservice"
echo ">> - combined.csv          : workload + metrik klaster (kolom LINKERD_* terisi)"
echo "========================================================================"
