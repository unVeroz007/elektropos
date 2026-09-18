# Perbaikan Audit Independen — September 2026

Dokumen kerja perbaikan. Sumber: audit 17 September 2026 (bukti SQL/HTTP dijalankan pada Supabase lokal).
Setiap ID temuan wajib ditutup oleh kode + uji yang membuktikan aturan bisnis, bukan implementasi.

## Keputusan pemilik (18 September 2026)

| No | Keputusan | Akibat pada sistem |
|---|---|---|
| D1 | STAFF boleh membuka dan menutup laci toko (SHOP_DRAWER) | Menu Kas untuk STAFF; saldo buka dibandingkan hitungan tutup terakhir, selisih ditandai untuk owner |
| D2 | STAFF boleh melihat omzet/penerimaan | Laporan & beranda untuk STAFF **tanpa** modal/COGS/laba kotor |
| D3 | Pembelian barang boleh dibayar tunai | Barang masuk CASH mengurangi kas dengan sesi terkunci dan cek saldo |
| D4 | Produksi awal memakai Supabase lokal di PC toko | Uji tidak boleh menyentuh database aplikasi; backup harus keluar PC; restore memulihkan aplikasi utuh |
| D5 | Barang retur akan dikembalikan ke distributor | Dokumen retur distributor (lihat default di bawah) |

Default D5 (dapat diubah pemilik): barang keluar stok menjadi **klaim distributor** senilai modal. Penyelesaian klaim:
`REFUND` (uang kembali; tunai masuk kas/transfer), `CREDIT` (potong tagihan berikutnya, tercatat sebagai saldo kredit distributor),
`REPLACEMENT` (barang pengganti masuk sebagai lot baru dengan modal = nilai klaim), `REJECTED` (ditolak; nilai menjadi kerugian tercatat).
Selisih uang kembali terhadap nilai klaim dicatat sebagai laba/rugi retur distributor, terpisah dari laba kotor penjualan.

## Konvensi wajib perbaikan

- RPC diawali `private.require_role(array[...])` (fondasi `20260918000100_fix_foundation.sql`). Akun nonaktif ditolak.
- Error: `raise exception 'KODE: kalimat awam'`. Kode stabil (mis. `INSUFFICIENT_STOCK`, `CASH_SESSION_CLOSED`, `PRICE_CHANGED`,
  `FORBIDDEN`, `ACCOUNT_INACTIVE`, `INVALID_NUMBER`, `INVALID_INPUT`, `VERSION_CONFLICT`, `IDEMPOTENCY_CONFLICT`, `REFUND_LIMIT_EXCEEDED`,
  `APPROVAL_REQUIRED`, `PAYMENT_OUTSTANDING`, `NOT_FOUND`, `INSUFFICIENT_CASH`). Jangan bocorkan isi baris/nilai modal di pesan.
- Angka wajib: `private.decimal_input`; opsional: `private.decimal_input_opt`. Tanggal: `private.date_range_input`/`private.local_day_start`.
- Kas tunai: `private.lock_open_cash_session(cashbox)`; jangan pernah menerima `cash_session_id` dari klien untuk menulis mutasi.
- Status operasi: `public.get_operation_v1({command, operation_id})`.
- Migrasi baru saja (jangan ubah migrasi lama). Uji: `node scripts/test-db.mjs` (database uji terisolasi, aman).

## Daftar temuan yang harus ditutup

### KRITIS
- K01 `finalize_sale_v1` tanpa cek peran/akun aktif; MAINTAINER bisa jual.
- K02 STAFF bisa diskon sampai 100%; T=0 tanpa alasan owner.
- K03 Filter tanggal laporan/dashboard/riwayat/CSV bergeser 14 jam.
- K04 Beberapa baris produk sama: nota 30, stok/modal terpotong 20 (sisa alokasi diabaikan).
- K05 Roll BR-03: potongan dijumlahkan jadi satu potongan/roll; pass alokasi memotong roll bersegel; posisi tidak dipilih.
- K06 Retur membalik modal dari satu alokasi saja, tidak kumulatif; reversed_qty > qty alokasi.
- K07 `handover_service_v1` tanpa syarat tagihan final/lunas/refund_due; location tak tervalidasi.
- K08 `finalize_service_invoice_v1` tanpa batas persetujuan dan langsung menutup tiket sebelum bayar.
- K09 `record_service_payment_v1` CASH tanpa sesi tidak masuk laci; `cash_session_id` klien bisa sesi tertutup/FATHER_WALLET; tendered/change dari klien.
- K10 Race tutup kas vs pembayaran: mutasi masuk setelah snapshot tutup.
- K11 `correct_payment_v1` menulis ke sesi tertutup; `return_sale_v1` tanpa refund_method dicatat CASH tanpa mutasi laci.
- K12 `list_service_tickets_v1` selalu error 42703; UI menelan error.
- K13 Upload foto 403 (EXECUTE helper policy dicabut); finalize READY tanpa objek dan oleh siapa pun.

### TINGGI
- T01 Kasir membuat operation_id baru tiap klik; tidak ada cek status operasi (get_operation_v1).
- T02 UI mengirim `confirmed: true` otomatis untuk TRANSFER/QRIS (kasir & barang masuk).
- T03 Keranjang bergantung hasil pencarian aktif; qty kosong membuat render throw.
- T04 Draf menimpa draf tunggal; tanpa batas 5; tanpa schema_version; tidak dibersihkan saat logout.
- T05 Retur tidak terjangkau UI; banyak FR tanpa UI (estimasi/persetujuan, part, DP/pelunasan, tagihan servis, serah terima,
  transfer/penyesuaian/disposal/opname, koreksi bayar, transfer kas); opname tanpa RPC pembuat; penyesuaian negatif mustahil.
- T06 WORKING tanpa estimasi disetujui; UI mengisi test_result 'OK' palsu.
- T07 Retur NONE membalik COGS; retur pecahan untuk barang pcs; retur nota T=0 ditolak.
- T08 Intake roll: beberapa roll jadi satu posisi.
- T09 Restore drop schema tanpa cek target≠sumber, hanya schema private (0 RPC), foto tak dibackup; test:db mereset DB aplikasi.
- T10 Uji mengesahkan bug (AT-06), label PASS hardcoded, verify:flows hanya cek `ok`.

### SEDANG
- S01 BR-04 G_i dibulatkan sebelum diskon; total UI ≠ server.
- S02 Laporan: sales_net tidak neto, COGS reversal di periode jual, COGS servis tidak ada, peran (lihat D2).
- S03 export_csv LIMIT/OFFSET rusak; CSV klien tanpa escape.
- S04 Error DB mentah (isi baris) ke klien/UI.
- S05 reverse_service_part_v1 tidak kembalikan stok/modal; tagihan mengakui modal part yang sudah di-reverse.
- S06 upsert_product menonaktifkan satuan walau hanya nama/rak berubah; versi di keranjang basi.
- S07 Foto tanpa kompresi; slot PENDING gagal ikut kuota.
- S08 Struk kurang metode, bayar/kembalian, petugas, satuan.
- S09 CASH tanpa tendered diterima; saldo buka laci bebas.
- S10 Layout HP (sidebar tetap), teks kecil, target sentuh 36px, elemen klik non-keyboard, tutup kas tanpa konfirmasi, indikator online palsu.
- S11 Label teknis (base, COGS, UUID, CASH, PAID); tanggal default UTC.
- S12 Kamera menambah qty berulang saat barcode ditahan.
- S13 Cache React Query tidak dibersihkan saat logout.

### RENDAH/INFO
- R01 EXECUTE `cash_session_expected` ke PUBLIC (ditutup di fondasi).
- R02 Migrasi lama tidak idempoten (dibiarkan; dilacak CLI).
- R03 Indeks ganda cost_allocations; tanpa CHECK reversed ≤ alokasi.
- R04 Dokumen: test:e2e, get_operation_v1, 11 RPC tak terdokumentasi; `allocateCost` mati.
- R05 Fixture seed ikut ke DB aplikasi (`sql_paths` dikosongkan di fondasi).

## Status penutupan (18 September 2026)

Semua temuan di atas ditangani di branch `fix/audit-menyeluruh`. Bukti per kasus uji ada di
[keterlacakan](../10-TRACEABILITY.md#status-bukti-aktual). Ringkas:

| Temuan | Status | Bukti utama |
|---|---|---|
| K01–K02 | Tertutup | `require_role` di semua RPC; `verify:flows` (akun teknis/diskon staff ditolak) |
| K03 | Tertutup | `private.date_range_input`; `report_period.sql` jam 00:00/00:30/13:30/23:59 WIB |
| K04–K06 | Tertutup | `sales_finalize.sql`, `sales_roll.sql`, `sales_return.sql` (multi-lot COGS neto 0) |
| K07–K09 | Tertutup | `service_flow.sql`, `service_money.sql`, `verify:flows` |
| K10–K11 | Tertutup | trigger `cash_movements_guard`, `test:db:cash-concurrency`, `cash_correct_payment.sql` |
| K12 | Tertutup | `list_service_tickets_v1` diperbaiki; UI menampilkan error (uji komponen) |
| K13 | Tertutup | helper policy di schema `storage_access`; `verify:flows` unggah foto ke Storage nyata |
| T01–T04 | Tertutup | `useCommand` + `get_operation_v1`, konfirmasi eksplisit, keranjang snapshot, draf maks 5 (uji Vitest) |
| T05 | Tertutup | UI retur, estimasi/persetujuan, part, tagihan, pembayaran, serah terima, stok (pindah/koreksi/buang/hitung), kas, koreksi cara bayar, distributor |
| T06–T08 | Tertutup | `service_guards.sql`, `sales_return.sql`, barang masuk satu posisi per roll |
| T09 | Tertutup | `test:db` di database terpisah; backup lengkap + restore diverifikasi; `setup:demo` tanpa reset |
| T10 | Tertutup | uji ditulis ulang dari aturan bisnis; `verify:flows` memeriksa nilai |
| S01–S13 | Tertutup | lihat keterlacakan; S10 tampilan HP dirancang responsif tetapi belum diuji di perangkat |
| R01–R05 | Tertutup | EXECUTE fungsi private dicabut; dokumen & perintah diperbarui; fixture tidak masuk DB aplikasi |

Sisa yang belum terbukti (bukan kegagalan, belum ada perangkat/pengguna): cetak fisik 58/80 mm, scanner & kamera
nyata, tampilan di HP nyata, putus jaringan nyata, performa fixture besar, UAT dengan ayah/karyawan, pemulihan ke
instance Supabase kedua. Pengembalian fisik part servis setelah tagihan final belum tersedia (koreksi harga lewat
nota kredit).
