# 07 — Pengujian dan Kriteria Penerimaan

Baseline 1.1. Dokumen ini spesifikasi tes, bukan laporan lulus. Status bukti aktual per kasus dicatat di [keterlacakan](10-TRACEABILITY.md#status-bukti-aktual).

## TEST-01 — Lapisan bukti

- Unit Vitest: parser angka, pembulatan, alokasi diskon/retur, state UI murni.
- PostgreSQL integration: constraint, fungsi RPC, RLS/grants, rollback, laporan dan transaksi dua koneksi paralel. Mock tidak cukup untuk gate ini.
- Playwright: alur browser, refresh/timeouts, keyboard scanner simulasi, viewport PC/HP, role dan printing view.
- Hardware/UAT manual: scanner/printer asli, struk fisik, ayah/karyawan menjalankan tugas tanpa arahan langkah per langkah.
- Operasional: backup+restore nyata ke lingkungan uji, kuota/performa dan recovery sesi.

Runner yang tersedia: `npm run lint`, `npm run typecheck`, `npm run test` (Vitest unit + komponen jsdom), `npm run test:db` (PostgreSQL di database uji terpisah), `npm run test:db:cash-concurrency` (dua koneksi), `npm run verify:flows` (HTTP end-to-end pada data demo), `npm run build`. Playwright (`test:e2e`) **belum** dibuat; alur browser, viewport dan cetak masih NOT_VERIFIED.

## TEST-02 — Fixture

Gunakan akun owner/staff/maintainer/nonaktif terpisah, data fiktif dan project uji. Fixture kecil memuat lampu pcs, kabel berisi roll100m dan roll50m, dua sisa potongan6m/4m, dua lot harga beli berbeda, tiket toko/onsite, drawer/wallet dan pembayaran tunai/non-tunai.

Fixture performa: 10.000 SKU, 20.000 invoice, total100.000 item, 1.000 tiket dengan distribusi status, ledger/payment yang konsisten. Angka ini beban uji yang diusulkan, bukan estimasi volume toko atau janji muat. Isi di lokal dahulu, ukur ukuran; cloud test hanya pada project uji dengan sisa kuota cukup, tidak memenuhi produksi dengan fixture.

## Kasus penerimaan

### AT-01 — Auth dan multi-perangkat

Owner login PC dan HP bersamaan, melihat akun benar; staff akun terpisah. Nonaktifkan staff lalu panggil read/write dengan JWT lama: ditolak. Logout/expired pada PC tidak merusak data committed dan tidak menampilkan draf owner pada staff. Bukti: integration Auth/RLS + E2E.

### AT-02 — Hak akses melalui API langsung

Anon, staff dan maintainer mencoba posting harga/diskon/refund/role atau baca cost dengan payload buatan. Semua tindakan yang dilarang matrix ditolak tanpa efek. Staff tidak memperoleh cost dari read table/view/RPC/export/error. Bukti: integration pada koneksi/session role nyata, bukan tombol disembunyikan.

### AT-03 — Produk dan barcode

Barcode dengan nol depan tetap cocok; duplikat barcode/SKU ditolak; nama mirip dengan variasi berbeda boleh. Barcode asing tidak memberi staff hak tambah. Produk diarsip tidak bisa dijual baru, nota lama tetap lengkap. Dua scan sah barang sama menghasilkan qty2. Bukti: DB + E2E.

### AT-04 — Satuan dan harga meter

Terima roll100m biayaRp500.000, hargaRp7.500/m. Jual2,5m: tagihanRp18.750, qty sisa97,5m, modal keluarRp12.500, laba kotorRp6.250. Posisi roll menjadi tidak bersegel. Bukti: unit + DB + struk E2E.

### AT-05 — Presisi dan batas input

Stok1m dijual0,1m sepuluh kali: sisa tepat0, modal lot tersisa0. Pcs1,5 ditolak. Qty0/negatif/Infinity/NaN/lebih dari3desimal/di luar step ditolak sebelum coercion. Uji overflow uang dan desimal string locale. Bukti: property/table-driven unit + DB parity.

### AT-06 — Roll utuh dan panjang kontinu

Sisa6m dan4m tidak bisa memenuhi satu potongan10m; UI meminta pilihan fisik yang benar. Total100m dari banyak potongan tidak bisa dijual sebagai roll100m segel utuh. Retur potongan membuat posisi baru. Bukti: DB + UI.

### AT-07 — Diskon dan rounding

Nilai barisRp10.001 diskon10% ->Rp9.001. Tiga barisRp100 dengan diskon notaRp1 -> alokasi[1,0,0], net[99,100,100], total299. Semua baris0 mewajibkan diskon nota0. Diskon di luar batas/staff diskon ditolak. Sum alokasi dan total exact. Bukti: unit golden vectors + DB.

### AT-08 — Keranjang/hold dan harga berubah

Hold tidak mengurangi stok. Ubah harga di server, lanjutkan draf: PRICE_CHANGED dan tinjauan ulang, tidak ada posting. Reload draf aman dan label lokal jelas. Batas5 draf menolak tambahan tanpa menghapus yang lama. Bukti: E2E.

### AT-09 — Finalisasi atomik dan tunai

TotalRp18.750, tenderRp20.000 -> changeRp1.250; receipt/cash inflow18.750. Simulasikan error setelah invoice sebelum stock: seluruh invoice/payment/movement/audit result rollback. Non-tunai tidak menambah drawer. Bukti: integration failpoint test-only yang tidak tersedia produksi.

### AT-10 — Retry dan hasil UNKNOWN

Submit dua kali key/hash sama menghasilkan satu nota, satu efek stock/payment. Key sama payload berbeda ditolak. Hilangkan respons setelah commit, reload/login lagi lalu lookup key: nota asal ditemukan. NOT_FOUND selama operasi berlangsung tidak mendorong key baru. Bukti: DB concurrency + E2E network interception.

### AT-11 — Dua pembeli stok terakhir

Dua koneksi melakukan sale qty1 terhadap stok1 dengan operation id berbeda. Tepat satu sale berhasil, satunya INSUFFICIENT_STOCK; stok0, satu receipt/COGS. Uji dua SKU urutan keranjang terbalik untuk deadlock/retry aman. Bukti: integration parallel database sessions.

### AT-12 — Struk dan perangkat

Cetak ulang tiga kali tidak menambah transaksi. Printer dicabut setelah sale berhasil: nota tetap dapat ditemukan. Struk fisik tidak terpotong pada ukuran terpilih; nama panjang/qty pecahan/kembalian terbaca. Scanner asli bekerja saat fokus pencarian dan tidak merusak input pelanggan. Bukti: E2E + hardware manual; simulasi tidak menggantikan hardware.

### AT-13 — Retur parsial dan total

Baris net100 qty3: tiga retur qty1 menghasilkan refund33,34,33. Retur berikutnya ditolak. Diskon/harga terbaru tidak memengaruhi refund. Stok/modal kembali sesuai alokasi asal; damaged tidak tersedia dijual. Bukti: unit + DB + E2E.

### AT-14 — Modal historis dan lot

Terima2pcs biaya total20.000, lalu2pcs biaya total30.000. Jual3pcs bulk FIFO ->COGS35.000, sisa1pcs nilai15.000. Harga katalog/beli baru tidak mengubah nota tersebut. Retur barang yang berasal lot kedua mengembalikan modal15.000. Bukti: DB reconciliation.

### AT-15 — Barang masuk, stok awal dan impor

Penerimaan posted dua kali dengan key sama menambah stok sekali. OPENING menambah qty/modal tanpa purchase payment/omzet/kas. Import duplikat/konversi salah muncul di pratinjau; batch gagal tidak ditandai semua selesai. Bukti: DB + UI.

### AT-16 — Transfer, kerusakan dan opname

Pindah2part SHOP->FIELD: kepemilikan total tetap, shop berkurang2. Kembalikan1: field1. Opname dengan version lama ditolak setelah penjualan concurrent. Disposal hanya mengurangi barang/kosten sekali, tidak membuat penjualan. Bukti: DB + invariant ledger.

### AT-17 — Penerimaan toko/onsite

Tiket toko membutuhkan kondisi/kelengkapan minimal dan custodySHOP; onsite alamat/jadwal dan custodyCUSTOMER. Estimasi boleh belum diketahui. Gagal upload foto tidak menghapus tiket. Barang dibawa dari rumah->ayah->toko tercatat pada tiket sama. Bukti: DB + E2E.

Tambahan pelanggan: penjualan biasa tanpa pelanggan harus berhasil; dua anggota keluarga boleh memakai nomorHP sama tanpa auto-merge; servis tanpa nomorHP memerlukan alternate_contact yang benar-benar diisi. Nomor/alias dinormalisasi tanpa mengubah identitas pelanggan lain.

### AT-18 — Persetujuan dan transisi

NEW->WORKING langsung ditolak. AWAITING_APPROVAL->WORKING tanpa persetujuan ditolak. Estimasi disetujui100.000, tagihan120.000 ditolak sampai revisi disetujui. READY tanpa hasil uji ditolak. Koreksi terminal hanya sebelum invoice/closed, alasan wajib. Bukti: table-driven DB seluruh pasangan status.

### AT-19 — Spare part digunakan sekali

USE1 part mengurangi stock1 dan menyimpan cost. Finalisasi/pelunasan servis tidak mengurangi lagi. REVERSE sebelum final memulihkan qty/cost tepat sekali, tidak melebihi USE. Part tidak ditagih tetap diakui sebagai biaya tiket ketika final. Bukti: DB.

### AT-20 — DP dan pelunasan

TerimaDP50.000 saat total belum ditentukan: tampil UNPRICED, bukan Lunas. Final tagihan150.000 ->sisa100.000; pelunasan100.000 ->PAID; penerimaan total150.000, revenue invoice150.000 sekali. Pembayaran final kurang dari seluruh sisa ditolak pada R1. Bukti: DB + UI.

### AT-21 — DP berlebih/batal

DP100.000, invoice penyelesaian80.000 ->refund_due20.000. Refund20.000 menghapus kewajiban, revenue tetap80.000. Pembatalan dengan invoice0 ->refund100.000; tidak otomatis hangus. Refund ulang/lebih receipt ditolak. Bukti: DB + UI.

Pembatalan awal tanpa estimasi disetujui hanya dapat invoice0 melalui pembebasan eksplisit owner; null biaya biasa tidak cukup. Refund cash dengan dana cashbox kurang ditolak atomik; setelah penambahan dana sah, refund dapat dicoba kembali tanpa duplikasi.

### AT-22 — Pengambilan dan penutupan

READY dan PAID tetapi custodySHOP tetap Belum diambil. Handover butuh nama penerima dan seluruh syarat; perubahan custody/closed atomik. UNREPAIRABLE dengan barang masih dititipkan tetap muncul. Onsite custodyCUSTOMER ditutup tanpa status Diambil palsu. Bukti: DB + E2E.

### AT-23 — Keluhan kembali

Buat tiket terkait invoice/tiket lama; riwayat asal tidak berubah. Tidak ada masa garansi atau gratis otomatis. Owner menetapkan biaya0 secara eksplisit bila disetujui. Bukti: DB + E2E.

### AT-24 — Kas ayah dan drawer

Drawer awal200.000, sale cash50.000, sale transfer30.000, expense20.000 ->expected230.000. Wallet menerimaDP100.000 lalu transfer60.000 ke drawer ->wallet40.000, drawer290.000; penerimaan pelanggan tidak naik karena transfer. Count drawer289.000 ->variance-1.000, tidak ada adjustment otomatis. Bukti: DB + UI.

### AT-25 — Tutup kas concurrent dan koreksi bayar

Tutup sesi bersamaan dengan payment: payment tercakup jika commit sebelum snapshot atau ditolak karena closed; tidak hilang dari saldo. Koreksi metode payment tunai ke transfer membalik cash sesi saat ini dan membuat receipt pengganti tanpa perubahan invoice/stock/pendapatan. Kasus receipt sudah direfund parsial ditolak sesuai kontrak. Bukti: DB parallel.

### AT-26 — Laporan, tanggal dan peran

Invoice akhir hari Jakarta dan refund awal hari berikut masuk periode masing-masing. DP tidak menjadi omzet sebelum invoice final. Total servis tidak dijumlahkan lagi sebagai SALE. Service COGS hanya recognition, bukan event+invoice dua kali. Laporan staff tidak mengandung modal. Bukti: fixture DB dengan nilai harapan independen.

### AT-27 — Foto dan ekspor

Anon tidak dapat foto; staff/owner sesuai policy. Akun nonaktif tidak memperoleh URL baru; URL lama tunduk expiry yang didokumentasikan. File berbahaya/oversize ditolak. CSV text `=HYPERLINK(...)` dan prefix lain tidak dieksekusi sebagai formula. PENDING orphan dibersihkan tanpa menghapus READY. Bukti: integration + file checks.

### AT-28 — Jaringan dan storage lokal

Offline: draf tetap bisa diedit, finalisasi diblokir. Storage quota/browser write error: pesan Draf belum tersimpan, bukan sukses palsu. Schema draf berubah: migrasi/penjelasan pemulihan, bukan hapus diam-diam. Logout/akun lain tidak melihat draf sensitif. Bukti: E2E.

Periksa IndexedDB setelah logout/pergantian akun: payload sensitif pengguna lama sudah dibersihkan setelah konfirmasi logout; namespace tersembunyi saja tidak cukup. ID minimum operasi UNKNOWN masih bisa dipakai lookup setelah login pemilik, tetapi tidak boleh merekonstruksi pelanggan/amount yang sudah dibuang.

### AT-29 — Setup dan pemulihan

Setup belum punya identitas/modal/faktor: checklist menunjukkan kekurangan, transaksi produk invalid ditolak. Backup+foto dibuat, pulihkan ke proyek uji; verifikasi counts, hashes, user login/reset path, RLS, receipt/stock/DP/attachment dan invoice dapat dibuka. RPO/RTO aktual dicatat. Bukti: drill nyata, bukan file backup sekadar ada.

### AT-30 — Kapasitas, performa dan usability

Catat fixture, ukuran tabel/index/Storage, browser, jaringan, versi build dan sampel request (minimum100 untuk target p95 RPC). Ukur NFR dan payload; tiga sesi aktif. Uji viewport PC/HP dan tugas ayah/karyawan tanpa panduan. Catat waktu/titik bingung; gagal target kritis menjadi perbaikan, bukan diberi label pass. Bukti: benchmark + UAT.

## TEST-03 — Hasil dan gate

Laporan uji memuat commit/build, schema version, lingkungan, perintah, waktu, status PASS/FAIL/NOT_RUN, bukti dan masalah tersisa. Framework unit/coverage tidak menggantikan bukti DB/hardware. Untuk uang/stok/otorisasi, seluruh cabang bisnis dan vektor tepi wajib diuji; tidak membuat tes yang hanya memanggil implementasi yang sama sebagai expected value.

No-go bila ada uang/qty salah, duplicate commit, akses cost staff/anon, restore gagal, atau status sukses palsu. Hasil NOT_RUN pada hardware/pemulihan tidak boleh diklaim siap produksi penuh. Gate lengkap ada pada [operasi/rilis](08-OPERATIONS-RELEASE.md).
