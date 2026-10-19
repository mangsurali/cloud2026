# Panduan & Rencana Riset: DeathStarBench SocialNetwork pada Klaster Kubernetes Homelab

Dokumen ini disusun khusus sebagai panduan lengkap dan terstruktur bagi mahasiswa baru untuk memahami, mendeploy, dan menguji aplikasi microservices **SocialNetwork (DeathStarBench)** pada klaster Kubernetes lokal, serta mengintegrasikannya dengan pipeline eksperimen **Cloud Dynamics**.

---

## 1. Analisis Lingkungan & Arsitektur

### 1.1 Apa itu DeathStarBench & SocialNetwork?
* **DeathStarBench** adalah suite *benchmark* standar industri dan riset komputasi awan yang merepresentasikan sistem komputasi terdistribusi nyata.
* **SocialNetwork** adalah sistem media sosial (arsitektur Twitter-like) yang terdiri dari ~30 microservices independen:
  * **Frontend / Ingress API:** `nginx-thrift` (OpenResty + modul Thrift RPC).
  * **Core Business Logic Services:** `user-service`, `social-graph-service`, `compose-post-service`, `home-timeline-service`, `user-timeline-service`, `text-service`, `unique-id-service`, `url-shorten-service`, `media-service`.
  * **Cache Layer:** Multi-cluster Redis dan Memcached.
  * **Database Layer:** Multi-instance MongoDB.
  * **Tracing & Observability:** Jaeger & Linkerd Service Mesh.

### 1.2 Hubungan dengan Homelab `cloud2023`
* Klaster lokal dibangun dengan **Kind** (Kubernetes in Docker) melalui panduan `cloud2023/kubernetes/setup-cluster/kind/setup-all.sh`.
* Ingress Controller yang digunakan adalah **Ingress Nginx**, yang meneruskan domain berformat `*.sslip.io` ke service di dalam klaster.
* Framework pengujian `cloud2023/kubernetes/research/cloud-dynamics-experiments` membutuhkan file output standar: `workload.csv`, `metadata.json`, dan `measurement-window.env` agar data metrik Prometheus dapat diekstraksi secara otomatis melalui `cloud-dynamics-metrics`.

---

## 2. Jawaban atas 4 Pertanyaan Kunci

### Pertanyaan 1: Bagaimana saya mendeploy SocialNetwork ke cluster yang sudah saya setup?
SocialNetwork di-deploy menggunakan paket **Helm Chart** resmi yang sudah tersedia di folder `DeathStarBench/socialNetwork/helm-chart/socialnetwork`.
1. Helm akan membuat seluruh deployment, service, dan configmap untuk ~30 microservices ke dalam namespace `cloud-dynamics`.
2. Sebuah objek **Ingress** dibuat untuk menghubungkan Ingress Nginx klaster lokal ke frontend `nginx-thrift` port `8080` dengan nama domain `social-network.${HOST_IP}.sslip.io`.
3. Skrip otomatisasi telah disediakan di: `research-plan/scripts/1-deploy-socialnetwork.sh`.

### Pertanyaan 2: Bagaimana saya menjalankan tes skenarionya jika aplikasi sudah terdeploy?
1. **Syarat Awal (Data Seeding):** Aplikasi SocialNetwork membutuhkan data akun dan relasi follower sebelum linimasa dapat dibaca. Gunakan skrip `DeathStarBench/socialNetwork/scripts/init_social_graph.py` untuk mendaftarkan akun awal dari dataset graf `socfb-Reed98`.
2. **Komposisi Beban Realistis:** Pengujian DeathStarBench mensimulasikan aktivitas pengguna asli:
   * **60%** Membaca linimasa beranda (`GET /wrk2-api/home-timeline/read`)
   * **30%** Membaca linimasa profil (`GET /wrk2-api/user-timeline/read`)
   * **10%** Membuat postingan baru (`POST /wrk2-api/post/compose`)
3. Skenario eksisting di lab (`constant`, `ramp`, `burst`, dll.) tetap dipakai untuk mengatur dinamika request per second (RPS) terhadap komposisi beban tersebut.

### Pertanyaan 3: Standarisasi format skrip test scenario agar sama dengan `cloud-dynamics-experiments`
Skrip pengujian bawaan (`wrk2`) menghasilkan format yang tidak cocok dengan pipeline metrik lab.
Oleh karena itu, dibuatkan engine **`research-plan/scripts/loadgen-socialnetwork.py`**:
* Menghasilkan file **`workload.csv`** dengan kolom identik:
  `timestamp_epoch, elapsed_s, target_rps, sent, success, failed, achieved_rps, mean_latency_ms, p95_latency_ms`
* Menghasilkan file **`measurement-window.env`** dan **`metadata.json`** yang kompatibel langsung dengan skrip penarik metrik `cloud-dynamics-metrics/scripts/collect-experiment.sh`.

### Pertanyaan 4: Skrip-skrip implementasi dan urutan menjalankannya
Struktur berkas yang telah dibuat di direktori `research-plan/`:
```text
research-plan/
├── config/
│   └── experiment.env              # Konfigurasi dasar target & durasi
├── scenarios/
│   ├── constant.env                # Profil beban konstan
│   ├── ramp.env                    # Profil beban meningkat (ramp-up)
│   └── burst.env                   # Profil lonjakan tiba-tiba (burst)
├── scripts/
│   ├── 1-deploy-socialnetwork.sh   # [Langkah 1] Deploy aplikasi ke Kubernetes
│   ├── 2-init-data.sh              # [Langkah 2] Seeding data akun & sosial
│   ├── loadgen-socialnetwork.py    # Engine pembuat beban standar Cloud Dynamics
│   ├── 3-run-experiment.sh         # [Langkah 3] Eksekusi skenario uji beban
│   └── 4-collect-metrics.sh        # [Langkah 4] Tarik metrik Prometheus
└── results/                        # Direktori penyimpan hasil pengujian
```

---

## 3. Panduan Langkah Demi Langkah (Step-by-Step)

### Langkah 0: Pastikan Klaster Lab Sudah Berjalan
Bila klaster Kind belum dibuat, jalankan setup dari homelab:
```bash
cd /home/ali/kuliah/komputasi-awan/cloud2023/kubernetes/setup-cluster/kind
./setup-all.sh
```

### Langkah 1: Deploy SocialNetwork ke Kubernetes
Masuk ke direktori `research-plan` dan jalankan skrip deployment:
```bash
cd /home/ali/kuliah/komputasi-awan/research-plan
./scripts/1-deploy-socialnetwork.sh
```
*Periksa kesiapan pod dengan perintah:*
```bash
kubectl get pods -n cloud-dynamics
```
*(Tunggu hingga status pod bertransisi menjadi `Running`)*

### Langkah 2: Inisialisasi Data Pengguna & Graf Sosial
Isi data awal pengguna agar endpoint linimasa dapat merespons:
```bash
./scripts/2-init-data.sh
```

### Langkah 3: Jalankan Skenario Eksperimen

#### Opsi A: Menggunakan Skenario Bawaan DeathStarBench (All-in-One + Auto Collect Metrics)
Anda dapat langsung menjalankan skenario bawaan DeathStarBench lengkap dengan ekstraksi metrik otomatis:
```bash
# 1. Skenario baca beranda (100% Read Home Timeline):
./scripts/run-dsb-scenario.sh read-home-timeline

# 2. Skenario baca profil user (100% Read User Timeline):
./scripts/run-dsb-scenario.sh read-user-timeline

# 3. Skenario membuat postingan (100% Compose Post):
./scripts/run-dsb-scenario.sh compose-post

# 4. Skenario campuran resmi DeathStarBench (60% Home, 30% User, 10% Compose):
./scripts/run-dsb-scenario.sh mixed-workload
```

#### Opsi B: Menggunakan File Skenario Cloud Dynamics
```bash
# Uji beban konstan:
./scripts/3-run-experiment.sh scenarios/constant.env

# Atau uji beban bertahap (ramp-up):
./scripts/3-run-experiment.sh scenarios/ramp.env

# Setelah itu tarik metrik secara manual:
./scripts/4-collect-metrics.sh results/<NAMA_FOLDER_EXPERIMENT_ID>
```
