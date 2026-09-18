# Product Requirements Document — ElektroPOS

Versi **1.1** · 15 September 2026 · Baseline implementasi dengan default rancangan dan keputusan terbuka yang ditandai.

Pemilik bisnis: ayah pengguna. Pengelola teknis: pengguna. Target pembukaan: akhir September 2026. Status aplikasi: belum diimplementasikan. PRD ini menggantikan v1.0 untuk pekerjaan baru; [arsip asli](docs/archive/PRD-ElektroPOS-v1.0.md) tetap tersedia.

## 1. Tujuan

Membantu ayah dan satu karyawan melayani penjualan serta servis dengan sedikit langkah, mengetahui lokasi/status barang pelanggan, menjaga kebenaran stok dan uang, serta memantau kegiatan dari HP. Aplikasi untuk satu toko, bukan layanan POS publik multi-tenant.

Keberhasilan berarti tugas nyata dapat diselesaikan mandiri dengan data benar, hasil server jelas, dan pemulihan data terbukti. Banyaknya fitur bukan ukuran keberhasilan.

## 2. Pengguna

| Peran | Kebutuhan |
|---|---|
| Owner / ayah | Kasir, mekanik, kunjungan, pengaturan harga, persetujuan biaya, pemantauan usaha |
| Staff / karyawan | Kasir, penerimaan titipan, pembayaran sesuai tagihan, pencarian dan penyerahan alat |
| Maintainer / developer | Pemantauan seluruh aktivitas, kapasitas dan backup, pengelolaan akun/teknis |

Akun masing-masing. Owner boleh menggunakan PC dan HP bersamaan. Maintainer bukan pelaku transaksi bisnis secara default. [Matriks izin](docs/04-ARCHITECTURE-SECURITY.md) mengatur akses server secara rinci.

## 3. Scope, perangkat dan asumsi

Semua fitur FR di bawah termasuk R1. [Scope dan keputusan](docs/01-SCOPE-DECISIONS.md) adalah sumber tunggal batas rilis. PC sudah ada; scanner/printer belum dipilih. HP menggunakan browser melalui internet. Internet/listrik dinyatakan aman, tetapi kegagalan jaringan harus ditangani.

R1 online untuk finalisasi; draf disimpan lokal. Rupiah, zona waktu Asia/Jakarta. Target biaya hosting awal Rp0 selama berada dalam kuota. Tidak ada janji kapasitas tak terbatas, pembayaran otomatis, atau transaksi offline final.

## 4. Persyaratan fungsional

### FR-AUTH-01 — Akun, login, dan sesi

- Akun disiapkan maintainer; tidak ada pendaftaran publik. Owner/staff/maintainer mempunyai izin berbeda.
- Login/logout, sesi PC/HP, penonaktifan akun, dan prosedur reset sandi tersedia sesuai arsitektur.
- Akun nonaktif ditolak server meskipun token lama belum habis. Perubahan peran tidak bergantung hanya pada data yang tersimpan di browser.
- Draf lokal dipisah per akun; logout tidak membocorkan keranjang/data pelanggan kepada akun berikutnya.

### FR-CAT-01 — Katalog, variasi dan satuan

- Owner mengelola nama, spesifikasi pembeda, SKU, kategori, barcode opsional, satuan dasar, satuan jual/beli, konversi, harga, batas stok, rak dan foto opsional.
- SKU unik; nama boleh sama jika identitas/spesifikasi berbeda. Setiap variasi dengan stok berbeda memiliki SKU tersendiri.
- Potongan dan roll utuh tercatat dengan kuantitas/konversi yang jelas. Produk belum lengkap tidak dapat dijual.
- Arsip produk tidak menghapus riwayat. Satuan dasar yang sudah digunakan tidak diedit; koreksi membutuhkan prosedur produk pengganti/migrasi.

### FR-CAT-02 — Barcode dan pencarian

- Scanner keyboard membaca kode lalu Enter. Scan pada kasir menambahkan barang bulk satu satuan jual default; kabel meminta panjang/roll sumber.
- Scan penerimaan hanya memilih produk; tidak langsung menambah stok.
- Pencarian nama, alias, SKU dan barcode menampilkan spesifikasi, satuan, harga, ketersediaan di toko dan rak.
- Barcode tidak dikenal tidak memberi staff hak membuat produk. Owner dapat mendaftarkan kode setelah memeriksa duplikasi.
- Produk tanpa barcode tetap dapat dicari manual. Label internal menggunakan Code 128 dengan SKU internal; tidak mengarang identitas EAN resmi.

### FR-INV-01 — Barang masuk dan stok awal

- Owner mencatat supplier opsional, nomor nota, tanggal, item, satuan, jumlah, konversi, harga beli dan metode pembayaran lunas.
- Finalisasi menambah stok dan nilai modal dalam satu operasi; kuantitas/biaya penerimaan disimpan sebagai lot.
- Stok awal menggunakan dokumen pembukaan khusus, bukan transaksi pembelian/penjualan hari berjalan; modal wajib diketahui dan dikonfirmasi.
- Penerimaan draft dapat diedit. Dokumen posted dipertahankan; kesalahan dikoreksi dengan catatan tertaut, bukan penghapusan.

### FR-INV-02 — Mutasi, roll dan part dibawa kunjungan

- Setiap perubahan kuantitas punya sumber, alasan/jenis, aktor, waktu dan alokasi lot/posisi.
- Lokasi dasar: SHOP dan FIELD_FATHER. Barang dibawa ayah masih milik toko, tetapi tidak tersedia untuk penjualan di laci toko.
- Bedakan part dibawa, terpakai, dikembalikan dan rusak. Transfer tidak menjadi penjualan.
- Roll/potongan kontinu memiliki label posisi fisik. Sisa potongan tidak otomatis dianggap roll utuh atau bisa disambung menjadi satu panjang.

### FR-INV-03 — Penyesuaian dan stok opname

- Owner dapat menghitung produk terpilih dan mencatat koreksi dengan alasan serta dasar modal untuk tambahan stok.
- Stok dibandingkan dengan versi saat penghitungan; perubahan selama hitung menghasilkan konflik dan perlu hitung ulang.
- Koreksi tidak menghapus ledger; barang rusak dibedakan dari stok layak jual. Tidak ada stok negatif.

### FR-POS-01 — Keranjang dan transaksi ditahan

- Tambah, ubah jumlah, hapus, cari/scan, tampilkan satuan/harga, diskon dan total.
- Tersedia Uang Pas serta nominal cepat saat pembayaran. Owner dapat memberi diskon; staff memakai harga berlaku.
- Draf/hold tidak mengurangi atau mereservasi stok. Ketika dilanjutkan, perubahan harga/stok dijelaskan dan dikonfirmasi sebelum pembayaran.
- Batas awal 5 draf aktif per akun/perangkat; jangan menghapus draf tertua diam-diam. Pemindahan draf antarperangkat di luar R1.

### FR-POS-02 — Pembayaran dan finalisasi penjualan

- Tunai, transfer, QRIS manual. Penjualan barang harus lunas; satu metode bayar per penjualan.
- Tunai: nominal diterima >= total; kembalian ditampilkan. Non-tunai memerlukan konfirmasi penerimaan oleh petugas.
- Server menentukan nilai final dan mengesahkan nota, pembayaran, stok, modal dan audit secara atomik/idempoten.
- Timeout bukan berarti gagal; status operasi diperiksa sebelum pengiriman ulang. Nomor nota unik ditetapkan server.

### FR-POS-03 — Riwayat dan struk

- Cari transaksi dengan nomor/tanggal; tampilkan detail historis, pembayaran, retur dan petugas.
- Cetak HTML/CSS melalui browser, ukuran awal dapat diatur 58/80 mm setelah uji perangkat. Cetak ulang tidak membuat transaksi baru.
- Printer gagal tidak membatalkan penjualan yang sudah tersimpan. Teks struk dapat disalin/dibagikan manual.
- Isi struk: identitas toko, nomor, tanggal lokal, item/spesifikasi, kuantitas+satuan, harga, diskon, total, metode, bayar/kembalian, petugas.

### FR-POS-04 — Retur dan refund penjualan

- Owner memilih transaksi asal, item/jumlah, kondisi barang, alasan dan metode refund.
- Kuantitas/nilai refund dibatasi sisa transaksi asal. Nilai mengikuti diskon/harga asal; harga terbaru tidak digunakan.
- Retur layak jual kembali ke persediaan dengan modal asal; barang rusak masuk kondisi DAMAGED. Penggantian barang dicatat sebagai retur dan penjualan baru yang saling dirujuk.
- Pembatalan penuh transaksi posted memakai proses koreksi penuh yang menjaga riwayat; staff hanya dapat mengajukan ke owner.

### FR-SRV-01 — Penerimaan servis dan kunjungan

- Tiket memiliki pelanggan/kontak, jenis alat, keluhan, lokasi layanan, kondisi/kelengkapan titipan bila ada, foto opsional dan ayah sebagai mekanik default.
- Kunjungan memerlukan alamat serta jadwal yang dapat dijadwal ulang; lokasi/tautan peta opsional.
- Estimasi boleh belum diketahui. Nomor tiket unik dan nota titipan hanya berlaku jika barang benar-benar dititipkan.
- Alat yang dibawa dari rumah pelanggan ke toko tetap pada tiket yang sama dengan catatan perpindahan penguasaan.

### FR-SRV-02 — Pemeriksaan, persetujuan dan progres

- Alur status mengikuti tabel transisi pada dokumen workflow; tidak memaksa setiap servis menunggu komponen.
- Estimasi, revisi, nominal maksimum yang disetujui, waktu/cara persetujuan dan catatan dicatat.
- Kenaikan biaya di atas persetujuan memerlukan persetujuan ulang. Biaya belum ditentukan berbeda dari nol/gratis.
- Siap diambil/selesai membutuhkan hasil pemeriksaan akhir. Pembatalan/tidak bisa diperbaiki tetap memerlukan penyelesaian pembayaran/pengembalian alat.

### FR-SRV-03 — Pemakaian spare part

- Owner memilih stok toko/yang dibawa, kuantitas dan harga tagihan yang terlihat.
- Konfirmasi terpakai mengurangi stok serta menyimpan modal historis sekali. Pelunasan tidak mengulangi mutasi.
- Part belum terpakai dikembalikan melalui transfer. Part yang telah terpakai hanya dikoreksi dengan kejadian reversal/kerusakan yang eksplisit.
- Tidak ada penggunaan part dari produk fiktif atau stok negatif; part yang baru dibeli harus diterima dahulu.

### FR-SRV-04 — Tagihan, pembayaran dan cicilan

- Tanpa uang muka: kerusakan dan part diperiksa dulu, tagihan dibuat dari hasil itu, baru pembayaran diterima (DEC-U04). Jumlah/metode/aktor/waktu/pemegang kas disimpan.
- Tagihan final terdiri atas baris jasa, biaya kunjungan/pemeriksaan bila ada, dan part. Owner menetapkan/menyetujui tagihan.
- Staff dapat menerima pembayaran/cicilan sampai sisa tagihan; tidak dapat mengubah biaya.
- Uang jasa boleh dicicil, termasuk setelah alat diserahkan dengan sisa tagihan atas keputusan owner (piutang servis). Tiket tertutup saat lunas.
- Kelebihan bayar (mis. setelah nota kredit) menjadi kewajiban refund yang terlihat. Kasus batal/diagnosis diselesaikan owner tanpa uang otomatis hangus.

### FR-SRV-05 — Penyerahan dan keluhan kembali

- Pengerjaan, tagihan, pembayaran dan penguasaan alat terpisah.
- Penyerahan merekam penerima, petugas dan waktu; mensyaratkan hasil terminal, tagihan final, tidak ada refund tertunda, dan lunas — kecuali owner memutuskan menyerahkan dengan sisa tagihan beserta catatan (piutang servis).
- Kunjungan tanpa titipan ditutup sebagai layanan selesai tanpa status Diambil palsu.
- Keluhan kembali membuat tiket terkait tiket asal. Tidak mengubah riwayat lama atau otomatis menjanjikan garansi gratis.

### FR-CUS-01 — Pelanggan

- Penjualan umum boleh tanpa identitas pelanggan; servis memerlukan nama dan cara kontak.
- Normalisasi nomor HP Indonesia; nomor dapat dipakai keluarga dan tidak menjadi primary key/keunikan mutlak.
- Tampilkan kandidat pelanggan yang mirip sebelum membuat baru. Tidak melakukan penggabungan otomatis.
- Riwayat penjualan/servis tersedia sesuai peran; tidak ada saldo piutang pada R1.

### FR-CASH-01 — Kas dan tutup hari

- Pisahkan kas laci SHOP_DRAWER dan uang servis yang dibawa ayah FATHER_WALLET.
- Catat saldo buka, penerimaan/pengembalian tunai, biaya dibayar kas, transfer antar pemegang, penambahan/penarikan manual dan saldo fisik tutup.
- Transfer/QRIS tidak menambah laci. Penyerahan uang ayah ke laci bukan pendapatan baru.
- Selisih uang fisik ditampilkan dengan alasan; tidak diam-diam membuat penjualan/koreksi saldo.

### FR-RPT-01 — Beranda dan pemantauan HP

- Ringkasan penjualan barang, tagihan servis final, penerimaan menurut metode, servis perlu tindakan, kunjungan, stok rendah dan status backup untuk peran yang berhak.
- Angka hanya berasal dari data nyata; keadaan kosong diberi label kosong.
- Tampilkan waktu data diperbarui dan status koneksi. Fokus data terkini; pembaruan tidak mengunduh semua riwayat.

### FR-RPT-02 — Laporan operasional

- Filter rentang tanggal; ringkasan dihitung server berdasarkan Asia/Jakarta dan definisi aturan bisnis.
- Pisahkan omzet barang, nilai tagihan servis, penerimaan, piutang servis, refund, modal barang/part dan laba kotor.
- Laba kotor hanya owner/maintainer; tidak dinyatakan sebagai laba bersih. Definisi COGS/servis/cancel mengikuti aturan bisnis.
- Bukti penelusuran dari angka ringkasan ke catatan sumber tersedia. Semua hasil memperhitungkan reversal dan retur tanpa duplikasi.

### FR-DATA-01 — Foto, impor dan ekspor

- Foto privat dengan batas ukuran/jumlah, kompresi, metadata yang diperlukan saja; kegagalan foto tidak menghilangkan tiket tersimpan.
- CSV impor katalog memiliki template, pratinjau dan validasi duplikasi/konversi. Stok awal diposting sebagai operasi terpisah terkontrol.
- Ekspor CSV terbatas izin dan periode, aman terhadap formula spreadsheet, mencantumkan zona waktu dan satuan. CSV bukan backup lengkap.

### FR-RES-01 — Draf dan gangguan jaringan

- Draf lokal memiliki schema version, akun dan waktu simpan. UI membedakan draf, sedang dikirim, hasil belum diketahui, berhasil dan gagal.
- Finalisasi diblokir ketika benar-benar offline. Permintaan yang hasilnya belum diketahui dicari menggunakan operation_id yang sama.
- Kegagalan kuota browser diberitahukan; jangan menampilkan Draf tersimpan jika penyimpanan gagal.

### FR-OPS-01 — Backup, restore dan kapasitas

- Cadangan data dan foto terpisah dari proyek aktif, status sukses terakhir, deteksi tugas terlewat, dan drill restore.
- Owner/maintainer dapat melihat kesehatan operasional sesuai izin; pesan teknis lengkap untuk maintainer.
- Ukur database termasuk indeks, Storage, egress, kueri lambat dan galat; ambang tindakan menurut runbook.

### FR-SEC-01 — Otorisasi dan audit

- Semua akses data memerlukan autentikasi/izin yang sesuai. Karyawan tidak dapat membaca harga modal melalui tabel, view, RPC, ekspor, atau payload error.
- Catat perubahan harga, stok, status, persetujuan, pembayaran, refund, konfigurasi dan akun dengan aktor/waktu/alasan yang diperlukan.
- Tidak ada penghapusan langsung transaksi posted, token/secret dalam log, atau URL foto publik permanen.

### FR-SET-01 — Penyiapan toko

- Pengaturan identitas, zona waktu tetap R1, ukuran struk, akun, satuan, stok awal, cashbox dan pilihan rekening/QRIS manual.
- Checklist setup menandai apa yang belum lengkap. Data contoh jelas dipisahkan dari data nyata.
- Produk belum memiliki modal/konversi tidak bisa dipakai transaksi yang memerlukan data tersebut. Tarif/garansi belum diputuskan tetap kosong, bukan diisi default fiktif.

## 5. Persyaratan non-fungsional

Angka berikut adalah target internal yang harus diukur, bukan hasil pengujian atau janji provider.

| ID | Target dan cara ukur |
|---|---|
| NFR-01 | Operasi kasir server p95 <= 2 detik setelah koneksi hangat pada fixture dan jaringan uji tercatat |
| NFR-02 | Barcode produk yang sudah ada di cache halaman ke respons UI <= 500 ms; pencarian server p95 <= 1 detik pada fixture |
| NFR-03 | Dashboard/laporan 30 hari p95 <= 3 detik dengan payload paginated/ringkas |
| NFR-04 | Tiga sesi aktif: satu kasir, satu owner di HP, satu pemantau; uji konflik dua penulis terpisah tetap wajib |
| NFR-05 | Tidak ada transaksi ganda, stok negatif, selisih alokasi uang atau akses tanpa izin pada seluruh kasus penerimaan |
| NFR-06 | PC 1366x768 dan HP 360x640/390x844; teks utama 16 px, tindakan utama >=48 px, navigasi keyboard dan fokus terlihat |
| NFR-07 | Browser stabil yang didukung pada perangkat nyata dipilih saat UAT; jangan mewarisi klaim Chrome 90/Safari 14 tanpa uji |
| NFR-08 | Target bundle awal <=300 KiB gzip untuk JS, foto/laporan dimuat terpisah; ukur hasil build dan catat pengecualian |
| NFR-09 | Target backup/RPO/RTO dan tindakan kapasitas mengikuti runbook; tidak ada klaim uptime SLA layanan Free |
| NFR-10 | Semua uang/kuantitas memiliki aturan presisi, seluruh total nota konsisten dengan sumber; waktu server sebagai otoritas |

## 6. Definisi siap

Setiap FR dipetakan ke AT dalam [keterlacakan](docs/10-TRACEABILITY.md). Semua gate uang/stok, keamanan, pemulihan, UX, dan perangkat harus lulus untuk klaim siap penggunaan penuh. Biaya/jadwal tidak boleh dipenuhi dengan menyembunyikan fitur yang belum bekerja.

Dokumen [rencana implementasi](docs/09-IMPLEMENTATION-PLAN.md) menjelaskan urutan, sedangkan [operasi/rilis](docs/08-OPERATIONS-RELEASE.md) menentukan bukti go-live. Perubahan default/open mengikuti [register keputusan](docs/01-SCOPE-DECISIONS.md).
