# Panduan Replikasi Environment Penelitian (Langkah Demi Langkah)

Panduan ini mereplikasi environment penelitian **dari nol** — dari klaster kosong sampai dataset penelitian terkumpul. Ada **2 mesin**:

| Mesin | Peran | IP (contoh) |
|---|---|---|
| **Server** | Setup klaster, deploy aplikasi, injeksi Linkerd | `10.160.4.43` |
| **Lokal** | Menjalankan skenario pengujian (load generator) | mesin Anda |

Semua skrip ada di folder `research-plan/` dalam repo ini. Skrip di server butuh `kubectl`; skrip di lokal **hanya HTTP** (tidak butuh kubectl).

---

## BAGIAN A — SERVER (10.160.4.43)

### A0. Prasyarat mesin
* Linux + Docker berjalan + akses `sudo`
* `git`, `python3` + `pip install aiohttp`, `curl`
* Port 80, 443, 30080, 30443 terbuka (ingress), 16443 untuk API server Kind

### A1. Ambil repo + binary Kubernetes
```bash
git clone <URL-REPO-ANDA> kuliah && cd kuliah

# Binary kind, kubectl, helm, linkerd CLI:
cd cloud2023/kubernetes/bin
sh download.sh
cd ../..
export PATH="$PWD/cloud2023/kubernetes/bin:$PATH"
```

### A2. Set HOST_IP di config homelab
```bash
# cloud2023/kubernetes/setup-cluster/supporting/variables.sh — isi dengan IP server:
echo "HOST_IP=10.160.4.43
export HOST_IP" > cloud2023/kubernetes/setup-cluster/supporting/variables.sh

# research-plan/config/experiment.env — baris HOST_IP sudah default 10.160.4.43
grep HOST_IP research-plan/config/experiment.env
```

### A3. Setup klaster Kind + Ingress + Prometheus + Linkerd (satu perintah)
```bash
cd cloud2023/kubernetes/setup-cluster/kind
sh setup-all.sh
```
Script ini otomatis: membuat klaster `mylab99` (1 control-plane + 3 worker, API server port 16443) → export kubeconfig → install Nginx Ingress → install Prometheus+Grafana → install Linkerd + Viz.

Verifikasi:
```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes                     # 4 node Ready
kubectl get pods -n monitoring        # prometheus & grafana Running
kubectl get pods -n linkerd           # kontrol plane linkerd Running
```

### A4. Deploy SocialNetwork
```bash
cd ~/kuliah/research-plan
./scripts/1-deploy-socialnetwork.sh
# Tunggu semua pod Running (±5 menit, initContainer clone image):
kubectl get pods -n cloud-dynamics -w    # Ctrl-C untuk keluar
```

### A5. Seeding data awal (50 user, dataset soc-small)
```bash
HOST_IP=10.160.4.43 ./scripts/2-init-data.sh
```

### A6. Injeksi sidecar Linkerd (skenario monitoring)
```bash
./scripts/inject-linkerd.sh
```
Otomatis: annotate namespace → rollout restart semua deployment → tunggu pod `2/2` (aplikasi + `linkerd-proxy`) → verifikasi metrik `response_total` muncul → **seeding ulang** (data hilang saat restart) → smoke test.

### A7. Pastikan app & Prometheus terjangkau dari luar
```bash
curl -o /dev/null -w "%{http_code}\n" http://social-network.10.160.4.43.sslip.io/        # harus 200
curl -o /dev/null -w "%{http_code}\n" http://prometheus.10.160.4.43.sslip.io/-/ready     # harus 200
```
Bila gagal: cek firewall port 80/443, dan `kubectl get ingress -n cloud-dynamics`.

> Selesai untuk server. Skrip selanjutnya dijalankan dari **mesin lokal**.

---

## BAGIAN B — MESIN LOKAL

### B1. Ambil repo + prasyarat
```bash
git clone <URL-REPO-ANDA> kuliah && cd kuliah/research-plan
# Cukup: python3, curl, bash. TIDAK butuh kubectl/docker.
```

### B2. Cek konektivitas
```bash
./scripts/0-connect-remote.sh
```
Harus menampilkan `[OK]` untuk App dan Prometheus (Kubectl `--` tidak masalah — hanya dibutuhkan skenario 11/12).

### B3. Validasi cepat (opsional, ~1 menit)
```bash
# Uji load singkat 15 detik:
DURATION=15 WARMUP_SECONDS=5 COOLDOWN_SECONDS=3 ./scripts/run-dsb-scenario.sh 01-baseline-mixed 1
```

### B4. Jalankan dataset penelitian
```bash
# Eksplorasi cepat — semua 10 skenario, 1 replicate (±25 menit):
./scripts/run-all-research.sh 1

# Dataset final — 10 skenario × 3 replicate (±90 menit):
./scripts/run-all-research.sh 3

# Atau per skenario (argumen ke-2 = replicate):
./scripts/run-dsb-scenario.sh 01-baseline-mixed 1
./scripts/run-dsb-scenario.sh 06-ramp-mixed 2
```

### B5. Skenario khusus Linkerd (butuh sidecar dari A6)
```bash
./scripts/run-linkerd-monitor.sh 1     # lalu 2, 3
```

### B6. Skenario 11 & 12 (butuh kubectl — jalankan di server atau via tunnel)
```bash
# Pilihan 1: SSH tunnel sekali, lalu jalan dari lokal:
REMOTE_SSH_HOST=<user>@10.160.4.43 ./scripts/0-connect-remote.sh tunnel
./scripts/run-jaeger-trace.sh 1
./scripts/run-pod-kill-test.sh home-timeline-service 1
```

---

## CATATAN HASIL (dataset penelitian)

Semua run tersimpan di `research-plan/results/<EXPERIMENT_ID>/`:

```text
workload.csv              # beban klien per detik (RPS, sukses, latency p95)
measurement-window.env    # jendela waktu pengukuran (epoch)
metadata.json             # konfigurasi run (reproduksi)
combined.csv              # workload + metrik klaster (CPU, memori, jaringan per pod)
metrics/                  # CSV mentah per metrik Prometheus
scenario.env, experiment.env  # salinan konfigurasi — dataset reproducible
```
Tambahan untuk skenario Linkerd: `linkerd-metrics/*.csv` (per pod) + `linkerd-summary.csv` (per service).

**Struktur run:** Fase 0 (baseline) → Fase 1 (pemetaan jalur per endpoint) → Fase 2 (dinamika beban) → Fase 3 (read/write-heavy, Linkerd) — lihat tabel di `README.md` §2.

---

## PEMECAHAN MASALAH UMUM

| Gejala | Penyebab | Solusi |
|---|---|---|
| `dial tcp [::1]:8080: connect: connection refused` | kubeconfig tidak ditemukan | Jalankan di server; cek `export KUBECONFIG=~/kuliah/cloud2023/kubernetes/setup-cluster/kind/kubeconfig` |
| HTTP 000/503 dari lokal | Firewall port 80/443 di server | Buka port; cek `kubectl get ingress -n cloud-dynamics` |
| `metrik Linkerd kosong` | Sidecar belum ter-injeksi | Jalankan `./scripts/inject-linkerd.sh` di **server**, tunggu ~1 menit |
| Pod `ImagePullBackOff` | Registry lambat/blokir | Cek `kubectl describe pod <pod> -n cloud-dynamics`; klaster sudah di-set mirror `10.21.84.254:8443` |
| Seeding gagal setelah injeksi | Data emptyDir hilang (normal) | `inject-linkerd.sh` sudah seeding ulang; manual: `./scripts/2-init-data.sh` |
| Latensi remote lebih tinggi | Jaringan WiFi/LAN | Naikkan `REQUEST_TIMEOUT` di `config/experiment.env` |
| Ganti ke klaster lain | IP berbeda | `export HOST_IP=<ip-baru>` sebelum menjalankan skrip |
