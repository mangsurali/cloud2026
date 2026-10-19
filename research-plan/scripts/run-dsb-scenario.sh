#!/usr/bin/env bash
# ==============================================================================
# Runner Skenario DeathStarBench (SocialNetwork) dengan Output Format Homelab
# ==============================================================================
# Skenario yang didukung:
#   1. read-home-timeline : Uji linimasa beranda (100% GET home timeline)
#   2. read-user-timeline : Uji linimasa profil pengguna (100% GET user timeline)
#   3. compose-post       : Uji posting konten (100% POST compose)
#   4. mixed-workload     : Uji campuran standar DSB (60% home, 30% user, 10% compose)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

SCENARIO_NAME=${1:-read-home-timeline}

case "$SCENARIO_NAME" in
    read-home-timeline|read_home_timeline)
        SCENARIO_FILE="$ROOT_DIR/scenarios/dsb-read-home-timeline.env"
        ;;
    read-user-timeline|read_user_timeline)
        SCENARIO_FILE="$ROOT_DIR/scenarios/dsb-read-user-timeline.env"
        ;;
    compose-post|compose_post)
        SCENARIO_FILE="$ROOT_DIR/scenarios/dsb-compose-post.env"
        ;;
    mixed|mixed-workload|mixed_workload)
        SCENARIO_FILE="$ROOT_DIR/scenarios/dsb-mixed-workload.env"
        ;;
    *)
        if [ -f "$SCENARIO_NAME" ]; then
            SCENARIO_FILE="$SCENARIO_NAME"
        elif [ -f "$ROOT_DIR/scenarios/$SCENARIO_NAME" ]; then
            SCENARIO_FILE="$ROOT_DIR/scenarios/$SCENARIO_NAME"
        else
            echo "ERROR: Unknown scenario '$SCENARIO_NAME'" >&2
            echo "Available scenarios: read-home-timeline, read-user-timeline, compose-post, mixed-workload" >&2
            exit 1
        fi
        ;;
esac

echo "========================================================================"
echo ">> Menjalankan Skenario DeathStarBench: $SCENARIO_NAME"
echo ">> File konfigurasi: $SCENARIO_FILE"
echo "========================================================================"

# 1. Jalankan pengujian beban (menghasilkan workload.csv, metadata.json, measurement-window.env)
"$SCRIPT_DIR/3-run-experiment.sh" "$SCENARIO_FILE"

# Dapatkan direktori hasil eksperimen terbaru
LATEST_EXP=$(ls -td "$ROOT_DIR/results/"* | head -n 1)

echo
echo "========================================================================"
echo ">> Mengumpulkan Metrik Prometheus Klaster Homelab..."
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
