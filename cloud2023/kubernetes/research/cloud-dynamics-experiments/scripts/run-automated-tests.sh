#!/usr/bin/env bash
# ==============================================================================
# Script Otomasi Pengujian Homelab Cloud Dynamics Experiments
# ==============================================================================
# Ketentuan sesuai README.md:
# 1. Menjalankan baseline scenario terlebih dahulu (constant.env)
# 2. Mendukung pengulangan (replicate) untuk baseline maupun skenario lainnya
# 3. Menyediakan array skenario lanjutan yang fleksibel dan mudah disesuaikan
# 4. Melakukan pra-pemeriksaan lingkungan (check-environment) sebelum pengujian
# 5. Memberikan jeda / cool-down tambahan antar skenario jika diperlukan
# ==============================================================================

set -euo pipefail

# Direktori dasar
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# ------------------------------------------------------------------------------
# Konfigurasi Pengujian & Array Skenario
# ------------------------------------------------------------------------------

# Skenario baseline wajib di awal
BASELINE_SCENARIO="scenarios/constant.env"

# Jumlah repetisi/replikasi untuk baseline (sesuai README section 17)
BASELINE_REPLICATES=5

# Array skenario lanjutan yang bisa Anda sesuaikan/tambahkan/kurangi
# Skenario yang tersedia di scenarios/:
#   - ramp.env
#   - burst.env
#   - periodic.env
#   - variable.env
#   - staircase.env
#   - spiky-diurnal.env
#   - overload.env
#   - mixed-rw.env
SUBSEQUENT_SCENARIOS=(
    "scenarios/ramp.env"
    "scenarios/burst.env"
    "scenarios/periodic.env"
    "scenarios/variable.env"
)

# Jumlah repetisi/replikasi untuk skenario lanjutan
SUBSEQUENT_REPLICATES=5

# Jeda waktu istirahat antar pengujian yang berbeda (dalam detik)
INTER_EXPERIMENT_PAUSE=15

# ------------------------------------------------------------------------------
# Fungsi Bantu
# ------------------------------------------------------------------------------

run_test() {
    local scenario_path="$1"
    local replicate_num="$2"
    local phase_label="$3"

    echo ""
    echo "========================================================================"
    echo "[$phase_label] Menjalankan: $scenario_path (Replicate: $replicate_num)"
    echo "Waktu mulai : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================================"

    REPLICATE="$replicate_num" "$ROOT_DIR/scripts/run-experiment.sh" "$scenario_path"

    echo "Selesai: $scenario_path (Replicate: $replicate_num)"
    if [ "$INTER_EXPERIMENT_PAUSE" -gt 0 ]; then
        echo "Menunggu jeda stabilisasi tambahan ${INTER_EXPERIMENT_PAUSE}s..."
        sleep "$INTER_EXPERIMENT_PAUSE"
    fi
}

# ------------------------------------------------------------------------------
# Eksekusi Utama
# ------------------------------------------------------------------------------

echo "=== Memulai Alur Pengujian Cloud Dynamics Experiments ==="
echo "Working directory: $ROOT_DIR"

# 1. Pengecekan Environment
echo ""
echo "-> Langkah 1: Pengecekan Lingkungan (check-environment.sh)"
if ! "$ROOT_DIR/scripts/check-environment.sh"; then
    echo "ERROR: Pemeriksaan lingkungan gagal. Pastikan target reachable sebelum lanjut." >&2
    exit 1
fi

# 2. Menjalankan Baseline Scenario (constant)
echo ""
echo "-> Langkah 2: Menjalankan Baseline Scenario ($BASELINE_SCENARIO)"
if [ ! -f "$ROOT_DIR/$BASELINE_SCENARIO" ] && [ ! -f "$BASELINE_SCENARIO" ]; then
    echo "ERROR: File baseline '$BASELINE_SCENARIO' tidak ditemukan!" >&2
    exit 1
fi

for (( r=1; r<=BASELINE_REPLICATES; r++ )); do
    run_test "$BASELINE_SCENARIO" "$r" "BASELINE"
done

# 3. Menjalankan Skenario Lanjutan dari Array
echo ""
echo "-> Langkah 3: Menjalankan Skenario Lanjutan"
for scenario in "${SUBSEQUENT_SCENARIOS[@]}"; do
    if [ ! -f "$ROOT_DIR/$scenario" ] && [ ! -f "$scenario" ]; then
        echo "PERINGATAN: Skenario '$scenario' tidak ditemukan, dilewati." >&2
        continue
    fi

    for (( r=1; r<=SUBSEQUENT_REPLICATES; r++ )); do
        run_test "$scenario" "$r" "LANJUTAN"
    done
done

echo ""
echo "========================================================================"
echo "SEMUA PENGUJIAN SELESAI DENGAN SUKSES!"
echo "Hasil pengujian tersimpan pada: $ROOT_DIR/results/"
echo "Waktu selesai: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================================"
