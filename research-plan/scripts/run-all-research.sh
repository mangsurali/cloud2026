#!/usr/bin/env bash
# ==============================================================================
# run-all-research.sh — Menjalankan SELURUH rangkaian penelitian otomatis
# ==============================================================================
# 10 skenario load x N replicate (default 3) + 2 skenario khusus.
#
# Penggunaan:
#   ./scripts/run-all-research.sh                # 3 replicate, semua fase
#   ./scripts/run-all-research.sh 1              # 1 replicate saja (eksplorasi)
#   ./scripts/run-all-research.sh 3 "Fase 0 1"   # 3 replicate, hanya fase tertentu
#
# Estimasi waktu: ~40 run x rata-rata 2 menit = +/- 90 menit (3 replicate).
# Progress tersimpan di results/ — bisa dihentikan (Ctrl-C) dan dilanjutkan.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

REPLICATES=${1:-3}
PHASES_FILTER=${2:-"Fase 0 Fase 1 Fase 2 Fase 3"}

# urutan: "fase|nama-skenario"
SCENARIOS=(
    "Fase 0|01-baseline-mixed"
    "Fase 1|02-read-user-timeline"
    "Fase 1|03-read-home-timeline"
    "Fase 1|04-compose-post"
    "Fase 1|05-mixed-highload"
    "Fase 2|06-ramp-mixed"
    "Fase 2|07-overload-mixed"
    "Fase 2|08-burst-mixed"
    "Fase 3|09-read-heavy"
    "Fase 3|10-write-heavy"
)

echo "=========================================================="
echo " RANGKAIAN PENELITIAN SocialNetwork (DeathStarBench)"
echo " Replicate: $REPLICATES | Fase: $PHASES_FILTER"
echo "=========================================================="

TOTAL=0
DONE=0
FAILED=""

for entry in "${SCENARIOS[@]}"; do
    PHASE=${entry%%|*}
    NAME=${entry#*|}
    echo "$PHASES_FILTER" | grep -q "$PHASE" || continue
    TOTAL=$((TOTAL + REPLICATES))
done

if [ "$TOTAL" -eq 0 ]; then
    echo "Tidak ada skenario yang cocok dengan filter fase." >&2
    exit 2
fi

echo "Total run: $TOTAL"
echo

for entry in "${SCENARIOS[@]}"; do
    PHASE=${entry%%|*}
    NAME=${entry#*|}
    echo "$PHASES_FILTER" | grep -q "$PHASE" || continue
    for R in $(seq 1 "$REPLICATES"); do
        DONE=$((DONE + 1))
        echo "=========================================================="
        echo "[$DONE/$TOTAL] $PHASE — $NAME (replicate $R)"
        echo "=========================================================="
        if ! "$SCRIPT_DIR/run-dsb-scenario.sh" "$NAME" "$R"; then
            FAILED="$FAILED $NAME-r$R"
            echo "!! GAGAL: $NAME replicate $R (lanjut ke berikutnya)"
        fi
        sleep 5  # jeda antar run agar cluster pulih
    done
done

echo
echo "=========================================================="
echo " RANGKAIAN SELESAI: $DONE/$TOTAL run"
if [ -n "$FAILED" ]; then
    echo " Gagal:$FAILED"
    echo " Jalankan ulang: ./scripts/run-dsb-scenario.sh <nama> <r>"
fi
echo " Hasil lengkap di: $ROOT_DIR/results/"
ls -td "$ROOT_DIR/results/"*/ | head -n "$TOTAL" | tail -n 5
echo "=========================================================="
