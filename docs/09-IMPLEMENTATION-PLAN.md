# 09 — Rencana Implementasi untuk AI

Baseline 1.1. Urutan ini mengikuti dependensi; bukan janji durasi atau hasil yang telah selesai. [Template tugas](templates/AI-TASK.md) digunakan per bagian. Tidak ada instruksi otomatis membuat thread/subagent, commit, PR atau deploy.

## PLAN-01 — Prinsip pelaksanaan

Selesaikan satu alur yang benar dari database sampai UI. Jangan membangun semua layar dengan data palsu lalu menganggap backend dapat ditambahkan belakangan tanpa perubahan bisnis. Sebelum setiap tugas pilih FR dan AT dari [keterlacakan](10-TRACEABILITY.md).

Komponen UI umum dibuat ketika diperlukan oleh fitur pertama; hindari design system internal tambahan. Tambahkan dependensi hanya untuk fungsi nyata. Tidak ada setup issue tracker berbayar/eksternal yang diwajibkan.

## Tahap P0 — Bootstrap dan bukti koneksi

Keluaran:

- React/TypeScript/Vite dan struktur folder baseline, package manager/lockfile serta versi runtime yang kompatibel.
- Tailwind/shadcn dasar, routing, konfigurasi lint/typecheck/test/build.
- Supabase lokal/uji, migrations, roles dan RPC read minimum; environment.example hanya placeholder publik.
- Login role individual, halaman sederhana yang menampilkan data nyata lingkungan uji, penanganan auth/error.
- Script validasi dokumen tetap berjalan. Jika memerlukan konfigurasi akun pengguna, lanjutkan dengan lokal/fixture yang jelas sampai konfigurasi tersedia.

Bukti: FR-AUTH-01, FR-SEC-01 bagian dasar; AT-01/02; build nyata. Stop: kerangka koneksi/izin bekerja, belum membuat seluruh fitur bisnis.

## Tahap P1 — Mesin hitung dan persediaan

Keluaran: parser/Decimal.js dan vektor bersama SQL; schema katalog/unit/barcode, lot/posisi/ledger; penerimaan/stok awal; cost allocation, transfer field, adjustment/opname. UI minimum untuk memasukkan produk dan memeriksa konversi.

Bukti: FR-CAT-01/02, FR-INV-01/02/03, aturan BR-01 sampai BR-06, AT-03 sampai AT-07 serta AT-14/15/16. Jangan lanjut checkout nyata jika presisi/alokasi tidak benar.

## Tahap P2 — Kasir dari awal sampai selesai

Keluaran: cashbox/session dasar, keranjang, scan/pencarian, diskon owner, finalisasi sale atomik/idempoten, payments, history/struk, retur/refund dan draf lokal. Mulai dengan fixture nyata DB uji, bukan mock respons sukses.

Bukti: FR-POS-01/02/03/04, FR-CASH-01 bagian dasar, FR-RES-01; AT-08 sampai AT-13 dan AT-24/25/28. Struk browser diuji; hardware gate tetap pending sampai perangkat tersedia.

## Tahap P3 — Servis toko dan kunjungan

Keluaran: pelanggan, intake/status/estimate approval, custody, field parts, DP/final invoice/settlement, handover/onsite close, linked revisit. Owner HP dapat menyelesaikan kunjungan; staff menerima titipan/pembayaran sesuai peran.

Bukti: FR-SRV-01 sampai FR-SRV-05, FR-CUS-01; AT-17 sampai AT-23. Uji alur gagal/DP lebih besar/part tidak ditagih, bukan hanya servis berhasil normal.

## Tahap P4 — Pemantauan dan operasi

Keluaran: dashboard PC/HP, laporan dengan definisi tunggal, CSV/foto privat, impor katalog, tutup kas lengkap, pengaturan dan status kesehatan; backup runner/manifest/restore script yang dikonfigurasi untuk tujuan disepakati.

Bukti: FR-RPT-01/02, FR-DATA-01, FR-OPS-01, FR-SET-01; AT-26 sampai AT-30. Runner tanpa tujuan/credential hanya disebut siap dikonfigurasi, bukan backup aktif.

## Tahap P5 — Uji toko dan rilis

Keluaran: fixture realistis dan pengukuran, uji pengguna/hardware, import data awal nyata yang diotorisasi, smoke staging, laporan gate, deployment bila diminta/diotorisasi.

Bukti: seluruh FR terpetakan dan semua AT/gate yang wajib lulus. Penggunaan nyata tidak dimulai hanya karena tanggal target tiba.

## PLAN-02 — Bentuk laporan setiap tugas

1. Ringkasan perilaku yang selesai dan siapa yang terbantu.
2. FR/BR/AT yang dikerjakan dan file utama.
3. Perintah yang dijalankan beserta PASS/FAIL/NOT_RUN dan bukti.
4. Keputusan/default yang diubah serta alasan.
5. Pekerjaan tersisa atau data OPEN yang benar-benar dibutuhkan tahap berikutnya.

Jangan menuliskan fitur seluruh sistem selesai ketika hanya UI yang terbentuk. Jangan membuat presentase kemajuan tanpa dasar daftar penerimaan.

## PLAN-03 — Perubahan spesifikasi

Saat menemukan konflik: tulis contoh pemicu dan hasil yang seharusnya, perbaiki dokumen pemilik aturan, sesuaikan schema/API/tes, lalu jalankan validasi doc. Tambah ID baru jika fitur berbeda; jangan memakai kembali ID lama untuk arti lain tanpa catatan versi.

Permintaan tambahan dari pengguna dapat mengubah scope. Catat apakah mengganti default, menjawab OPEN atau menambah fitur. Bukti pengujian harus tetap mengikuti perilaku final.
