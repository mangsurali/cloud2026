# Panduan & Rencana Riset: DeathStarBench SocialNetwork pada Klaster Kubernetes (Mode Remote)

Dokumen ini adalah panduan langkah-demi-langkah bagi mahasiswa baru untuk menjalankan **dataset penelitian** berbasis aplikasi microservices **SocialNetwork (DeathStarBench)** pada klaster Kubernetes, dengan pipeline eksperimen **Cloud Dynamics** (`workload.csv` + metrik Prometheus → `combined.csv`).

> **Mode Remote (default):** klaster berada di mesin lain (`HOST_IP=10.160.4.43`, diatur di `config/experiment.env`). Load test dan penarikan metrik berjalan penuh dari mesin ini via HTTP (ingress `*.sslip.io`) — **tidak perlu kubectl**. Kubectl hanya dibutuhkan untuk deploy, Jaeger trace, dan pod-kill (lihat §5).

---

## 1. Analisis Lingkungan & Arsitektur

### 1.1 Apa itu DeathStarBench & SocialNetwork?
* **DeathStarBench** adalah suite *benchmark* standar riset komputasi awan untuk sistem terdistribusi nyata.
* **SocialNetwork** adalah sistem media sosial (Twitter-like) ~27 microservices:
  * **Frontend API:** `nginx-thrift` (OpenResty + Thrift RPC).
  * **Business Logic:** `user-service`, `social-graph-service`, `compose-post-service`, `home-timeline-service`, `user-timeline-service`, `text-service`, `unique-id-service`, `url-shorten-service`, `media-service`.
  * **Cache:** Redis & Memcached (multi-instance).
  * **Database:** MongoDB (multi-instance).
  * **Observability:** Jaeger (tracing).

### 1.2 Jalur Pemanggilan per Endpoint (inti pengujian arsitektur microservice)
| Endpoint | Rantai service | Karakter |
|---|---|---|
| `GET user-timeline/read` | nginx → user-timeline → redis/mongodb | Baca terpendek (lower bound) |
| `GET home-timeline/read` | nginx → home-timeline → redis → post-storage → ... | Baca fan-out |
| `POST post/compose` | nginx → compose-post → text → unique-id → post-storage → user-timeline → media | Tulis terpanjang (5+ service, 3 DB) |

Membandingkan skenario per-endpoint = membedah kontribusi tiap jalur arsitektur terhadap latency.

### 1.3 Format Output (standar Cloud Dynamics)
Setiap run menghasilkan folder di `results/<EXPERIMENT_ID>/`:
* `workload.csv` — metrik klien per detik (RPS, sukses/gagal, latency mean/p95).
* `measurement-window.env`, `metadata.json`, `experiment.env`, `scenario.env`.
* `metrics/` — ekstrak Prometheus (CPU, memori, jaringan, restart, pod ready per pod).
* `combined.csv` — workload + metrik klaster gabungan, siap analisis Jupyter.

---

## 2. Rencana Penelitian: 12 Skenario × 3 Replicate

| Fase | # | Skenario | Perintah | Tujuan |
|---|---|---|---|---|
| **0 — Baseline** | 1 | Mixed 25 RPS 60s | `./scripts/run-dsb-scenario.sh 01-baseline-mixed 1` | Titik acuan kinerja |
| **1 — Pemetaan jalur** | 2 | Read user-timeline | `./scripts/run-dsb-scenario.sh 02-read-user-timeline 1` | Jalur baca terpendek |
| | 3 | Read home-timeline | `./scripts/run-dsb-scenario.sh 03-read-home-timeline 1` | Biaya fan-out read |
| | 4 | Compose post | `./scripts/run-dsb-scenario.sh 04-compose-post 1` | Biaya jalur tulis terpanjang |
| | 5 | Mixed high-load 50 RPS | `./scripts/run-dsb-scenario.sh 05-mixed-highload 1` | Interaksi antar jalur |
| **2 — Dinamika beban** | 6 | Ramp 5→40 RPS / 120s | `./scripts/run-dsb-scenario.sh 06-ramp-mixed 1` | Titik jenuh (knee point) |
| | 7 | Overload 100 RPS | `./scripts/run-dsb-scenario.sh 07-overload-mixed 1` | Identifikasi bottleneck |
| | 8 | Burst 10→50 RPS | `./scripts/run-dsb-scenario.sh 08-burst-mixed 1` | Elastisitas & pemulihan |
| **3 — Arsitektur lanjutan** | 9 | Read-heavy (95% baca) | `./scripts/run-dsb-scenario.sh 09-read-heavy 1` | isolasi jalur baca |
| | 10 | Write-heavy (50% tulis) | `./scripts/run-dsb-scenario.sh 10-write-heavy 1` | Biaya relatif jalur tulis |
| | 11 | Jaeger trace | `./scripts/run-jaeger-trace.sh 1` | Distribusi latency **per-hop** antar microservice |
| | 12 | Pod-kill saat load | `./scripts/run-pod-kill-test.sh home-timeline-service 1` | Ketahanan (resilience) & self-healing |

**Replicate:** jalankan tiap skenario dengan argumen `1`, `2`, `3` → 3 hasil per skenario (mean ± std dev).

**Jalankan semua otomatis (±90 menit):**
```bash
./scripts/run-all-research.sh          # 3 replicate, semua fase
./scripts/run-all-research.sh 1        # 1 replicate dulu (eksplorasi cepat)
./scripts/run-all-research.sh 3 "Fase 0 Fase 1"   # hanya fase tertentu
```

---

## 3. Persiapan (sekali saja)

### Langkah 0: Cek konektivitas remote
```bash
cd research-plan
./scripts/0-connect-remote.sh
```
Harus menampilkan `[OK]` untuk App dan Prometheus. (Kubectl opsional — hanya untuk fase 3 bagian Jaeger/pod-kill.)

### Langkah 1 & 2: Deploy + seeding (hanya bila aplikasi belum ada di klaster)
Kedua langkah ini butuh kubectl. Bila aplikasi **sudah ter-deploy** di `10.160.4.43`, lewati ke §4.

```bash
# Buka tunnel API server klaster remote (kind API server hanya listen di localhost mesin klaster):
REMOTE_SSH_HOST=<user>@10.160.4.43 ./scripts/0-connect-remote.sh tunnel

# Deploy:
./scripts/1-deploy-socialnetwork.sh
# Tunggu pod Running:
kubectl get pods -n cloud-dynamics

# Seeding data (50 user, dataset soc-small):
./scripts/2-init-data.sh
```

---

## 4. Menjalankan Pengujian (tanpa kubectl)

```bash
# Contoh: baseline 3 replicate:
./scripts/run-dsb-scenario.sh 01-baseline-mixed 1
./scripts/run-dsb-scenario.sh 01-baseline-mixed 2
./scripts/run-dsb-scenario.sh 01-baseline-mixed 3
```
Pindahkan argumen replicate untuk skenario lain sesuai tabel §2. File konfigurasi tiap run ikut tersimpan di folder hasil (`scenario.env`, `experiment.env`) sehingga dataset dapat direproduksi.

Atau manual per langkah (format sama):
```bash
./scripts/3-run-experiment.sh scenarios/research-01-baseline-mixed.env
./scripts/4-collect-metrics.sh results/<EXPERIMENT_ID>
```

### Skenario khusus (fase 3) — butuh kubectl + tunnel
```bash
REMOTE_SSH_HOST=<user>@10.160.4.43 ./scripts/0-connect-remote.sh tunnel   # sekali saja

# Skenario 11 — trace per-hop (output: traces.json, traces-summary.csv):
./scripts/run-jaeger-trace.sh 1

# Skenario 12 — matikan pod di tengah load (output: pod-kill.json):
./scripts/run-pod-kill-test.sh home-timeline-service 1
```

---

## 5. Catatan Teknis Mode Remote

* **App**: `http://social-network.10.160.4.43.sslip.io` (ingress Nginx, hostPort 80/443 di mesin klaster).
* **Prometheus**: `http://prometheus.10.160.4.43.sslip.io`.
* **API server Kind** (`https://<mesin-klaster>:16443`) hanya listen di `localhost` mesin klaster → gunakan SSH tunnel (§3) untuk kubectl.
* Ganti klaster lain: `export HOST_IP=<ip>` sebelum menjalankan skrip, atau ubah default di `config/experiment.env`.
* Mode lokal: `export HOST_IP=127.0.0.1`.
* Timeout: `REQUEST_TIMEOUT=5` detik di `config/experiment.env` — naikkan bila latensi remote tinggi.
* Untuk dataset penuh dengan 962 user (dataset `socfb-Reed98`), ubah `MAX_USER_INDEX=962` dan jalankan ulang seeding dengan dataset lengkap (proses seeding ± beberapa menit).

---

## 6. Struktur Berkas

```text
research-plan/
├── config/
│   └── experiment.env                  # HOST_IP (remote), timeout, MAX_USER_INDEX
├── scenarios/
│   ├── research-01-baseline-mixed.env  # ... s/d research-10-write-heavy.env
│   ├── dsb-*.env                       # skenario DSB legacy
│   └── constant.env / ramp.env / burst.env   # profil cloud-dynamics
├── scripts/
│   ├── 0-connect-remote.sh             # [Persiapan] cek remote + SSH tunnel
│   ├── 1-deploy-socialnetwork.sh       # [Persiapan] deploy (butuh kubectl)
│   ├── 2-init-data.sh                  # [Persiapan] seeding (butuh kubectl)
│   ├── loadgen-socialnetwork.py        # engine beban (mixed/read-heavy/write-heavy/dll)
│   ├── 3-run-experiment.sh             # eksekusi 1 run + metadata
│   ├── 4-collect-metrics.sh            # tarik metrik Prometheus → combined.csv
│   ├── run-dsb-scenario.sh             # ★ runner 1 skenario (load + metrik)
│   ├── run-jaeger-trace.sh             # ★ skenario 11: trace per-hop
│   ├── run-pod-kill-test.sh            # ★ skenario 12: fault injection
│   └── run-all-research.sh             # ★ jalankan semua rangkaian otomatis
└── results/                            # dataset penelitian (per EXPERIMENT_ID)
```
