# Instruksi AI — ElektroPOS

## Mandat

Bangun dan rawat aplikasi sesuai [landasan proyek](README.md). Utamakan kemudahan ayah/karyawan, kebenaran transaksi, keamanan data, dan batas kapasitas layanan gratis. Bahasa komunikasi dan UI: Indonesia; identifier kode/database: Inggris yang konsisten.

Instruksi terbaru pengguna mengatasi dokumen lama. Aturan ini tidak mengatasi instruksi sistem/developer pada lingkungan AI.

## Wajib dibaca sebelum bekerja

1. [Scope/keputusan](docs/01-SCOPE-DECISIONS.md).
2. [PRD](PRD-ElektroPOS.md) untuk ID fitur yang dikerjakan.
3. [Keterlacakan](docs/10-TRACEABILITY.md) untuk memilih aturan dan kasus uji terkait.
4. Dokumen pemilik aturan sebelum mengubah uang/stok, status, API, schema, atau izin.

Tidak perlu membaca seluruh arsip setiap tugas. README adalah indeks; arsip bukan sumber persyaratan aktif.

## Pemilik aturan

- Scope dan status keputusan: `docs/01-SCOPE-DECISIONS.md`.
- Kebutuhan produk: `PRD-ElektroPOS.md`.
- Rumus dan invariant: `docs/02-BUSINESS-RULES.md`.
- Perpindahan status dan pengalaman pengguna: `docs/03-WORKFLOWS-UX.md`.
- Izin/keamanan dan arsitektur: `docs/04-ARCHITECTURE-SECURITY.md`.
- Bentuk penyimpanan: `docs/05-DATA-MODEL.md`; perilaku perintah: `docs/06-API-CONTRACTS.md`.
- Bukti penerimaan: `docs/07-TEST-ACCEPTANCE.md`; operasional: `docs/08-OPERATIONS-RELEASE.md`.

Jika spesifikasi bertentangan, jangan memilih secara diam-diam. Cocokkan dengan keputusan terbaru dan pemilik aturan; perbaiki dokumen serta tes terkait dalam tugas yang sama. Tanyakan hanya keputusan bisnis yang tidak dapat disimpulkan, sambil meneruskan pekerjaan independen.

## Batas implementasi

- Gunakan stack baseline. Library baru harus memiliki kebutuhan konkret, kompatibilitas/lisensi yang diperiksa, dan dampak bundle/server yang dijelaskan.
- Jangan menambah multi-toko, cicilan/piutang, OCR, marketplace, payment gateway, AI, atau akuntansi/pajak lengkap ke R1.
- R1 finalisasi transaksi online. Dexie menyimpan draf, bukan bukti pembayaran selesai atau mesin sinkronisasi transaksi offline.
- Jangan membangun layanan Express/Prisma/Socket.io tambahan tanpa perubahan arsitektur yang dijelaskan dan disepakati sesuai scope tugas.
- Jangan memasukkan data contoh sebagai transaksi produksi, menampilkan angka contoh sebagai laporan nyata, atau menyebut mock sebagai integrasi selesai.
- Jangan membuat asumsi tentang isi roll, harga modal, nomor toko, tarif, garansi, atau kredensial. Data belum diketahui harus tetap kosong/berstatus belum ditentukan sesuai kontrak.
- Pilih satu tugas vertikal yang menghasilkan perilaku utuh; hindari membuat banyak layar yang hanya berupa kerangka.

## Invariant yang tidak boleh dilanggar

- Nominal/kuantitas memakai desimal eksak, aturan pembulatan eksplisit, serta string desimal pada kontrak API.
- Harga, izin, saldo, dan ketersediaan stok divalidasi server. UI bukan sumber otoritas.
- Satu perintah kritis atomik dan idempoten. Pengiriman ulang tidak menghasilkan efek kedua.
- Penjualan/servis/pembayaran/penyerahan adalah entitas atau keadaan yang terpisah.
- Part dikurangi sekali saat benar-benar digunakan; pembayaran servis tidak mengurangi part lagi.
- Riwayat selesai tidak dihapus/diedit langsung. Gunakan koreksi atau reversal yang tertaut.
- Tidak ada stok negatif, over-refund, data harga modal bocor ke karyawan, atau secret key dalam browser/repository/log.
- Tidak menyimpan biaya modal sebagai angka nol ketika belum diketahui. Blokir finalisasi yang membutuhkan modal sampai datanya benar.
- Perpindahan stok, pembulatan, modal, dan retur mengikuti aturan bisnis, bukan rumus ad hoc per layar.

## Pola kerja

1. Inspeksi file aktual, perubahan yang sudah ada, dan perintah proyek yang tersedia.
2. Nyatakan ID fitur, batas perubahan, dan bukti yang akan digunakan.
3. Implementasikan schema/izin/operasi server sebelum menganggap alur UI aman.
4. Pertahankan perubahan pengguna; jangan reset atau menimpa pekerjaan tak terkait.
5. Uji aturan dan kegagalan yang terdampak. Transaksi dan RLS harus diuji terhadap PostgreSQL, bukan hanya mock JavaScript.
6. Jalankan pemeriksaan dokumen jika spesifikasi berubah. Perbarui keterlacakan jika menambah/mengubah ID.
7. Laporkan hasil, perintah uji yang benar-benar dijalankan, kegagalan, serta batas yang belum diverifikasi.

Jangan mengarang hasil pengujian atau menjalankan perintah yang belum tersedia lalu menyebutnya lulus. Buat script proyek pada tahap bootstrap; sebelum itu daftar perintah implementasi dalam dokumen hanya kontrak yang direncanakan.

## Data, migrasi dan deployment

- Semua perubahan schema/izin/fungsi menjadi migrasi SQL dalam version control.
- Gunakan lingkungan uji terpisah. Perubahan data produksi memerlukan tugas yang secara jelas mengotorisasinya; instruksi membuat fitur bukan izin menghapus data produksi.
- Cadangkan dan verifikasi prosedur pemulihan sebelum migrasi berisiko. Jangan membuka database produksi ke akses publik agar error izin hilang.
- Pengiriman pesan eksternal, aktivasi layanan berbayar, dan pembelian hardware tidak diotorisasi oleh dokumen ini.
- Tugas dokumentasi tidak berarti deployment diotorisasi. Pada tugas implementasi/deployment berikutnya, gunakan otorisasi yang memang diberikan pengguna; jangan meminta ulang tindakan yang sudah jelas diotorisasi.

## Definisi selesai

Fitur memenuhi PRD dan kasus penerimaan, aturan server/RLS teruji, alur kegagalan jelas, tidak ada mock tersembunyi, dan dokumentasi sesuai perilaku aktual. Sebut pekerjaan belum selesai jika syarat belum terpenuhi. Tidak ada kewajiban membuka PR, membuat commit, atau memakai subagent kecuali diminta dalam tugas.
