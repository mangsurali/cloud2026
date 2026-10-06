# Tutorial Eksperimen Tingkat Lanjut: Event-Driven API & Workload Kompleks

Tutorial ini akan memandu Anda secara langkah demi langkah untuk membangun dan melakukan *deploy* aplikasi asinkron (`event-driven-api`) ke klaster Kubernetes, memberikan beban kerja (*workload*) menggunakan skenario kompleks, hingga mengekstraksi data hasil metrik dan *workload* (dataset) untuk keperluan analisis.

---

## Tahap 1: Persiapan dan Deploy Aplikasi Target

Pada tahap ini, kita akan menggunakan *bundle* `cloud-dynamics-applications` untuk membuat *image* dari arsitektur *event-driven*, dan menjalankannya di klaster Kubernetes lokal (seperti `kind`).

1. **Masuk ke direktori aplikasi:**
   ```bash
   cd cloud-dynamics-applications
   ```

2. **Build dan Load Image:**
   Perintah ini akan membaca `Dockerfile` dari aplikasi, membangun Docker Image-nya, lalu me-muat *image* tersebut ke dalam klaster Kubernetes lokal Anda.
   ```bash
   ./scripts/build-and-load.sh event-driven-api
   ```

3. **Deploy ke Kubernetes:**
   Perintah ini akan menerapkan (*apply*) manifes `event-driven-api.yaml` yang berisi API Gateway, barisan Worker, Redis, RabbitMQ, dan PostgreSQL.
   ```bash
   ./scripts/deploy.sh event-driven-api
   ```
   *Catatan: Tunggu beberapa saat hingga semua Pod dalam status `Running` (terutama Postgres dan RabbitMQ karena membutuhkan waktu inisiasi yang sedikit lebih lama).*

4. **Lakukan Smoke-Test:**
   Pastikan *endpoint* utama sudah merespons dengan baik sebelum diberikan beban besar.
   ```bash
   ./scripts/smoke-test.sh event-driven-api
   ```
   Jika sukses, *output* akan menampilkan JSON seperti `{"order_id":"...","status":"accepted"}`.

---

## Tahap 2: Menjalankan Eksperimen Skenario Kompleks

Setelah aplikasi `event-driven-api` berjalan lancar, kita akan memberinya beban *workload* tingkat lanjut. Kita berpindah ke *bundle* eksperimen.

1. **Masuk ke direktori eksperimen:**
   ```bash
   cd ../cloud-dynamics-experiments
   ```

2. **Menentukan URL Target:**
   Atur aplikasi mana yang ingin Anda serang dengan *load generator*.
   ```bash
   export TARGET_URL="http://event-driven-api.127.0.0.1.sslip.io/"
   ```
   *(Ganti `127.0.0.1` dengan IP *Node* Kubernetes Anda jika berjalan di mesin remote atau server terpisah).*

3. **Jalankan Skenario Eksperimen Pilihan:**

   **Opsi A: Skenario Staircase (Anak Tangga)**
   Digunakan untuk mengamati *threshold* (ambang batas) kapasitas secara presisi.
   ```bash
   ./scripts/run-experiment.sh scenarios/staircase.env
   ```

   **Opsi B: Skenario Spiky Diurnal (Pola Gelombang + Kejutan)**
   Digunakan untuk mensimulasikan trafik dunia nyata (fluktuatif) yang terkadang memunculkan lonjakan mendadak (*micro-bursts*).
   ```bash
   ./scripts/run-experiment.sh scenarios/spiky-diurnal.env
   ```

   **Opsi C: Skenario Overload (Uji Resiliensi)**
   Digunakan untuk membanjiri antrean (RabbitMQ) dan mengevaluasi sistem setelah dibombardir secara agresif.
   ```bash
   ./scripts/run-experiment.sh scenarios/overload.env
   ```

   **Opsi D: Skenario Mixed Read/Write**
   Digunakan jika Anda ingin menembak beberapa endpoint acak dengan persentase tertentu. *Anda perlu menjalankan ini dengan sedikit argumen tambahan (opsional):*
   ```bash
   export TARGET_URL="http://event-driven-api.127.0.0.1.sslip.io/,http://event-driven-api.127.0.0.1.sslip.io/health"
   export URL_WEIGHTS="80,20"
   ./scripts/run-experiment.sh scenarios/mixed-rw.env
   ```

4. **Catat ID Eksperimen:**
   Ketika script selesai berjalan, perhatikan `Experiment ID` yang tertera pada baris terakhir di terminal (misal: `staircase-20261006T140000Z-r1`). ID inilah yang akan kita ekstrak datanya.

---

## Tahap 3: Ekstraksi Data (Dataset Collection)

Trafik dari eksperimen telah di-generate, kini saatnya menarik data penggunaan CPU, Memori, dan antrean (RabbitMQ) dari Prometheus agar tersinkronisasi.

1. **Masuk ke direktori metrik:**
   ```bash
   cd ../cloud-dynamics-metrics
   ```

2. **Cek Koneksi Prometheus:**
   Pastikan Prometheus Anda beroperasi secara wajar.
   ```bash
   ./scripts/check-prometheus.sh
   ```

3. **Kumpulkan Dataset:**
   Jalankan script kolektor dengan merujuk pada *path* hasil ID eksperimen Anda di langkah sebelumnya. 
   *(Ganti `<EXPERIMENT_ID>` dengan ID aktual hasil di Tahap 2, contoh: `staircase-20261006T140000Z-r1`).*
   ```bash
   ./scripts/collect-experiment.sh ../cloud-dynamics-experiments/results/<EXPERIMENT_ID>
   ```

4. **Verifikasi Dataset:**
   Jika berhasil, kolektor akan menempelkan data pemakaian *resource* dari Prometheus secara rata menyamping (di-join berdasarkan stempel waktu/timestamp) ke data beban. Buka dan analisis datanya:
   ```bash
   cat ../cloud-dynamics-experiments/results/<EXPERIMENT_ID>/combined.csv
   ```
   Di dalam file `combined.csv` ini, Anda dapat membandingkan:
   * Kolom `achieved_rps` (seberapa kencang tembakan request dari klien)
   * Kolom `mean_latency_ms` (seberapa cepat API merespons)
   * Kolom `CPU_USAGE` (seberapa tinggi CPU Worker bekerja)
   * Kolom `RABBITMQ_QUEUE_MESSAGES` (seberapa panjang antrean menumpuk)

## Selesai!
Sekarang Anda memiliki himpunan data (`dataset`) komprehensif yang siap divisualisasikan dalam bentuk grafik atau diimpor ke Jupyter Notebook (Python/Pandas) untuk penelitian analisis yang mendalam terkait rekayasa keandalan perangkat lunak di Cloud.
