# Product Requirements Document (PRD)
## ElektroPOS — Sistem Kasir & Manajemen Toko Alat Listrik

---

| Field | Detail |
|---|---|
| Versi Dokumen | 1.0.0 |
| Tanggal | September 2026 |
| Status | Draft — Perlu Review |
| Author | \[Nama Kamu\] |
| Stakeholder | Pemilik Toko (Ayah) |

---

## Daftar Isi

1. [Latar Belakang](#1-latar-belakang)
2. [Tujuan Produk](#2-tujuan-produk)
3. [Ruang Lingkup](#3-ruang-lingkup)
4. [Pengguna & Peran](#4-pengguna--peran)
5. [Asumsi & Batasan](#5-asumsi--batasan)
6. [Fitur & Persyaratan Fungsional](#6-fitur--persyaratan-fungsional)
   - 6.1 Modul Autentikasi
   - 6.2 Modul Kasir & Penjualan
   - 6.3 Modul Inventori
   - 6.4 Modul Jasa Perbaikan (Work Order)
   - 6.5 Modul Manajemen Pelanggan
   - 6.6 Modul Supplier & Pembelian
   - 6.7 Modul Laporan & Analitik
7. [Persyaratan Non-Fungsional](#7-persyaratan-non-fungsional)
8. [Spesifikasi Teknis](#8-spesifikasi-teknis)
9. [Desain Database](#9-desain-database)
10. [Alur Kerja Utama (User Flow)](#10-alur-kerja-utama-user-flow)
11. [Persyaratan Integrasi Hardware](#11-persyaratan-integrasi-hardware)
12. [Antarmuka & UX Guidelines](#12-antarmuka--ux-guidelines)
13. [Prioritas Pengembangan (Roadmap)](#13-prioritas-pengembangan-roadmap)
14. [Kriteria Keberhasilan](#14-kriteria-keberhasilan)
15. [Risiko & Mitigasi](#15-risiko--mitigasi)
16. [Glosarium](#16-glosarium)

---

## 1. Latar Belakang

Toko alat listrik yang akan dibuka membutuhkan sistem operasional yang efisien sejak hari pertama. Tanpa sistem digital, pencatatan stok dilakukan manual sehingga rawan kehilangan data, salah harga, dan barang habis tanpa diketahui. Selain berjualan produk, toko juga akan membuka layanan **jasa perbaikan alat listrik** yang memerlukan pelacakan pengerjaan secara terpisah dari transaksi penjualan biasa.

ElektroPOS dibangun sebagai solusi satu atap yang mencakup kasir, inventori, work order perbaikan, dan laporan bisnis — dirancang khusus untuk skala toko kecil-menengah dengan satu atau beberapa orang operator.

---

## 2. Tujuan Produk

- Mempercepat proses kasir dengan scan barcode dan OCR
- Mencegah kehilangan stok karena tidak tercatat
- Memberikan visibilitas penuh atas status setiap barang yang masuk untuk diperbaiki
- Menghasilkan laporan keuangan harian secara otomatis tanpa rekap manual
- Dapat dioperasikan dari perangkat yang sudah dimiliki (HP Android, tablet, laptop)

---

## 3. Ruang Lingkup

### Dalam Lingkup (In Scope)

- Aplikasi web (PWA) yang dapat diakses melalui browser
- Modul kasir penjualan produk
- Modul inventori dengan manajemen stok real-time
- Modul work order untuk jasa perbaikan alat listrik
- Modul manajemen pelanggan dan riwayat transaksi
- Modul pembelian barang dari supplier
- Modul laporan penjualan, stok, dan keuangan
- Integrasi barcode scanner USB dan OCR via kamera
- Cetak struk via thermal printer atau kirim via WhatsApp
- Dukungan offline untuk transaksi kasir (Progressive Web App)

### Di Luar Lingkup (Out of Scope) — Versi 1.0

- Aplikasi mobile native (iOS/Android)
- Integrasi marketplace online (Tokopedia, Shopee, dll.)
- Sistem akuntansi lengkap (neraca, arus kas, pajak)
- Multi-cabang / multi-toko
- Loyalty program / poin pelanggan
- Integrasi payment gateway otomatis

---

## 4. Pengguna & Peran

### 4.1 Admin (Pemilik Toko)

Akses penuh ke seluruh sistem. Bertanggung jawab atas pengaturan harga, data produk, dan melihat semua laporan termasuk laporan laba.

**Hak akses:**
- Semua yang bisa dilakukan Kasir dan Teknisi
- Kelola produk (tambah, edit, hapus, atur harga)
- Lihat laporan laba kotor
- Kelola akun pengguna (tambah/nonaktifkan kasir dan teknisi)
- Atur pengaturan sistem (pajak, nama toko, batas stok minimum)
- Hapus atau batalkan transaksi

### 4.2 Kasir

Operator yang bertugas di meja kasir sehari-hari. Hanya bisa melakukan transaksi dan melihat stok.

**Hak akses:**
- Buat transaksi penjualan
- Scan barcode dan input produk
- Cari pelanggan dan catat piutang
- Buat work order baru
- Lihat stok produk (tidak bisa edit harga)
- Cetak struk

### 4.3 Teknisi

Staf yang menangani perbaikan alat. Hanya berinteraksi dengan work order yang ditugaskan padanya.

**Hak akses:**
- Lihat daftar work order yang ditugaskan
- Update status pengerjaan
- Tambah spare part yang digunakan dari inventori
- Tambah catatan teknis dan dokumentasi foto

---

## 5. Asumsi & Batasan

### Asumsi

- Toko memiliki koneksi internet minimal (tidak harus cepat; hanya untuk sinkronisasi)
- Tersedia setidaknya satu perangkat untuk kasir (HP Android / tablet / laptop)
- Pemilik bersedia melakukan input data produk awal ke sistem sebelum go-live
- Produk yang dijual memiliki harga tetap (bukan harga tawar)
- Mata uang yang digunakan adalah Rupiah (IDR)

### Batasan

- Sistem tidak menangani penghitungan pajak (PPN) secara otomatis di versi 1.0 — dapat ditambahkan di versi berikutnya
- OCR untuk nota supplier bersifat semi-otomatis; tetap perlu konfirmasi manual sebelum data disimpan
- Cetak struk membutuhkan thermal printer yang terhubung ke perangkat kasir
- Laporan laba hanya mencakup laba kotor (harga jual dikurangi harga beli); tidak termasuk biaya operasional

---

## 6. Fitur & Persyaratan Fungsional

---

### 6.1 Modul Autentikasi

#### FR-AUTH-01 — Login Pengguna
- Sistem harus menyediakan halaman login dengan field username dan password
- Sistem harus memvalidasi kredensial terhadap database
- Setelah login berhasil, pengguna diarahkan ke dashboard sesuai peran (Admin, Kasir, atau Teknisi)
- Session aktif selama 8 jam; setelah itu pengguna diminta login ulang

#### FR-AUTH-02 — Manajemen Akun (Admin only)
- Admin dapat menambah akun pengguna baru dengan menetapkan nama, username, password, dan peran
- Admin dapat menonaktifkan akun tanpa menghapus riwayat transaksinya
- Admin dapat mereset password pengguna lain

#### FR-AUTH-03 — Keamanan Sesi
- Password disimpan dalam bentuk hash (bcrypt)
- Tidak ada fitur "lupa password" di versi 1.0 (reset dilakukan oleh Admin)
- Satu akun hanya bisa login di satu perangkat dalam satu waktu

---

### 6.2 Modul Kasir & Penjualan

#### FR-POS-01 — Layar Kasir Utama
- Layar kasir menampilkan: kolom input produk, daftar item keranjang, ringkasan harga (subtotal, diskon, total)
- Tombol aksi yang selalu terlihat: Bayar, Tahan Transaksi, Bersihkan Keranjang

#### FR-POS-02 — Input Produk via Barcode
- Sistem menerima input dari scanner USB barcode (mode HID keyboard)
- Saat barcode dibaca, produk langsung masuk keranjang dengan qty 1
- Jika barcode tidak ditemukan di database, sistem menampilkan dialog untuk tambah produk baru
- Jika produk sudah ada di keranjang, qty bertambah 1 secara otomatis

#### FR-POS-03 — Input Produk via Kamera (Barcode)
- Tersedia tombol "Scan Kamera" yang mengaktifkan kamera perangkat
- Sistem menggunakan library ZXing-js untuk membaca barcode dari kamera
- Format yang didukung: EAN-13, EAN-8, Code 128, Code 39, QR Code
- Setelah barcode terdeteksi, kamera berhenti dan produk masuk keranjang

#### FR-POS-04 — Input Produk via OCR
- Tersedia tombol "Foto Label" yang mengaktifkan kamera
- Pengguna memfoto label harga atau kemasan produk
- Tesseract.js memproses gambar dan mengekstrak teks
- Sistem menampilkan hasil OCR dan pilihan produk yang cocok untuk dikonfirmasi kasir
- Konfirmasi wajib sebelum produk masuk keranjang

#### FR-POS-05 — Input Produk Manual
- Tersedia kolom pencarian produk (by nama atau kode SKU)
- Hasil pencarian ditampilkan sebagai daftar dropdown dengan nama, harga, dan stok tersisa
- Pengguna memilih produk dari daftar; sistem menambahkannya ke keranjang

#### FR-POS-06 — Manajemen Keranjang
- Kasir dapat mengubah qty item langsung di keranjang
- Kasir dapat menghapus item dari keranjang
- Sistem menolak penambahan item jika stok = 0 dan menampilkan peringatan
- Sistem memperingatkan (tidak memblokir) jika qty yang diminta melebihi stok tersedia

#### FR-POS-07 — Diskon
- Diskon dapat diterapkan per item (nominal atau persen)
- Diskon dapat diterapkan untuk total transaksi (nominal atau persen)
- Kedua jenis diskon dapat digunakan bersamaan
- Diskon total tidak boleh melebihi nilai subtotal; sistem memvalidasi

#### FR-POS-08 — Proses Pembayaran
- Pilihan metode: Tunai, Transfer Bank, QRIS
- Untuk Tunai: kasir input jumlah uang diterima; sistem hitung kembalian otomatis
- Untuk Transfer/QRIS: tidak ada penghitungan kembalian; kasir konfirmasi pembayaran diterima
- Tombol bayar cepat dengan nominal umum (Rp 5.000, Rp 10.000, Rp 20.000, Rp 50.000, Rp 100.000) tersedia untuk pembayaran tunai

#### FR-POS-09 — Penyelesaian Transaksi
- Setelah pembayaran dikonfirmasi, transaksi disimpan ke database
- Stok produk berkurang secara real-time sesuai item yang terjual
- Sistem generate nomor transaksi otomatis (format: TRX-YYYYMMDD-XXXX)
- Pengguna ditawarkan pilihan: Cetak Struk, Kirim via WhatsApp, atau Selesai (tanpa struk)

#### FR-POS-10 — Struk
- Struk berisi: nama toko, alamat, nomor telepon, nomor transaksi, tanggal dan jam, daftar item (nama, qty, harga satuan, subtotal), diskon, total, metode bayar, nominal bayar, kembalian, nama kasir
- Format struk thermal: 58mm dan 80mm (dapat dipilih di pengaturan)
- Struk WhatsApp: format teks yang rapi, dapat langsung di-copy atau dibuka di WhatsApp

#### FR-POS-11 — Tahan Transaksi (Hold)
- Kasir dapat menahan transaksi yang sedang berjalan
- Transaksi yang ditahan muncul di daftar "Transaksi Ditunda"
- Kasir dapat melanjutkan transaksi yang ditahan kapan saja
- Maksimal 5 transaksi ditahan secara bersamaan

#### FR-POS-12 — Riwayat Transaksi Hari Ini
- Kasir dapat melihat semua transaksi yang sudah selesai hari ini
- Klik transaksi menampilkan detail lengkap dan opsi cetak ulang struk
- Admin dapat membatalkan transaksi dari riwayat (dengan catatan alasan pembatalan)

#### FR-POS-13 — Mode Offline
- Jika internet terputus, transaksi kasir tetap berjalan menggunakan data lokal (IndexedDB)
- Sistem menampilkan indikator "Offline Mode" yang jelas
- Saat internet kembali, semua transaksi offline disinkronisasi ke server secara otomatis
- Jika ada konflik stok, sistem menandai transaksi untuk direview Admin

---

### 6.3 Modul Inventori

#### FR-INV-01 — Daftar Produk
- Menampilkan semua produk dalam bentuk tabel atau kartu dengan kolom: Foto, Nama, SKU, Kategori, Harga Jual, Stok, Status Stok
- Filter by: Kategori, Status Stok (Normal / Kritis / Habis)
- Pencarian by nama, SKU, atau barcode
- Sorting by nama, stok, atau harga

#### FR-INV-02 — Tambah Produk Baru
- Form input: Nama produk, Kategori, Barcode (scan atau input manual), SKU (auto-generate atau manual), Harga Beli, Harga Jual, Stok Awal, Stok Minimum (batas notifikasi), Satuan (pcs/meter/roll/set), Supplier default, Lokasi rak (opsional), Foto produk (dari kamera atau galeri)
- Sistem memvalidasi: nama tidak boleh duplikat, harga jual tidak boleh lebih rendah dari harga beli (tampilkan peringatan, bukan blokir), barcode harus unik
- Jika produk belum memiliki barcode fisik, sistem dapat generate barcode EAN-13 otomatis

#### FR-INV-03 — Edit Produk
- Semua field dapat diedit kecuali SKU (yang sudah digunakan di transaksi)
- Perubahan harga beli dan harga jual dicatat di riwayat (tidak diganti, tapi ditambahkan entri baru)
- Admin only untuk perubahan harga

#### FR-INV-04 — Manajemen Stok
- Stok berkurang otomatis saat: produk terjual di kasir, spare part dipakai di work order
- Stok bertambah otomatis saat: pembelian barang dari supplier diterima, stok opname dengan penyesuaian positif
- Riwayat mutasi stok tersimpan: tanggal, jenis (jual/beli/opname/koreksi), qty, sumber (nomor transaksi / nomor WO / nomor PO)

#### FR-INV-05 — Notifikasi Stok Kritis
- Sistem menandai produk sebagai "Stok Kritis" jika stok ≤ stok_minimum yang ditetapkan
- Notifikasi muncul di dashboard Admin dan Kasir
- Daftar produk stok kritis dapat diakses sebagai halaman tersendiri
- Admin dapat langsung buat draft Purchase Order dari halaman stok kritis

#### FR-INV-06 — Stok Opname
- Admin dapat memulai sesi stok opname
- Sistem menampilkan stok sistem per produk; Admin input stok fisik aktual
- Sistem menghitung selisih (lebih/kurang)
- Admin mengkonfirmasi penyesuaian; stok diperbarui dan selisih dicatat

#### FR-INV-07 — Kategori Produk
- Admin dapat menambah, edit, dan nonaktifkan kategori
- Kategori default yang disediakan: Kabel & Konduktor, Stop Kontak & Saklar, MCB & Panel, Lampu & Fitting, Alat Ukur, Pipa & Konduit, Spare Part Motor/Pompa, Aksesoris Lain
- Kategori yang masih memiliki produk aktif tidak dapat dihapus

---

### 6.4 Modul Jasa Perbaikan (Work Order)

#### FR-WO-01 — Buat Work Order Baru
- Form input saat barang masuk:
  - Data Pelanggan: Nama, Nomor HP (cari dari database atau input baru)
  - Data Alat: Jenis alat, Merk, Model/Tipe, Nomor seri (opsional)
  - Kondisi masuk: Keluhan yang dilaporkan pelanggan, Kondisi fisik alat (teks), Foto kondisi awal (dari kamera HP, bisa lebih dari satu)
  - Penugasan: Teknisi yang menangani
  - Estimasi: Biaya estimasi (range boleh, contoh: Rp 50.000–100.000), Estimasi waktu selesai
- Sistem generate nomor WO otomatis (format: WO-YYYYMMDD-XXXX)
- Cetak nota titipan untuk pelanggan berisi: Nomor WO, nama alat, tanggal masuk, estimasi selesai, nomor HP toko untuk konfirmasi

#### FR-WO-02 — Status Work Order
Status mengikuti alur berikut (status berikutnya tidak bisa kembali ke status sebelumnya kecuali Admin):

```
Masuk → Diperiksa → Menunggu Spare Part → Dikerjakan → Selesai → Diambil
                                                              ↓
                                                    Tidak Bisa Diperbaiki
```

- Setiap perubahan status dicatat: waktu, oleh siapa, dan catatan opsional
- Teknisi hanya bisa memajukan status; Admin bisa mundurkan jika diperlukan

#### FR-WO-03 — Penambahan Spare Part
- Teknisi dapat menambah spare part yang digunakan dari inventori
- Spare part ditambahkan menggunakan scan barcode atau pencarian
- Harga spare part untuk pelanggan dapat berbeda dari harga jual normal (markup jasa)
- Stok inventori berkurang saat spare part dikonfirmasi digunakan

#### FR-WO-04 — Penyelesaian dan Pembayaran
- Saat status menjadi "Selesai", sistem menghitung total tagihan: ongkos jasa + total spare part
- Kasir/Teknisi dapat mencetak nota tagihan untuk pelanggan
- Pembayaran work order diproses melalui kasir (pilihan metode bayar sama seperti transaksi biasa)
- Sistem generate transaksi penjualan baru yang terhubung ke nomor WO
- Status WO otomatis berubah ke "Diambil" setelah pembayaran selesai

#### FR-WO-05 — Work Order Tidak Bisa Diperbaiki
- Jika alat tidak bisa diperbaiki, Teknisi dapat mengubah status ke "Tidak Bisa Diperbaiki" dengan wajib mengisi alasan
- Ongkos pemeriksaan/diagnosis dapat dikenakan (opsional, diatur Admin)
- Nota penolakan dicetak/dikirim ke pelanggan

#### FR-WO-06 — Daftar dan Pencarian Work Order
- Tampilan daftar WO dapat difilter by: Status, Teknisi, Tanggal masuk, Tanggal estimasi selesai
- Tanda visual untuk WO yang sudah lewat estimasi waktu selesai (highlight merah)
- Pencarian by nomor WO, nama pelanggan, atau nama alat
- Teknisi hanya melihat WO yang ditugaskan padanya; Admin dan Kasir melihat semua

---

### 6.5 Modul Manajemen Pelanggan

#### FR-CUS-01 — Database Pelanggan
- Data tersimpan: Nama, Nomor HP (sebagai identifier utama), Alamat (opsional), Tanggal bergabung
- Pelanggan baru dapat dibuat langsung dari layar kasir atau dari modul pelanggan
- Nomor HP harus unik; sistem mencegah duplikasi

#### FR-CUS-02 — Profil Pelanggan
- Halaman profil menampilkan: Data diri, Ringkasan (total transaksi, total belanja, total WO), Riwayat transaksi penjualan, Riwayat work order, Saldo piutang (jika ada)

#### FR-CUS-03 — Piutang Pelanggan
- Kasir dapat menandai transaksi sebagai "Bayar Nanti" (kredit) dengan konfirmasi Admin
- Nominal piutang tercatat di profil pelanggan
- Pembayaran piutang dicatat sebagai transaksi tersendiri (tipe: Pembayaran Piutang)
- Laporan piutang total tersedia di modul laporan

---

### 6.6 Modul Supplier & Pembelian

#### FR-SUP-01 — Data Supplier
- Data tersimpan: Nama toko/perusahaan, Nama kontak, Nomor HP/telepon, Alamat, Catatan (opsional)
- Setiap produk dapat dikaitkan ke supplier defaultnya

#### FR-SUP-02 — Purchase Order (PO)
- Admin dapat membuat PO ke supplier tertentu
- PO berisi daftar produk dan qty yang dipesan
- Status PO: Draft → Dikirim ke Supplier → Sebagian Diterima → Diterima Penuh
- PO dapat di-generate otomatis dari daftar stok kritis

#### FR-SUP-03 — Penerimaan Barang
- Saat barang dari supplier tiba, kasir/admin membuka PO terkait dan konfirmasi item yang diterima
- Qty yang diterima bisa berbeda dari qty yang dipesan (diterima sebagian)
- Harga beli aktual dapat disesuaikan saat penerimaan (jika berbeda dari PO)
- Stok inventori bertambah otomatis setelah penerimaan dikonfirmasi

#### FR-SUP-04 — Hutang ke Supplier
- Admin mencatat status pembayaran PO: Lunas, Tempo (tanggal jatuh tempo), Belum Dibayar
- Ringkasan hutang ke masing-masing supplier tersedia di dashboard Admin

---

### 6.7 Modul Laporan & Analitik

#### FR-RPT-01 — Laporan Penjualan
- Rekap per hari / per minggu / per bulan / rentang tanggal kustom
- Data: Total transaksi, Total item terjual, Total pendapatan, Total diskon diberikan, Breakdown per metode bayar (Tunai / Transfer / QRIS)
- Grafik tren penjualan harian dalam periode yang dipilih

#### FR-RPT-02 — Laporan Laba Kotor (Admin only)
- Laba kotor = (harga jual × qty) − (harga beli × qty) untuk semua produk terjual
- Tersedia per periode
- Breakdown laba per kategori produk

#### FR-RPT-03 — Laporan Produk
- Produk terlaris (by qty terjual)
- Produk dengan nilai penjualan tertinggi
- Produk yang tidak terjual dalam periode tertentu (slow moving)
- Laporan stok kritis dan stok habis saat ini

#### FR-RPT-04 — Laporan Work Order
- Jumlah WO masuk, selesai, dalam proses, tidak bisa diperbaiki per periode
- Total pendapatan jasa perbaikan
- Rata-rata waktu penyelesaian WO
- Daftar WO yang belum diambil oleh pelanggan (sudah selesai tapi belum dibayar)

#### FR-RPT-05 — Laporan Piutang
- Total piutang yang belum lunas
- Daftar piutang per pelanggan dengan tanggal terakhir transaksi

#### FR-RPT-06 — Export Laporan
- Semua laporan dapat di-export ke format PDF
- Laporan penjualan dan produk dapat di-export ke format Excel (.xlsx)

---

## 7. Persyaratan Non-Fungsional

### 7.1 Performa

| Metrik | Target |
|---|---|
| Waktu load halaman kasir | < 2 detik pada koneksi 3G |
| Waktu respons scan barcode ke keranjang | < 500 ms |
| Waktu pemrosesan OCR | < 5 detik |
| Waktu load laporan (data 1 bulan) | < 3 detik |
| Dukungan transaksi bersamaan | Minimal 3 kasir paralel |

### 7.2 Ketersediaan & Reliabilitas

- Sistem harus dapat beroperasi offline untuk fungsi kasir (transaksi penjualan)
- Data yang dibuat dalam mode offline tidak boleh hilang saat sinkronisasi
- Uptime target: 99% (tidak termasuk maintenance terjadwal)

### 7.3 Keamanan

- Semua komunikasi menggunakan HTTPS
- Password di-hash menggunakan bcrypt (salt rounds ≥ 10)
- Tidak ada data sensitif yang disimpan di localStorage browser
- Session token expired otomatis setelah 8 jam tidak aktif
- Setiap aksi kritis (hapus transaksi, ubah harga) dicatat di audit log

### 7.4 Kemudahan Penggunaan (Usability)

- Layar kasir harus dapat dioperasikan dengan satu tangan di smartphone berukuran 5–6 inci
- Ukuran tombol minimum 44×44px untuk mendukung interaksi touch
- Font minimum 14px untuk keterbacaan di layar kecil
- Semua pesan error menggunakan bahasa Indonesia yang jelas dan mudah dipahami

### 7.5 Kompatibilitas

- Browser yang didukung: Chrome 90+, Firefox 90+, Safari 14+, Samsung Internet 14+
- Perangkat: Android 8.0+, iOS 14+, Windows 10+
- Resolusi minimum: 360×640 px (smartphone) hingga 1920×1080 px (desktop)

---

## 8. Spesifikasi Teknis

### 8.1 Stack Teknologi (Rekomendasi)

| Layer | Teknologi |
|---|---|
| Frontend | React.js + Vite |
| UI Components | Tailwind CSS + shadcn/ui |
| State Management | Zustand |
| Offline Storage | IndexedDB via Dexie.js |
| Barcode Scanner | ZXing-js (kamera), HID Keyboard (USB scanner) |
| OCR | Tesseract.js |
| Backend | Node.js + Express.js |
| Database | PostgreSQL |
| ORM | Prisma |
| Autentikasi | JWT (JSON Web Token) + bcrypt |
| Real-time Sync | Socket.io (untuk update stok multi-kasir) |
| PDF Generation | PDFKit / jsPDF |
| Hosting (opsional) | VPS (Railway / Render) atau localhost + Nginx |

### 8.2 Arsitektur Sistem

```
[Browser / PWA]
      |
      | HTTPS
      |
[Backend API (Node.js/Express)]
      |
      ├── [PostgreSQL Database]
      |
      └── [Socket.io Server] ── [Kasir 1] [Kasir 2] [Kasir 3]
```

### 8.3 Struktur Endpoint API Utama

```
POST   /api/auth/login
POST   /api/auth/logout

GET    /api/products
POST   /api/products
PUT    /api/products/:id
DELETE /api/products/:id
GET    /api/products/barcode/:barcode

GET    /api/transactions
POST   /api/transactions
GET    /api/transactions/:id
PUT    /api/transactions/:id/cancel

GET    /api/work-orders
POST   /api/work-orders
GET    /api/work-orders/:id
PUT    /api/work-orders/:id/status
POST   /api/work-orders/:id/parts

GET    /api/customers
POST   /api/customers
GET    /api/customers/:id

GET    /api/suppliers
POST   /api/purchases
PUT    /api/purchases/:id/receive

GET    /api/reports/sales
GET    /api/reports/products
GET    /api/reports/work-orders
GET    /api/reports/stock
```

---

## 9. Desain Database

### Tabel Utama

```sql
-- Pengguna sistem
users (id, nama, username, password_hash, role, aktif, created_at)

-- Master data produk
produk (id, nama, sku, barcode, kategori_id, supplier_id, harga_beli,
        harga_jual, stok, stok_minimum, satuan, foto_url, aktif, created_at)

kategori (id, nama, aktif)

-- Pelanggan
pelanggan (id, nama, no_hp, alamat, saldo_piutang, created_at)

-- Transaksi penjualan
transaksi (id, no_transaksi, kasir_id, pelanggan_id, waktu, subtotal,
           diskon_total, total, metode_bayar, jumlah_bayar, kembalian,
           status, catatan, wo_id, created_at)

transaksi_item (id, transaksi_id, produk_id, nama_produk_snapshot,
                harga_satuan_snapshot, qty, diskon_item, subtotal)

-- Work Order
work_order (id, no_wo, pelanggan_id, teknisi_id, jenis_alat, merk,
            model, no_seri, keluhan, kondisi_fisik, estimasi_biaya_min,
            estimasi_biaya_max, estimasi_selesai, total_jasa, total_sparepart,
            total_tagihan, status, alasan_tolak, created_at, selesai_at)

wo_status_log (id, wo_id, status, catatan, oleh_id, created_at)
wo_sparepart (id, wo_id, produk_id, nama_snapshot, qty, harga_jual)
wo_foto (id, wo_id, tipe, foto_url, created_at)

-- Supplier dan pembelian
supplier (id, nama, kontak, no_hp, alamat, total_hutang)

purchase_order (id, no_po, supplier_id, dibuat_oleh, tanggal, total,
                status_penerimaan, status_bayar, jatuh_tempo)

purchase_item (id, po_id, produk_id, qty_pesan, qty_diterima, harga_beli)

-- Mutasi stok (audit trail)
stok_log (id, produk_id, tipe, qty_delta, stok_sebelum, stok_sesudah,
          referensi_tipe, referensi_id, oleh_id, created_at)
```

### Relasi Kunci

- `transaksi.kasir_id` → `users.id`
- `transaksi.pelanggan_id` → `pelanggan.id` (nullable)
- `transaksi_item.produk_id` → `produk.id`
- `work_order.pelanggan_id` → `pelanggan.id`
- `work_order.teknisi_id` → `users.id`
- `wo_sparepart.produk_id` → `produk.id`
- `produk.kategori_id` → `kategori.id`
- `produk.supplier_id` → `supplier.id`

---

## 10. Alur Kerja Utama (User Flow)

### 10.1 Alur Transaksi Kasir

```
Kasir buka layar kasir
        │
        ▼
Scan barcode / cari produk
        │
        ▼
Produk masuk keranjang ──► Edit qty / hapus item
        │
        ▼
Atur diskon (opsional)
        │
        ▼
Klik Bayar → Pilih metode bayar
        │
        ▼
Input nominal (jika tunai) → Hitung kembalian
        │
        ▼
Konfirmasi → Transaksi tersimpan + Stok berkurang
        │
        ▼
Pilih: Cetak Struk / Kirim WA / Selesai
```

### 10.2 Alur Work Order Perbaikan

```
Pelanggan datang bawa alat
        │
        ▼
Kasir buat WO baru
(isi data pelanggan + alat + foto + estimasi)
        │
        ▼
Cetak nota titipan untuk pelanggan
        │
        ▼
Status: Masuk
        │
        ▼
Teknisi periksa → Status: Diperiksa
        │
        ▼
Butuh spare part? ──Tidak──► Langsung kerjakan
        │ Ya
        ▼
Status: Menunggu Spare Part
(Beli spare part dari supplier jika tidak ada stok)
        │
        ▼
Spare part tersedia → Status: Dikerjakan
(Teknisi tambahkan spare part yang dipakai dari inventori)
        │
        ▼
Selesai → Status: Selesai
(Sistem hitung total tagihan)
        │
        ▼
Kasir hubungi pelanggan untuk pengambilan
        │
        ▼
Pelanggan datang → Bayar di kasir
        │
        ▼
Status: Diambil / Lunas
```

### 10.3 Alur Penerimaan Barang

```
Admin buat Purchase Order (atau generate dari stok kritis)
        │
        ▼
PO dikirim ke supplier (manual / via WA)
        │
        ▼
Barang tiba → Kasir/Admin buka PO
        │
        ▼
Konfirmasi item yang diterima (bisa sebagian)
        │
        ▼
Harga beli aktual dikonfirmasi
        │
        ▼
Stok inventori bertambah otomatis
        │
        ▼
Status PO diperbarui (Sebagian Diterima / Diterima Penuh)
```

---

## 11. Persyaratan Integrasi Hardware

### 11.1 Barcode Scanner USB

- Tipe: HID (Human Interface Device) — mode keyboard emulator
- Konfigurasi: Scanner harus diset mengirimkan karakter Enter setelah tiap barcode agar sistem langsung memproses
- Tidak memerlukan driver khusus — plug and play di Windows, macOS, Android (OTG)
- Rekomendasi: Scanner 1D/2D (QR-compatible)
- Harga estimasi: Rp 150.000 – Rp 350.000

### 11.2 Thermal Printer

- Protokol: ESC/POS (standar industri)
- Koneksi: USB atau Bluetooth (untuk HP/tablet)
- Lebar kertas: 58mm (portable) atau 80mm (standar kasir)
- Integrasi: Library `escpos` untuk Node.js (koneksi USB via backend) atau `bluetooth-escpos` untuk mobile
- Rekomendasi: Xprinter XP-58IIH (USB, 58mm) atau Epson TM-T82 (USB/LAN, 80mm)
- Harga estimasi: Rp 300.000 – Rp 700.000

### 11.3 Kamera untuk Scan & OCR

- Gunakan kamera bawaan HP/tablet yang sudah ada — tidak perlu perangkat tambahan
- Resolusi minimum yang direkomendasikan: 5 MP untuk OCR yang akurat
- Akses kamera melalui Web API (`getUserMedia`) — didukung semua browser modern

### 11.4 Koneksi Jaringan

- Router WiFi lokal jika kasir dan admin menggunakan perangkat berbeda di toko yang sama
- Internet diperlukan untuk: sinkronisasi data, backup cloud, pengiriman struk WA
- Internet tidak diperlukan untuk: transaksi kasir (mode offline aktif otomatis)

---

## 12. Antarmuka & UX Guidelines

### 12.1 Prinsip Desain

- **Speed first:** Layar kasir dioptimalkan untuk kecepatan — minimal tap/klik untuk menyelesaikan transaksi
- **Error prevention:** Validasi real-time, konfirmasi untuk aksi destruktif
- **Visibility:** Status sistem selalu jelas (mode offline, stok kritis, WO menunggu) melalui indikator di header/dashboard
- **Consistency:** Pola interaksi yang sama di seluruh modul (tombol aksi di kanan bawah, navigasi di sidebar kiri)

### 12.2 Layout Umum

- **Mobile:** Bottom navigation bar dengan 5 tab (Kasir, Produk, WO, Laporan, Menu)
- **Tablet/Desktop:** Sidebar kiri dengan navigasi, konten di kanan
- **Layar kasir:** Split view — kiri untuk input/pencarian, kanan untuk keranjang dan total

### 12.3 Warna Status

| Status | Warna |
|---|---|
| Normal / Sukses | Hijau |
| Peringatan / Kritis | Kuning/Amber |
| Error / Habis / Mendesak | Merah |
| Informasi | Biru |
| Nonaktif / Abu | Abu-abu |

### 12.4 Notifikasi & Alert

- Toast notification untuk aksi sukses (muncul 3 detik, tidak memblokir layar)
- Modal dialog untuk konfirmasi aksi destruktif (hapus, batalkan, dll.)
- Badge merah di ikon navigasi untuk item yang butuh perhatian (stok kritis, WO lewat batas waktu)

---

## 13. Prioritas Pengembangan (Roadmap)

### Fase 1 — MVP (Minimum Viable Product) — Target: 4–6 minggu

Fokus pada operasional toko yang bisa langsung berjalan.

- [ ] Setup project, database, dan autentikasi
- [ ] Modul Inventori (CRUD produk, manajemen stok dasar)
- [ ] Modul Kasir (input manual + scan barcode USB, pembayaran, struk teks)
- [ ] Modul Work Order (buat WO, update status, tambah spare part)
- [ ] Laporan harian sederhana (total penjualan, total WO)

### Fase 2 — Operasional Lengkap — Target: +3–4 minggu

- [ ] Scan barcode via kamera (ZXing-js)
- [ ] OCR input (Tesseract.js)
- [ ] Modul Pelanggan lengkap (profil, riwayat, piutang)
- [ ] Modul Supplier & Purchase Order
- [ ] Cetak struk via thermal printer
- [ ] Laporan lengkap (laba, produk, piutang, WO)
- [ ] Export PDF dan Excel

### Fase 3 — Penyempurnaan & Optimasi — Target: +2–3 minggu

- [ ] Mode offline (IndexedDB + Service Worker)
- [ ] Dashboard Admin dengan grafik dan ringkasan
- [ ] Stok opname
- [ ] Struk via WhatsApp
- [ ] Notifikasi stok kritis
- [ ] Audit log

### Fase 4 — Fitur Tambahan (Future) — Belum ditentukan timeline

- [ ] Multi-cabang
- [ ] Loyalty point pelanggan
- [ ] Integrasi marketplace
- [ ] PPN & perpajakan
- [ ] Backup otomatis ke cloud
- [ ] Versi mobile native (React Native)

---

## 14. Kriteria Keberhasilan

Sistem dianggap berhasil jika memenuhi kriteria berikut setelah go-live 1 bulan:

| Kriteria | Ukuran Keberhasilan |
|---|---|
| Kecepatan kasir | Waktu rata-rata per transaksi < 2 menit |
| Akurasi stok | Selisih stok opname vs sistem < 2% |
| Adopsi WO | 100% perbaikan masuk tercatat sebagai WO |
| Kepuasan pengguna | Pemilik toko dan kasir tidak perlu kembali ke pencatatan manual |
| Uptime | Sistem berjalan tanpa gangguan > 95% waktu operasional toko |

---

## 15. Risiko & Mitigasi

| Risiko | Kemungkinan | Dampak | Mitigasi |
|---|---|---|---|
| Internet mati saat transaksi | Sedang | Tinggi | Mode offline dengan IndexedDB; sinkronisasi otomatis saat online |
| Barcode produk tidak terbaca (rusak/tidak ada) | Sedang | Rendah | Fallback ke pencarian manual; bisa generate barcode baru |
| OCR tidak akurat (tulisan buram/miring) | Tinggi | Rendah | Selalu ada konfirmasi manual sebelum data disimpan |
| Data hilang akibat kerusakan perangkat | Rendah | Sangat Tinggi | Backup harian ke cloud; database di server (bukan hanya lokal) |
| Kasir salah input harga | Rendah | Sedang | Validasi harga jual ≥ harga beli; notifikasi jika margin terlalu kecil |
| Stok tidak sinkron antar kasir | Rendah | Sedang | Real-time sync via Socket.io; konflik stok ditandai untuk review |
| Thermal printer tidak terhubung | Sedang | Rendah | Fallback ke struk teks WhatsApp; tidak memblokir transaksi |

---

## 16. Glosarium

| Istilah | Definisi |
|---|---|
| POS | Point of Sale — sistem kasir dan manajemen penjualan |
| PWA | Progressive Web App — web app yang bisa diinstall dan berjalan offline |
| SKU | Stock Keeping Unit — kode unik internal untuk setiap produk |
| EAN-13 | European Article Number — format barcode 13 digit yang paling umum |
| OCR | Optical Character Recognition — teknologi pembacaan teks dari gambar/foto |
| WO | Work Order — tiket pengerjaan jasa perbaikan |
| HID | Human Interface Device — standar USB yang membuat scanner bekerja seperti keyboard |
| ESC/POS | Standar perintah untuk thermal printer (Epson Standard Code for POS) |
| IndexedDB | Database lokal di browser untuk penyimpanan data offline |
| JWT | JSON Web Token — format token untuk autentikasi API |
| PO | Purchase Order — surat pesanan pembelian ke supplier |
| Piutang | Tagihan yang belum dibayar oleh pelanggan |
| Hutang | Pembayaran yang belum dilunasi ke supplier |
| Stok Opname | Penghitungan fisik stok yang ada di toko untuk dicocokkan dengan sistem |
| Margin | Selisih antara harga jual dan harga beli (laba per produk) |

---

*Dokumen ini bersifat living document — akan diperbarui seiring perkembangan proyek dan feedback dari pengguna.*

*Versi berikutnya: PRD v1.1 setelah review dengan pemilik toko.*
