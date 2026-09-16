# Review PRD ElektroPOS

> **Dokumen historis.** Review ini menilai PRD v1.0. Untuk implementasi baru gunakan [landasan v1.1](README.md) dan [PRD aktif](PRD-ElektroPOS.md). Usulan di bawah tidak otomatis menjadi scope rilis saat ini.

Tanggal: 15 September 2026  
Dokumen yang ditelaah: [PRD-ElektroPOS.md](PRD-ElektroPOS.md), versi 1.0.0  
Status: Bahan diskusi; usulan di bawah belum menjadi keputusan produk.

## 1. Kesimpulan

PRD sudah memiliki cakupan yang jelas: kasir, stok, servis, pelanggan, pembelian, dan laporan. Kekuatan utamanya adalah menghubungkan pemakaian spare part servis dengan inventori toko serta mencatat riwayat pengerjaan dan kondisi awal alat.

Prioritas penyempurnaan adalah membuat alur harian mudah dilakukan, memastikan uang dan stok tercatat benar, serta menyediakan pemulihan ketika terjadi kesalahan. Beberapa aturan penting belum lengkap, sehingga PRD perlu diperjelas sebelum dijadikan acuan implementasi penuh.

Belum tersedia informasi tentang perangkat utama, kebiasaan ayah menggunakan aplikasi, jumlah operator, jenis servis, volume barang, internet toko, dan tanggal pembukaan. Rekomendasi pengalaman pengguna di sini merupakan hipotesis untuk diuji bersama ayah; tidak mengasumsikan kemampuan digital berdasarkan usia.

## 2. Bagian yang sudah kuat

- Persyaratan memiliki kode FR, sehingga mudah dilacak ke implementasi dan pengujian.
- Penjualan barang dan pengerjaan servis memiliki alur masing-masing.
- Pencarian manual tersedia sebagai alternatif scan.
- Nota titipan, foto kondisi masuk, estimasi, dan log status membantu melacak barang pelanggan.
- Harga jual dan nama barang disalin ke detail transaksi; ini awal yang baik untuk menjaga riwayat.
- Ada stok opname, penerimaan sebagian, piutang, dan pembagian hak akses.
- Ada rencana pengujian performa dan ukuran keberhasilan setelah peluncuran.

## 3. Perbaikan prioritas sebelum dipakai di toko

### P1 — Pisahkan pengerjaan servis, pembayaran, dan pengambilan

**Temuan:** FR-WO-04 mengubah status menjadi Diambil setelah pembayaran selesai. FR-RPT-04 menyamakan barang belum diambil dengan belum dibayar.

**Dampak:** Pelanggan yang melunasi lewat transfer tetapi datang besok akan terlihat sudah mengambil alat. Alat yang tidak bisa diperbaiki juga tetap perlu dilacak sampai dikembalikan.

**Usulan:** Catat tiga hal secara terpisah:

| Hal yang dicatat | Contoh status |
|---|---|
| Pengerjaan | Baru masuk, diperiksa, menunggu persetujuan, menunggu komponen, dikerjakan, siap diambil, tidak bisa diperbaiki, dibatalkan |
| Pembayaran | Belum bayar, dibayar sebagian, lunas; pengembalian dana dicatat tersendiri bila terjadi |
| Penyerahan barang | Masih di toko, sudah diambil — dengan waktu dan petugas penyerahan |

Tidak semua servis harus melewati Menunggu Spare Part. Alat dapat dinyatakan tidak bisa diperbaiki saat pemeriksaan atau pengerjaan. Setelah pengerjaan, sediakan hasil uji singkat sebelum dinyatakan siap diambil.

Tambahan praktis:

- Persetujuan biaya: nominal yang disetujui, waktu, dan cara pelanggan menyetujui. Kenaikan di atas nominal tersebut meminta persetujuan ulang.
- DP, pembayaran sebagian, pelunasan, biaya pemeriksaan, dan pembatalan beserta aturan pengembalian uang.
- Kelengkapan yang dititipkan, misalnya remote, kabel, adaptor, atau tutup alat.
- Nomor tiket yang sama pada nota pelanggan dan label barang, serta lokasi penyimpanannya.
- Garansi servis sesuai kebijakan toko; servis ulang terhubung ke tiket asal, dengan hasil pemeriksaan dan biaya yang eksplisit.
- Pengambilan barang tetap menjadi tindakan tersendiri. Jika penyerahan belum lunas diperbolehkan, gunakan persetujuan pemilik dan catatan piutang.
- Biarkan estimasi dan teknisi diisi setelah penerimaan bila belum diketahui; form awal cukup untuk mengidentifikasi pelanggan, alat, keluhan, dan kondisi titipan.

### P2 — Aturan satuan dan identitas barang listrik

**Temuan:** FR-INV-02 menyediakan pcs/meter/roll/set, tetapi belum menjelaskan konversi, pecahan, atau harga per satuan.

**Contoh kebutuhan:** Membeli satu roll berisi 100 meter lalu menjual 2,5 meter harus menyisakan 97,5 meter. Isi per roll harus dikonfigurasi per produk, bukan diasumsikan selalu 100 meter.

**Usulan:**

- Tetapkan satuan stok dasar per produk; contoh kabel dalam meter.
- Satuan pembelian dan penjualan dapat dikonversi ke satuan dasar dengan faktor yang tercatat.
- Izinkan pecahan hanya pada barang yang sesuai. Tetapkan ketelitian kuantitas dan pembulatan nominal Rupiah.
- Simpan satuan dan faktor konversi pada transaksi agar perubahan pengaturan tidak mengubah riwayat.
- Bila menjual roll utuh dan potongan, tentukan apakah jumlah roll utuh juga perlu dilacak. Total meter saja tidak membuktikan masih ada roll yang belum dipotong.
- Nama tampilan sebaiknya mencakup merek, tipe, dan spesifikasi pembeda: watt, ampere, ukuran kabel, warna, atau tegangan sesuai kategori.
- Tambahkan nama panggilan/pencarian alternatif yang benar-benar dipakai ayah dan lokasi rak.
- Bedakan identitas SKU/barcode dari nama tampilan; larangan nama duplikat saja belum cukup sebagai aturan identitas barang.

Harga ecer/grosir, harga pelanggan langganan, dan harga hasil tawar perlu dikonfirmasi. Asumsi harga selalu tetap pada bagian 5 belum tentu cocok dengan praktik yang direncanakan.

### P3 — Pembayaran, piutang, dan uang laci

**Temuan:** FR-CUS-03 sudah menyebut piutang, tetapi alur Bayar pada FR-POS-08 hanya memuat Tunai/Transfer/QRIS. Belum ada pengelolaan pembayaran sebagian dan rekonsiliasi uang laci.

**Usulan:**

- Pisahkan nilai tagihan, catatan pembayaran, sisa tagihan, dan pengembalian uang.
- Pelunasan piutang mengurangi sisa tagihan dan menambah penerimaan uang; tidak dihitung lagi sebagai penjualan baru.
- DP servis tidak membuat pekerjaan otomatis selesai atau barang otomatis diambil.
- Pembayaran campuran dapat ditambahkan jika diperlukan, misalnya sebagian tunai dan sebagian transfer.
- Catat modal kas awal, uang masuk/keluar di luar penjualan, saldo kas yang seharusnya, uang fisik saat tutup, dan selisih beserta alasan.
- Ringkasan penjualan, penerimaan tunai, transfer/QRIS, piutang, dan laba kotor harus diberi label berbeda.
- Penjualan umum tidak mewajibkan profil pelanggan; pelanggan dibutuhkan untuk servis atau transaksi berutang. Sediakan penanganan pelanggan tanpa HP atau yang berbagi nomor keluarga.

Ini merupakan rancangan perilaku aplikasi dan pencatatan operasional sederhana. Perhitungan akuntansi/pajak lengkap tetap berada di luar cakupan PRD.

### P4 — Retur, salah input, dan jejak perubahan

**Temuan:** PRD menyediakan pembatalan transaksi, tetapi belum mendefinisikan pengembalian barang sebagian, penukaran, atau pengembalian uang. Hak Admin masih menyebut hapus transaksi.

**Usulan:**

- Transaksi selesai dipertahankan sebagai riwayat; pembatalan/retur membuat catatan koreksi yang terkait ke transaksi awal, dengan alasan, petugas, dan waktu.
- Retur dapat dilakukan per item/kuantitas, tidak harus membatalkan seluruh nota.
- Kondisi barang menentukan apakah kembali menjadi stok layak jual atau masuk stok rusak.
- Nilai uang yang dikembalikan mengikuti transaksi asal, diskon, dan pembayaran yang sudah diterima. Retur transaksi berutang dapat mengurangi piutang.
- Koreksi spare part servis harus dapat mengembalikan stok bila part belum terpakai; part rusak tetap dicatat sebagai pemakaian/kerusakan sesuai kebijakan.
- Arsipkan produk yang sudah memiliki transaksi; riwayat tetap bisa dibuka.
- Tombol cetak ulang hanya mencetak, tidak membuat penjualan baru.

### P5 — Stok dan perhitungan laba harus konsisten

**Temuan:** FR-POS-06 memblokir stok nol tetapi hanya memperingatkan jika kuantitas melebihi stok. FR-WO-03 mengurangi stok saat part digunakan, kemudian FR-WO-04 membuat transaksi penjualan baru. Ini membuka risiko implementasi pengurangan stok dua kali jika aturan tidak dipisahkan.

**Usulan:**

- Pilih satu kebijakan stok kurang. Usulan awal: blokir, lalu pemilik bisa menyetujui pengecualian dengan alasan bila memang diperlukan.
- Pemakaian part mengurangi stok tepat sekali. Pelunasan servis tidak mengurangi part yang sama lagi.
- Transaksi ditahan belum mengurangi stok; cek ulang harga dan ketersediaan ketika dilanjutkan. Jika kelak memakai reservasi, definisikan masa berlaku dan pelepasannya.
- Simpan biaya modal yang digunakan pada setiap item penjualan/pemakaian part. Perubahan harga beli hari ini tidak mengubah laba transaksi kemarin.
- Tentukan metode penetapan modal, misalnya rata-rata tertimbang, setelah pola pembelian dikonfirmasi.
- Rumus laporan memperhitungkan diskon dan retur, dengan pembagian diskon total yang konsisten untuk laporan per produk.
- Definisikan pendapatan jasa dan biaya part agar pendapatan servis dan transaksi kasir terkait tidak dijumlahkan dua kali.
- Pada stok opname, tentukan bagaimana penjualan yang terjadi selama penghitungan diperhitungkan.

### P6 — Pencadangan dan operasi tanpa internet

**Temuan:** Offline merupakan janji inti, tetapi masuk fase 3. Backup harian menjadi mitigasi risiko, tetapi backup otomatis baru fase 4. Audit log juga ditunda ke fase 3.

**Usulan:**

- Masukkan backup otomatis, indikator keberhasilan backup, dan uji pemulihan ke kebutuhan sebelum penggunaan nyata.
- Backup mencakup database serta foto/lampiran servis. Tentukan penyimpanan terpisah, masa simpan, dan siapa yang menerima pemberitahuan kegagalan.
- Tetapkan batas kehilangan data dan lama pemulihan yang disepakati. Backup harian sendiri masih dapat kehilangan perubahan sejak backup terakhir.
- Rancang offline sejak awal jika wajib untuk pembukaan, sekalipun implementasinya bertahap. Definisikan apakah penerimaan servis juga harus tersedia tanpa internet.
- Tampilkan status sederhana: Tersimpan di perangkat, Menunggu dikirim, Sudah tersinkron — berikut jumlah transaksi tertunda dan waktu sinkronisasi terakhir.
- Kirim ulang transaksi harus menghasilkan satu transaksi saja. Gunakan identitas unik per transaksi agar nomor/kiriman dari beberapa perangkat tidak bertabrakan.
- Tentukan perilaku login kedaluwarsa saat offline, perangkat belum pernah disiapkan, perubahan harga saat offline, ruang penyimpanan penuh, dan konflik stok antarperangkat.
- Pembayaran yang sudah diterima saat offline harus tetap tercatat ketika terjadi konflik; konflik stok ditangani sebagai selisih yang perlu diselesaikan.
- Simpan catatan aksi penting sejak awal: pembatalan, perubahan harga, penyesuaian stok, pembayaran, dan retur.

**Verifikasi teknis:** IndexedDB berada di penyimpanan browser yang memiliki kuota dan aturan penghapusan. Permintaan persistent storage membantu menghadapi penghapusan otomatis tertentu, tetapi tidak menggantikan backup atau mencegah pengguna menghapus data. Lihat [dokumentasi penyimpanan browser MDN](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria).

PWA offline memerlukan aset yang telah disimpan dan rancangan service worker; data lokal saja belum memastikan aplikasi bisa dibuka tanpa jaringan. Lihat [Using Service Workers — MDN](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers).

### P7 — Barang masuk dan persiapan pembukaan

**Temuan:** Alur pembelian selalu dimulai dari PO. Belum ada alur impor produk, saldo awal, dan pembelian langsung menggunakan nota supplier.

**Usulan:**

- Sediakan Catat Barang Masuk tanpa wajib membuat pesanan terlebih dahulu; PO tetap tersedia bila diperlukan.
- Penerimaan bertahap memiliki catatan per kedatangan, jumlah, harga, tanggal, dan referensi nota. Satu nilai qty_diterima kumulatif belum menggambarkan seluruh riwayat.
- Cicilan pembayaran supplier dan retur pembelian perlu catatan masing-masing jika toko menggunakannya.
- Siapkan impor Excel/CSV dengan contoh kolom, pemeriksaan duplikat, dan pratinjau sebelum disimpan.
- Sediakan panduan pengaturan toko, produk, satuan, harga, stok awal, lokasi rak, dan uji transaksi.
- Jika ada saldo piutang/utang atau servis berjalan pada saat mulai memakai aplikasi, buat proses pencatatan awal yang eksplisit.

## 4. Pengalaman penggunaan yang diusulkan

### Beranda ayah

Empat tindakan utama: **Jual Barang**, **Terima Servis**, **Cari Servis**, dan **Tutup Hari**. Pengelolaan produk, pembelian, pengguna, dan laporan lengkap tetap dapat dibuka dari menu lain.

Ringkasan cukup menampilkan pekerjaan yang perlu tindakan: servis menunggu persetujuan, servis siap diambil, servis terlambat, stok perlu dibeli, dan tagihan jatuh tempo bila digunakan.

### Aturan interaksi

- Gunakan istilah keseharian: Servis, Barang Masuk, Stok, Utang Pelanggan. WO, PO, dan SKU tidak perlu menjadi label navigasi utama.
- Usulan awal ukuran teks utama 16–18 px dan tombol penting sekitar 48 px atau lebih, lalu uji langsung pada perangkat dan preferensi ayah.
- Tampilkan total dan kembalian besar, tombol Uang Pas, serta nominal tunai cepat.
- Hasil pencarian menampilkan spesifikasi pembeda, harga per satuan, stok, dan lokasi rak. Favorit barang dapat disesuaikan.
- Produk belum terdaftar: simpan kode yang dipindai dan arahkan ke tindakan sesuai hak akses. Kasir tidak otomatis mendapat izin membuat produk.
- Form menggunakan nilai bawaan dan pilihan cepat; data tambahan bisa dilengkapi kemudian jika tidak diperlukan untuk penerimaan barang yang aman.
- Simpan keranjang/form yang belum selesai; cegah ketukan ganda pada Bayar dan jelaskan hasil penyimpanannya.
- Status penting disampaikan dengan teks dan ikon, tidak hanya warna atau toast tiga detik.
- Konfirmasi dipakai untuk tindakan yang sulit dibatalkan; tindakan kecil seperti menghapus item keranjang dapat menyediakan Urungkan.
- Bila ayah merangkap pemilik, kasir, dan teknisi, seluruh aktivitas dapat dilakukan melalui satu akun tanpa pergantian peran manual.
- Sediakan pemulihan akun pemilik; reset oleh Admin saja belum menyelesaikan kasus satu-satunya Admin lupa akses.

## 5. Ketidakkonsistenan yang perlu dirapikan

| Rujukan PRD | Masalah | Perbaikan |
|---|---|---|
| FR-WO-04; FR-RPT-04 | Lunas disamakan dengan Diambil | Pisahkan pembayaran dan penyerahan |
| FR-WO-02; alur 10.2 | Diagram status tampak berurutan wajib, alur membolehkan melewati tunggu spare part | Buat daftar perpindahan status yang diizinkan |
| FR-POS-06 | Stok nol diblokir, stok kurang bisa diteruskan | Satu aturan pengecualian yang konsisten |
| FR-POS-02; peran Kasir | Barcode tak dikenal membuka tambah produk, tetapi kasir tidak punya hak kelola produk | Tindakan sesuai hak akses |
| Peran Kasir; FR-SUP-03 | Peran menyebut hanya transaksi/lihat stok, penerimaan barang mengizinkan kasir | Matriks izin yang eksplisit |
| FR-CUS-03; FR-POS-08 | Bayar Nanti belum menjadi bagian alur pembayaran | Tambahkan skenario kredit dan pelunasan |
| FR-AUTH-01; 7.3 | Sesi 8 jam vs 8 jam tidak aktif | Pilih definisi dan aturan saat offline |
| 4.1; bagian 5; fase 4 | Ada pengaturan pajak, tetapi penghitungan pajak di luar v1 | Selaraskan cakupan dan tampilan |
| Bagian 5; FR-POS-04 | OCR nota supplier disebut, tetapi fitur OCR hanya label produk | Tentukan target OCR atau tunda |
| 7.2; bagian 14 | Target uptime 99% vs >95%, dasar pengukuran berbeda | Satu definisi periode dan waktu operasional |
| Bagian 3, 7, 15; roadmap | Offline, backup, audit dibutuhkan tetapi terlambat dijadwalkan | Selaraskan kebutuhan pembukaan dengan tahap rilis |
| 12.2 | Split view kasir belum dibedakan untuk layar kecil | Spesifikasikan tata letak HP terpisah |

## 6. Catatan teknis untuk revisi berikutnya

### Printer dan perangkat

Jangan mengunci model printer, harga anggaran, atau janji kompatibilitas seluruh browser sebelum perangkat utama dipilih dan jalur cetaknya diuji. Harga/model dalam PRD belum diverifikasi dalam review ini.

Web Bluetooth memiliki dukungan browser terbatas dan berbicara dengan perangkat Bluetooth Low Energy; label Bluetooth pada printer belum membuktikan cocok dengan PWA. Sumber: [Web Bluetooth API — MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API). Implikasinya untuk proyek ini: uji satu kombinasi perangkat, browser, koneksi, dan printer yang nyata sebelum membeli atau menjanjikan dukungan.

Lokasi backend juga perlu diputuskan: pustaka USB yang berjalan pada backend membutuhkan akses ke printer dari mesin tersebut. Bila backend ada di cloud dan printer di toko, perlu jalur cetak melalui perangkat toko. Ini keputusan arsitektur yang belum dijelaskan pada bagian 8 dan 11.

### Model data

Skema saat ini masih ringkasan. Tambahkan kebutuhan konseptual berikut sebelum memfinalisasi tabel:

- Pembayaran dan alokasinya ke tagihan, DP, pelunasan, refund, dan riwayat utang/piutang.
- Sesi kas serta pergerakan uang di luar penjualan.
- Satuan/konversi, biaya modal historis, riwayat perubahan harga, dan lokasi rak.
- Catatan penerimaan pembelian per kejadian serta retur penjualan/pembelian.
- Persetujuan estimasi, penyerahan, hasil pengujian, dan keterkaitan garansi servis.
- Identitas transaksi offline, status sinkronisasi, dan audit aksi kritis.

Saldo dan total ringkasan perlu dapat ditelusuri kembali ke catatan sumber, bukan menjadi angka yang bisa berubah tanpa jejak. Nilai uang dan kuantitas pecahan harus memiliki ketelitian dan aturan pembulatan eksplisit.

### Cakupan teknologi

Daftar library pada bagian 8 belum perlu diperluas. Keputusan tentang perangkat, internet, printer, dan aturan transaksi lebih menentukan rancangan saat ini. Target tiga kasir paralel dan banyak browser perlu dikonfirmasi relevansinya untuk pembukaan toko.

## 7. Usulan urutan pengerjaan

### Tahap A — Validasi cara kerja toko

Wawancara singkat dengan ayah, contoh 15–20 barang nyata, contoh servis yang akan diterima, perangkat utama, kondisi jaringan, dan uji jalur cetak. Buat contoh layar kasir dan penerimaan servis untuk dicoba ayah.

### Tahap B — Kebutuhan pembukaan

- Produk, satuan yang benar, stok awal, pencarian, dan barang masuk sederhana.
- Kasir, pembayaran, riwayat, struk sesuai perangkat yang dipilih, koreksi dan retur dasar.
- Servis dari penerimaan sampai penyerahan, persetujuan biaya, part, dan pembayaran terpisah.
- Ringkasan penjualan/penerimaan, kas awal/tutup hari, dan stok rendah.
- Hak akses minimum, audit penting, backup serta pemulihan, dan pencegahan transaksi ganda.
- Offline yang teruji bila wajib saat pembukaan.
- DP/piutang/utang supplier sejak pembukaan jika praktik toko memerlukannya; jika belum, sembunyikan fiturnya.

### Tahap C — Mempercepat pekerjaan rutin

PO lengkap, impor massal lanjutan, laporan rinci, pesan WhatsApp siap kirim, harga langganan/grosir, dan dukungan operator tambahan berdasarkan kebutuhan nyata.

### Tahap D — Eksperimen setelah alur utama stabil

OCR label/nota, grafik tambahan, serta integrasi lain berdasarkan masalah yang terbukti muncul. OCR perlu diuji terhadap foto barang/nota toko sebelum menjadi janji performa.

Target 4–6 minggu MVP di PRD masih perkiraan; kelayakannya belum dapat dinilai tanpa kapasitas pengembang, keputusan offline/perangkat, dan cakupan rilis yang disepakati.

## 8. Skenario penerimaan sebelum dipakai

| Skenario | Hasil yang harus terlihat |
|---|---|
| Beli kabel 1 roll dengan isi 100 m, jual 2,5 m | Sisa 97,5 m dan tagihan sesuai satuan |
| Jual produk berspesifikasi mirip | Ayah dapat membedakan produk tanpa membuka banyak layar |
| Servis total Rp150.000, DP Rp50.000, kemudian pelunasan Rp100.000 | Sisa nol, riwayat kedua pembayaran utuh, barang tetap di toko sampai diserahkan |
| Pakai 1 spare part lalu lunasi servis | Stok turun tepat 1 kali |
| Pelanggan menolak estimasi | Pengerjaan dihentikan; biaya pemeriksaan/refund dan penyerahan tetap dapat dicatat |
| Retur 1 dari 3 barang pada nota | Kuantitas, diskon, stok, piutang/refund terkoreksi sesuai barang yang diretur |
| Harga beli berubah setelah transaksi lama | Laba transaksi lama tetap memakai biaya yang sudah dicatat |
| Ketuk Bayar dua kali atau kirim ulang setelah koneksi putus | Hanya satu transaksi dan satu pengurangan stok |
| Internet mati, aplikasi ditutup lalu dibuka | Data dan fungsi offline yang dijanjikan tetap tersedia pada perangkat yang sudah disiapkan |
| Dua kasir menjual stok terakhir | Perilaku online/offline mengikuti aturan konflik yang disepakati; pembayaran tidak hilang |
| Printer mati setelah pembayaran | Transaksi tetap tersimpan dan dapat dicetak ulang tanpa duplikasi |
| Tutup hari dengan penjualan tunai, transfer, DP, dan uang keluar | Saldo kas memperhitungkan hanya arus uang tunai yang relevan |
| Pulihkan backup pada lingkungan uji | Produk, transaksi, pembayaran, stok, tiket, dan foto dapat diakses sesuai titik backup |

Uji kemudahan penggunaan langsung: ayah melakukan penjualan, mencari alat servis, menerima DP, menyerahkan alat, dan menutup hari tanpa petunjuk langkah demi langkah. Catat salah tekan, langkah membingungkan, waktu pengerjaan, dan kebutuhan bantuan. Gunakan hasilnya untuk menyempurnakan layar.

Ukuran keberhasilan perlu memiliki cara hitung: waktu transaksi untuk jenis transaksi tertentu; selisih stok berdasarkan jumlah/nilai dan perlakuan stok nol; persentase tugas yang selesai mandiri; transaksi ganda/hilang; serta keberhasilan pemulihan backup.

## 9. Pertanyaan untuk diskusi

1. Perangkat utama dan yang sudah dimiliki apa: HP, tablet, laptop/PC? Apakah scanner/printer sudah ada?
2. Ayah mengerjakan kasir dan servis sendiri atau dibantu orang lain? Pengalaman menggunakan aplikasi sehari-hari seperti apa?
3. Barang dijual dalam satuan apa saja? Ada kabel potongan, roll utuh, harga tukang/grosir, atau tawar-menawar?
4. Servis apa yang diterima? Apakah hanya di toko atau juga kunjungan ke rumah pelanggan?
5. Apakah akan menerima DP, cicilan/utang pelanggan, pembelian supplier tempo, dan garansi servis?
6. Bagaimana kondisi internet/listrik dan kapan toko direncanakan mulai beroperasi?
7. Siapa yang merawat aplikasi, menerima laporan backup gagal, dan membantu ayah saat ada kendala?

Langkah diskusi yang disarankan: sepakati perangkat dan cara kerja harian terlebih dahulu, kemudian tetapkan cakupan pembukaan, baru revisi PRD menjadi v1.1.
