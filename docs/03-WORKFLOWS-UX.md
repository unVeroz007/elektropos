# 03 — Alur Kerja dan UX

Baseline 1.1. Rumus: [aturan bisnis](02-BUSINESS-RULES.md). Izin: [arsitektur/keamanan](04-ARCHITECTURE-SECURITY.md).

## UX-01 — Struktur layar

PC: navigasi konsisten, area pencarian/produk dan keranjang yang terbaca pada 1366x768; total dan Bayar selalu mudah ditemukan. HP: susunan satu kolom, ringkasan dan tindakan sesuai konteks; jangan memaksa split view desktop pada lebar 360 px.

Beranda owner: Jual Barang, Terima Servis, Daftar Servis, Tutup Hari; kartu ringkas pekerjaan perlu perhatian. Pada HP prioritaskan Ringkasan Toko, Servis/Kunjungan, Stok, Menu. Staff langsung ke kasir. Maintainer ke ringkasan dan kesehatan sistem.

- Label produk: nama + spesifikasi pembeda + satuan harga; pencarian alias yang digunakan ayah.
- Bahasa: Servis, Barang Masuk, Pelanggan, Laci Kas; hindari WO/PO/RPC sebagai istilah menu.
- Teks utama minimal 16 px; tindakan utama minimal 48x48 px. Teks bisa diperbesar; label tidak bergantung warna. Fokus keyboard terlihat.
- Tanggal/jam lokal jelas; Rupiah dan satuan tidak disingkat ambigu. Angka total/kembalian paling menonjol.
- Form wajib seminimal data yang diperlukan saat itu; model/serial/foto opsional. Jangan meminta estimasi pasti pada penerimaan awal.
- Error memberi penyebab dan langkah berikutnya. Status penting persisten; toast boleh tambahan tetapi bukan satu-satunya bukti transaksi tersimpan.
- Tombol destruktif menjelaskan akibat; penghapusan baris draf dapat Urungkan. Konfirmasi berulang untuk setiap klik biasa tidak diperlukan.

## WF-01 — Penjualan

1. Buka kasir; tunai membutuhkan sesi drawer terbuka sebelum finalisasi.
2. Scan/cari barang. Produk potongan meminta panjang dan roll fisik; produk bulk memakai qty default.
3. Edit qty, periksa satuan/spesifikasi. Jika belum terdaftar, staff mencari manual/meminta owner; tidak membuat produk otomatis.
4. Owner dapat memberi diskon dengan alasan bila diwajibkan; staff tidak melihat kontrol tersebut sebagai akses yang dapat dipakai.
5. Bayar: pilih satu metode, masukkan nominal tunai atau verifikasi penerimaan non-tunai.
6. UI mengunci submit, memakai operation_id dan menjalankan finalisasi server.
7. Berhasil: tampilkan nomor nota dan kembalian, lalu cetak/salin teks/selesai. Gagal: tampilkan error dan pertahankan keranjang. UNKNOWN: tampilkan Periksa status, jangan membuat pembayaran baru.

Scan saat mengetik nama pelanggan tidak boleh masuk field yang salah. Handler scanner hanya aktif pada konteks scan; tidak mencegat seluruh keyboard tanpa membedakan focus/komposisi/input. Dua scan fisik sah berarti qty bertambah dua; deduplikasi hanya mencegah submit/event yang sama, bukan menolak barang identik.

## WF-02 — Penerimaan dan stok

Owner membuat dokumen barang masuk, memilih supplier/nota, scan produk, memasukkan qty satuan beli dan biaya total baris. Pratinjau menampilkan konversi, jumlah posisi roll, biaya/modal, dan total pembayaran. Posting satu kali menghasilkan lot, stock positions, ledger, pembayaran pembelian dan cash event bila tunai.

Stok awal menggunakan alur khusus dengan tanggal pembukaan dan modal; tidak menjadi pengeluaran kas/omzet pada hari aplikasi dimulai. Impor katalog terpisah dari posting saldo awal.

Koreksi/opname: pilih produk/posisi, ambil versi, hitung fisik, lihat selisih, isi alasan dan modal jika positif. Jika ada transaksi baru pada posisi tersebut, tampilkan data berubah dan minta penghitungan ulang; jangan menerapkan angka lama.

## WF-03 — Penerimaan servis toko

Pilih/catat pelanggan dan kontak → alat/keluhan → kondisi/kelengkapan → custody SHOP → label dan nota titipan → DP opsional. Tiket boleh tersimpan sebelum foto selesai diunggah. Tiket tetap ada jika unggah gagal, dengan opsi unggah ulang.

Nota titipan memuat nomor, pelanggan, alat, kondisi/kelengkapan ringkas, tanggal masuk, kontak toko dan estimasi jika ada. Tidak mencetak tarif/garansi yang belum ditentukan.

## WF-04 — Kunjungan rumah

Catat pelanggan, alamat, keluhan, jadwal dan mekanik ayah; custody CUSTOMER. Jadwal ulang dicatat dengan alasan. Ayah melihat tiket dari HP.

Sebelum pergi: transfer part yang dibawa dari SHOP ke FIELD_FATHER; uang modal wallet melalui transfer kas jika diperlukan. Di lokasi: catat pemeriksaan, persetujuan biaya, part benar-benar dipakai, hasil pekerjaan dan pembayaran. Jika tunai masuk ke FATHER_WALLET, tidak langsung masuk drawer.

Jika alat dibawa pulang, pindahkan custody CUSTOMER->FATHER->SHOP pada tiket sama dengan kondisi/kelengkapan. Spare part sisa dikembalikan FIELD_FATHER->SHOP. Setor uang wallet ke drawer sebagai transfer, bukan pendapatan kedua.

## WF-05 — Status pengerjaan

Status teknis disimpan dalam kode Inggris; UI menampilkan label Indonesia. Hasil terminal READY, UNREPAIRABLE, CANCELLED tidak sama dengan closed_at. READY untuk onsite ditampilkan Selesai Dikerjakan, untuk titipan Siap Diambil.

| Dari | Ke yang diizinkan | Syarat |
|---|---|---|
| NEW | INSPECTING, CANCELLED | Penerimaan lengkap minimum |
| INSPECTING | AWAITING_APPROVAL, UNREPAIRABLE, CANCELLED | Hasil diagnosis/alasan |
| AWAITING_APPROVAL | WORKING, WAITING_PARTS, CANCELLED | Kerja/tunggu part hanya setelah persetujuan revisi aktif |
| WAITING_PARTS | WORKING, AWAITING_APPROVAL, UNREPAIRABLE, CANCELLED | Part siap atau biaya berubah/alasan |
| WORKING | READY, WAITING_PARTS, AWAITING_APPROVAL, UNREPAIRABLE, CANCELLED | READY membutuhkan hasil uji; biaya baru perlu persetujuan |
| READY, UNREPAIRABLE, CANCELLED | Tidak maju/mundur biasa | Finalisasi tagihan dan penyelesaian custody/pembayaran |

Untuk tindakan owner koreksi status terminal sebelum invoice final dan sebelum closed_at, server boleh memulihkan ke status tepat sebelum terminal berdasarkan log, dengan alasan wajib dan versi yang cocok. Setelah invoice final, pekerjaan tambahan/ulang menjadi tiket baru terkait. Staff tidak memiliki operasi koreksi progres.

Biaya nol tetap membutuhkan penetapan/persetujuan eksplisit sebelum WORKING. Persetujuan dapat lisan/telepon/WhatsApp dengan catatan aktor, waktu, revisi, lingkup dan batas nominal; aplikasi tidak mengirim pesan sendiri.

## WF-06 — Tagihan dan penyelesaian

1. Owner memilih hasil terminal dan memastikan pemakaian part/reversal sudah benar.
2. Owner mengisi jasa/biaya lain, memeriksa total terhadap persetujuan, lalu finalisasi invoice.
3. DP dialokasikan ke tiket; layar menampilkan sisa atau kelebihan. Pelunasan sisa diterima oleh owner/staff sesuai lokasi kas.
4. Kelebihan dikembalikan melalui refund owner yang mengacu receipt asli. Batal/tidak berhasil dapat punya biaya diagnosis yang disepakati atau nol.
5. Jika alat masih dititipkan, serahkan setelah syarat BR-11; simpan nama penerima dan waktu. Jika alat di rumah pelanggan, langsung Close layanan setelah semua syarat terpenuhi.

Koreksi total invoice final yang menurunkan tagihan menggunakan credit note jasa/part, tidak melakukan refund DP kedua. Part yang terpasang tidak otomatis kembali ke stok akibat pengurangan harga jasa; pengembalian part perlu kejadian fisik tersendiri.

## WF-07 — Keluhan kembali

Cari tiket asal → Catat Keluhan Kembali → tiket baru dengan parent_ticket_id, keluhan dan kondisi baru. Owner memutuskan biaya setelah pemeriksaan. Tampilan memperlihatkan pekerjaan/part sebelumnya; tidak mengubah tanggal/hasil invoice lama.

## WF-08 — Retur dan refund

Owner membuka nota asal, memilih item/qty yang belum diretur, kondisi dan alasan. Pratinjau memperlihatkan refund menurut harga asal dan stok yang akan kembali. Konfirmasi menggunakan operation_id; posted credit note, pemulihan stok/modal dan refund konsisten.

Jika barang ditukar, buat penjualan pengganti yang merujuk retur. UI memperlihatkan kedua nomor. Tidak ada penghapusan nota lama atau penggabungan saldo tersembunyi.

## WF-09 — Tutup hari

Pilih cashbox/session → tampilkan ringkasan metode pembayaran dan arus kas → input hitungan fisik → tampilkan selisih → alasan bila selisih → tutup dengan snapshot. Staff menghitung drawer; owner menyelesaikan wallet dan meninjau selisih. Closed session tidak menerima gerakan baru; koreksi dicatat pada sesi saat ini.

Laporan hari dan laporan session dibedakan terutama jika sesi melewati tengah malam. Transfer non-tunai tidak disertakan sebagai uang fisik. Piutang tidak muncul pada navigasi R1.

## UX-02 — Keadaan koneksi dan pengiriman

| Keadaan | Pesan/tindakan |
|---|---|
| DRAFT_LOCAL | Draf tersimpan di perangkat; belum menjadi transaksi |
| SUBMITTING | Sedang menyimpan; tombol kirim terkunci |
| UNKNOWN | Hasil belum diketahui; periksa operation_id yang sama |
| COMMITTED | Nomor dokumen dan waktu server; struk dapat dibuat |
| REJECTED | Alasan spesifik; draf tetap ada; perubahan payload memakai operasi baru |
| OFFLINE | Finalisasi tidak tersedia; boleh mengubah draf |
| LOCAL_STORAGE_FAILED | Draf belum tersimpan; jangan tutup sebelum mengamankan isian |

Saat auth habis, login ulang lalu periksa operasi lama. Jangan menghapus draf atau mengirim ulang sebagai transaksi baru. Refresh halaman memulihkan konteks operasi pending; perubahan schema draf tidak boleh membuang isian tanpa pemberitahuan.

Pernyataan di atas berlaku saat auth expired/refresh dengan pengguna yang sama. Logout eksplisit/pergantian akun mengikuti pembersihan draf sensitif ARC-03: pengguna diberi penjelasan sebelum draf dibuang. Operasi UNKNOWN hanya menyisakan identifier minimum untuk lookup; bila belum committed dan payload sudah dibuang, lakukan rekonsiliasi pengguna, bukan retry otomatis dengan data tebakan.

## UX-03 — Pengujian dengan ayah/karyawan

Gunakan contoh produk nyata untuk membedakan merek/ampere/watt, transaksi meteran, pencarian alat titipan, DP dan kas tutup. Setelah latihan singkat, pengguna menjalankan tugas tanpa panduan langkah demi langkah; catat waktu, salah tekan dan kebutuhan bantuan. UI harus diperbaiki berdasarkan observasi sebelum dinyatakan mudah digunakan.
