# 08 — Operasi, Backup, Kapasitas dan Rilis

Baseline 1.1. Penanggung jawab teknis: developer/pengguna. Pengambil keputusan bisnis: ayah. Semua checklist awal **belum dilaksanakan**. Referensi batas layanan: [sumber](11-SOURCES.md).

## OPS-01 — Lingkungan

| Lingkungan | Isi/akses |
|---|---|
| Local development | Kode lokal, Supabase lokal bila runtime mendukung, fixture palsu; tidak menggunakan database produksi untuk seed/reset |
| Test/staging | Project khusus pengujian jika kuota memungkinkan; akun dan data uji; URL diberi penanda UJI |
| Production | Data toko nyata, akun berizin, build/migrasi yang sudah melalui gate |

Jika kuota Free tidak cukup untuk tiga project remote, gunakan lokal untuk dev/test dan satu project remote untuk produksi. Menamai branch Git sebagai staging tidak memisahkan database. Pastikan URL/project ref di setiap environment benar sebelum menjalankan write.

Konfigurasi publik frontend: Supabase URL, publishable key, lingkungan dan versi build. Secret admin, DB password, kunci backup dan token hosting hanya pada runner tepercaya, tidak di prefix VITE_, repo, screenshot atau output log.

## OPS-02 — Setup sebelum pembukaan

- [ ] Identitas toko, kontak, zona waktu, struk dan metode pembayaran nyata terisi.
- [ ] Akun owner/staff/maintainer dibuat; owner bisa login PC/HP; akun staff tidak membaca modal.
- [ ] Public signup dinonaktifkan; grants/RLS dan Storage private diuji.
- [ ] Katalog/satuan/barcode diperiksa dengan contoh barang fisik; isi roll/step sesuai kenyataan.
- [ ] Stok/modal awal diposting sekali melalui OPENING; tanpa transaksi penjualan/pembelian fiktif.
- [ ] Cashbox drawer/wallet dan saldo awal fisik dikonfirmasi.
- [ ] Scanner, printer/driver, ukuran struk, label roll/titipan diuji.
- [ ] Daftar tarif/garansi yang belum ditetapkan tidak muncul sebagai janji otomatis.
- [ ] Backup runner, tujuan penyimpanan terpisah dan deteksi gagal aktif; restore diuji.
- [ ] Perbedaan R1 online/draf lokal dipahami ayah dan karyawan.
- [ ] Semua gate penerimaan lulus; data fixture tidak muncul sebagai data usaha.

## OPS-03 — Cadangan

Target baseline: RPO <=24 jam (batas kehilangan perubahan sejak cadangan terakhir) dan RTO <=4 jam (waktu pemulihan). Angka ini target internal yang harus diuji. Kerusakan antara backup masih dapat menghilangkan perubahan setelah titik backup.

Isi cadangan minimum:

1. Schema aplikasi, migration history, fungsi, grants/RLS dan data tabel bisnis.
2. Data identitas Auth yang diperlukan beserta prosedur pemulihan akun yang didukung versi Supabase; jangan berasumsi dump default mencakup auth/users/password/roles. Session aktif boleh diwajibkan login ulang.
3. Objek Storage foto yang dirujuk dan manifest metadata, bukan hanya tabel metadata Storage.
4. Konfigurasi nonsensitif, build/schema version, counts, checksums, waktu snapshot dan catatan pemulihan secret melalui secret store terpisah.

Runner implementasi harus memeriksa perilaku Supabase CLI/pg_dump aktual dan melakukan restore test. Jangan mengklaim satu perintah db dump otomatis mencadangkan seluruh objek Auth/Storage. File executable/OS/printer driver dikelola terpisah dalam checklist setup.

### Siklus backup

1. Jalankan minimal harian saat perangkat runner biasanya aktif; trigger cadangan setelah tutup hari boleh menjadi tambahan, bukan satu-satunya pemicu.
2. Buat snapshot database konsisten. Daftar lampiran harus sesuai snapshot itu; gunakan snapshot bersama atau jendela penulisan dihentikan sementara dengan durasi tercatat. File READY bersifat immutable agar manifest dapat disalin tanpa perubahan isi di tengah proses.
3. Salin objek baru/berubah ke tujuan terpisah; verifikasi seluruh referensi manifest tersedia dan hash/ukuran cocok.
4. Enkripsi/atur akses cadangan. Tulis SUCCEEDED hanya setelah database, objek dan manifest terverifikasi. Catat error terfilter bila gagal.
5. Jalankan pekerjaan catch-up saat runner hidup kembali jika jadwal terlewat. Waktu sukses terakhir tidak dimajukan oleh retry gagal.
6. Health check membaca usia backup. Jika database tidak dapat dihubungi, runner tetap menyimpan log lokal dan menandai pemeriksaan tidak berhasil; jangan hanya mengandalkan tabel backup_runs pada database yang sedang gagal.

Tujuan/media kedua dan kanal pemberitahuan ada pada DEC-O07. Belum ada izin mengirim pesan eksternal dari tugas dokumentasi ini. Implementasi berikutnya harus memakai kanal yang dipilih pengguna dan telah diotorisasi.

Retensi default cadangan: 7 harian +4 mingguan dengan manifest/deduplikasi objek jika runner mendukung dan sudah diuji. Jangan menghapus objek incremental yang masih dirujuk cadangan retained. Cadangan terakhir yang berhasil tidak dihapus sebelum penggantinya lolos. Target penyimpanan harus dihitung terhadap foto nyata; pilihan gratis tidak diasumsikan tak terbatas.

## OPS-04 — Restore drill

1. Pilih backup tertentu, catat timestamp dan alasan. Siapkan lingkungan kosong terisolasi, bukan restore eksperimental di produksi.
2. Pastikan versi PostgreSQL/extensions/schema/Auth kompatibel dan prosedur restore didukung. Pulihkan fungsi/grants/RLS serta data, bukan hanya tabel bisnis.
3. Pulihkan foto sesuai manifest dan kebijakan Storage. Jangan membuat bucket public untuk mempermudah pengujian.
4. Verifikasi counts/hash dan invariants stock/lot/invoice/payment/cash; bandingkan data sampel yang diketahui sebelum backup.
5. Uji login owner/staff, pembatasan biaya, buka invoice/servis/foto dan satu transaksi pada lingkungan uji.
6. Catat waktu mulai/selesai, titik data yang dipulihkan, kehilangan data terukur, masalah, dan hasil AT-29.
7. Jika pemulihan produksi diperlukan: hentikan write, amankan salinan data yang masih ada, lakukan restore/cutover terencana, perbarui konfigurasi aplikasi, dan rekonsiliasi transaksi yang terjadi setelah snapshot bersama owner. Jangan menganggap transaksi hilang telah dipulihkan hanya karena aplikasi bisa dibuka.

Jadwalkan drill sebelum go-live, setelah perubahan format backup penting, dan minimal bulanan selama awal operasi. Penjadwalan aktual dilakukan pada task implementasi/operasional, bukan dibuat oleh dokumen ini.

## OPS-05 — Kapasitas dan performa

Pantau database termasuk tabel/index, Storage, egress, latensi/error RPC, waktu backup dan pertumbuhan harian. Pisahkan ukuran penyimpanan dengan RAM/CPU server. Kapasitas package dikonfirmasi di dashboard/provider sebelum deployment.

| Ambang internal | Tindakan |
|---|---|
| <70% kuota | Catat tren; tidak perlu pembersihan agresif |
| >=70% | Investigasi sumber pertumbuhan, ukuran foto, payload/retry/poll, proyeksi hari tersisa |
| >=85% | Rencana kapasitas wajib sebelum mendekati batas: kurangi data sementara, atur unggahan nonesensial, atau usulkan peningkatan/pemindahan |
| Provider menolak write/kuota penuh | Jangan menyatakan transaksi berhasil; draf/UNKNOWN sesuai hasil, tangani kapasitas dan rekonsiliasi |

Jangan menghapus transaksi/stock ledger/audit penting otomatis untuk mengejar paket gratis. Orphan upload dan log sementara boleh dibersihkan dengan aturan retensi yang diuji. Kompresi foto dilakukan sebelum upload; foto bukti yang tertaut bukan data sampah.

Proyeksi kapasitas memakai pertumbuhan yang diukur, bukan asumsi MB per nota. Paket gratis memiliki risiko pause/kuota dan tidak menjadi SLA toko. Budget Rp0 tidak boleh diwujudkan lewat pembukaan data atau penghapusan riwayat.

## OPS-06 — Gangguan umum

| Gangguan | Tindakan operator | Tindakan teknis |
|---|---|---|
| Internet putus sebelum submit | Simpan draf; finalisasi menunggu koneksi | Pastikan tidak ada false success |
| Timeout setelah Bayar | Jangan membuat pembayaran baru; Periksa status | Lookup/retry key sama; rekonsiliasi receipt jika uang nyata sudah diterima |
| Supabase paused/unavailable | Tampilkan layanan belum tersedia | Developer periksa status/pause, pulihkan sesuai provider; jangan ping palsu sebagai pengganti rencana reliabilitas |
| Printer gagal | Transaksi tetap tersimpan; cetak ulang/salin teks | Periksa driver/koneksi/margin; tidak repost sale |
| HP tertinggal/hilang | Laporkan ke developer | Cabut sesi/nonaktifkan akses yang perlu; periksa audit |
| Backup lewat24 jam | Owner tahu status, developer menangani | Periksa runner/tujuan, jalankan catch-up dan verifikasi |
| Saldo/stock mismatch | Catat fisik dan sumber, hentikan koreksi sembarang | Investigasi ledger/operasi dan lakukan koreksi bertanda alasan |
| Kesalahan posting produksi | Simpan nomor/dampak, jangan hapus | Reversal/koreksi berizin; perbaiki bug beserta tes regresi |

Jika saat jaringan putus toko menerima uang di luar aplikasi, gunakan catatan darurat bernomor dan setelah koneksi pulih pastikan tidak ada operasi yang sudah committed sebelum memasukkan transaksi dengan referensi darurat unik. Ini prosedur rekonsiliasi manusia, bukan fitur transaksi offline yang dijanjikan.

## OPS-07 — Deployment dan rollback

- Build lulus lint/typecheck/test/build, DB integration dan e2e yang relevan; konfigurasi project refs diperiksa.
- Migrasi tambahan yang kompatibel diterapkan sebelum frontend baru. Untuk perubahan breaking, sediakan masa kompatibilitas atau maintenance window terencana; jangan membuat frontend lama memanggil fungsi yang sudah dihapus.
- Backup dan restore readiness diperiksa sebelum migrasi berisiko. Deploy UI versi diketahui, uji smoke login/cari/transaksi fixture pada staging, kemudian smoke produksi tanpa membuat transaksi bisnis fiktif.
- Rollback UI hanya ke build yang kompatibel dengan schema saat ini. Rollback database tidak dilakukan dengan drop/recreate sembarang; gunakan forward fix atau restore terencana dengan dampak kehilangan data dijelaskan.
- Secrets/akun berbayar/domain/pembelian tidak dibuat tanpa otorisasi tugas berikutnya. Penggunaan paket berbayar memerlukan keputusan anggaran pengguna.

## OPS-08 — Gate rilis

| Gate | Bukti minimum | No-go |
|---|---|---|
| G1 Bisnis | Scope/default dipahami, data awal tervalidasi | Data modal/satuan fiktif, fitur kredit tersembunyi |
| G2 Uang/stok | AT-04 sampai AT-26 yang relevan PASS dan rekonsiliasi | Duplicate, negatif, salah rounding/refund/COGS |
| G3 Akses | AT-01/02/27 PASS, secret scan | Cost staff bocor, anon dapat data, secret di build |
| G4 Perangkat/UX | AT-12/30 hardware dan ayah/karyawan lulus | Printer belum diuji, tugas utama membingungkan |
| G5 Pemulihan | AT-29 drill dan status backup nyata | Backup belum aktif atau restore gagal |
| G6 Kapasitas | Ukuran, latency/p95, workload dicatat | Klaim free cukup tanpa pengukuran atau kuota hampir habis |

Laporan go-live menyatakan status setiap gate, known limitations, versi dan keputusan owner. Jika gate belum lengkap, sebut pilot terbatas, bukan siap operasional penuh.
