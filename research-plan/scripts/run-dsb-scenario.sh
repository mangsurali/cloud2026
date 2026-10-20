#!/usr/bin/env bash
# ==============================================================================
# Runner Skenario DeathStarBench (SocialNetwork) — Output Format Homelab
# ==============================================================================
# Penggunaan:
#   ./scripts/run-dsb-scenario.sh <skenario> [replicate]
#
# Skenario riset (urutan penelitian):
#   Fase 0 — Baseline
#     01-baseline-mixed        : mixed 25 RPS 60s (titik acuan)
#   Fase 1 — Pemetaan jalur microservice
#     02-read-user-timeline    : jalur baca terpendek
#     03-read-home-timeline    : jalur baca fan-out
#     04-compose-post          : jalur tulis terpanjang
#     05-mixed-highload        : mixed 50 RPS (interaksi antar jalur)
#   Fase 2 — Dinamika beban
#     06-ramp-mixed            : 5 -> 40 RPS / 120s (titik jenuh)
#     07-overload-mixed        : 100 RPS (bottleneck)
#     08-burst-mixed           : 10 -> 50 RPS mendadak (elastisitas)
#   Fase 3 — Arsitektur microservice lanjutan
#     09-read-heavy            : 95% baca / 5% tulis
#     10-write-heavy           : 50% tulis (biaya jalur write)
#
# Skenario legacy (tetap tersedia):
#   read-home-timeline, read-user-timeline, compose-post, mixed,
#   constant, ramp, burst
#
# Replicate: angka urut pengulangan (default 1). Jalankan 1..3 untuk 3 replicate.
# Remote: set HOST_IP di config/experiment.env (default 10.160.4.43).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

SCENARIO_NAME=${1:-read-home-timeline}
REPLICATE=${2:-1}

case "$SCENARIO_NAME" in
    # --- Fase 0-3: skenario riset ---
    01-baseline-mixed|baseline)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-01-baseline-mixed.env" ;;
    02-read-user-timeline|read-user-timeline|read_user_timeline)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-02-read-user-timeline.env" ;;
    03-read-home-timeline|read-home-timeline|read_home_timeline)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-03-read-home-timeline.env" ;;
    04-compose-post|compose-post|compose_post)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-04-compose-post.env" ;;
    05-mixed-highload|mixed-highload|highload)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-05-mixed-highload.env" ;;
    06-ramp-mixed|ramp)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-06-ramp-mixed.env" ;;
    07-overload-mixed|overload)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-07-overload-mixed.env" ;;
    08-burst-mixed|burst)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-08-burst-mixed.env" ;;
    09-read-heavy|read-heavy|read_heavy)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-09-read-heavy.env" ;;
    10-write-heavy|write-heavy|write_heavy)
        SCENARIO_FILE="$ROOT_DIR/scenarios/research-10-write-heavy.env" ;;
    mixed|mixed-workload|mixed_workload)
        SCENARIO_FILE="$ROOT_DIR/scenarios/dsb-mixed-workload.env" ;;
    *)
        if [ -f "$SCENARIO_NAME" ]; then
            SCENARIO_FILE="$SCENARIO_NAME"
        elif [ -f "$ROOT_DIR/scenarios/$SCENARIO_NAME" ]; then
            SCENARIO_FILE="$ROOT_DIR/scenarios/$SCENARIO_NAME"
        else
            echo "ERROR: Skenario tidak dikenal '$SCENARIO_NAME'" >&2
            echo "Skenario riset: 01-baseline-mixed, 02-read-user-timeline, 03-read-home-timeline," >&2
            echo "  04-compose-post, 05-mixed-highload, 06-ramp-mixed, 07-overload-mixed," >&2
            echo "  08-burst-mixed, 09-read-heavy, 10-write-heavy" >&2
            exit 1
        fi
        ;;
esac

echo "========================================================================"
echo ">> Menjalankan Skenario DeathStarBench: $SCENARIO_NAME (replicate $REPLICATE)"
echo ">> File konfigurasi: $SCENARIO_FILE"
echo "========================================================================"

# 1. Jalankan pengujian beban (menghasilkan workload.csv, metadata.json, measurement-window.env)
REPLICATE="$REPLICATE" "$SCRIPT_DIR/3-run-experiment.sh" "$SCENARIO_FILE"

# Dapatkan direktori hasil eksperimen terbaru
LATEST_EXP=$(ls -td "$ROOT_DIR/results/"*/ | head -n 1)

echo
echo "========================================================================"
echo ">> Mengumpulkan Metrik Prometheus..."
echo "========================================================================"
# 2. Ekstraksi metrik klaster dan buat combined.csv
"$SCRIPT_DIR/4-collect-metrics.sh" "$LATEST_EXP"

echo
echo "========================================================================"
echo ">> PENGUJIAN & PENGUMPULAN METRIK SELESAI!"
echo ">> Direktori Hasil: $LATEST_EXP"
echo ">> File Hasil:"
ls -lh "$LATEST_EXP"
echo "========================================================================"
