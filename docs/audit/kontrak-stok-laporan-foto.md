# Kontrak RPC — Stok, Laporan, Foto, Pengaturan, Backup

Perbaikan audit 2026-09 (domain operasi). Migrasi: `20260918004100_ops_stock.sql`, `004200_ops_reports.sql`,
`004300_ops_attachments.sql`, `004400_ops_settings_health.sql`. Uji: `supabase/tests/stock_*.sql`, `report_*.sql`,
`attach_storage.sql`, `p4_setup_health.sql`, `p4_extra.sql`.

## Konvensi umum

- Semua fungsi `public.*(p_input jsonb)`, EXECUTE hanya `authenticated`. Baris pertama `private.require_role`:
  akun tidak aktif/tidak terdaftar → `ACCOUNT_INACTIVE` (SQLSTATE 42501); peran salah → `FORBIDDEN` (42501).
- Error: `KODE: kalimat awam`. Kode yang dipakai domain ini: `INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_DATE`,
  `NOT_FOUND`, `VERSION_CONFLICT` (40001), `INSUFFICIENT_STOCK`, `ALREADY_FINALIZED`, `ATTACHMENT_INVALID`,
  `STORAGE_LIMIT`, `IDEMPOTENCY_CONFLICT`. Pesan tidak memuat nilai modal atau isi baris.
- Field tidak dikenal ditolak (`INVALID_INPUT: Field tidak dikenal: ...`).
- Angka: string desimal kanonik (`"2.5"`, bukan `2.5`, bukan `"-2"`). Versi/limit/offset: bilangan bulat (angka atau teks digit).
- Perintah tulis: `operation_id` UUID wajib; ulang dengan payload sama → hasil sama; payload beda → `IDEMPOTENCY_CONFLICT`.
  **Nama command idempotensi = nama RPC** sehingga `get_operation_v1({command:'dispose_stock_v1', operation_id})`
  menemukan hasil (bug lama: disposal tersimpan sebagai `post_disposal_v1`).
- Tanggal: `start_date`/`end_date` `YYYY-MM-DD`, jendela `[00:00 WIB start, 00:00 WIB hari setelah end)`; rentang
  bersebelahan tidak tumpang tindih. Maksimal 366 hari.
- Keluaran tulis: `ok`, `operation_id`, `entity_id`, `document_number` bila ada, `server_time`, `schema_version`, `version`.

## Stok (hanya OWNER untuk tulis)

Urutan lock: products → inventory_lots → stock_positions (id naik); versi diperiksa setelah lock. Tidak ada jalur yang
membuat qty/modal negatif (CHECK tabel + validasi `INSUFFICIENT_STOCK`).

### transfer_stock_v1

```json
{"operation_id":"…","position_id":"…","expected_version":3,"qty_base":"20",
 "destination_location":"FIELD_FATHER","destination_condition":"SALEABLE","destination_label":"R002-F",
 "reason":"Dibawa ayah","note":"opsional"}
```

- `reason` wajib (≤500). `qty_base` kelipatan `quantity_step` produk dan ≤ qty posisi.
- Produk roll: `destination_label` wajib dan unik; produk bulk: label ditolak.
- Tujuan (lokasi, kondisi) harus berbeda dari asal. Transfer penuh roll bersegel mempertahankan segel; parsial membuka segel.
- Hasil: `source_position_id`, `source_version`, `source_qty_base`, `destination_position_id`, `destination_version`, `qty_base`.
  Modal lot tidak berubah.

### adjust_stock_v1

Kurangi (modal keluar proporsional lot posisi, BR-05):

```json
{"operation_id":"…","direction":"OUT","position_id":"…","expected_version":2,"qty_base":"2","reason":"Pecah di rak"}
```

Tambah (lot koreksi baru, bukan pembelian):

```json
{"operation_id":"…","direction":"IN","product_id":"…","location":"SHOP","condition":"SALEABLE","qty_base":"3",
 "acquisition_cost":"36000","cost_confirmed":true,"reason":"Ditemukan di gudang"}
```

- IN wajib salah satu: `acquisition_cost` (Rupiah bulat, total lot) + `cost_confirmed:true`, atau `zero_cost_reason`.
- IN produk roll: `label` unik wajib, `segment_capacity` opsional (default = qty).
- Hasil: `direction`, `position_id`, `version`, `qty_base`, `position_qty_base`, `cost_delta` (negatif untuk OUT).

### dispose_stock_v1

`{"operation_id","position_id","expected_version","qty_base","reason","note"?}` → `cost_removed`, `remaining_qty_base`,
`position_id`, `version`. Kerugian disposal tercatat sebagai movement `DISPOSAL` (dilaporkan terpisah dari laba kotor).

### Opname: create_stock_count_v1 / get_stock_count_v1 / list_stock_counts_v1 / post_stock_count_v1

Mulai (OWNER): `{"operation_id","position_ids":[…]}` **atau** `{"operation_id","product_ids":[…],"location"?:"SHOP"}`
(maks 200 posisi; produk → semua posisi berstok). Menyimpan `expected_version` dan `system_qty` tiap posisi.
Hasil: `entity_id` (count_id), `status:"DRAFT"`, `item_count`. Toko tidak diblokir selama menghitung.

Baca (OWNER/MAINTAINER): `get_stock_count_v1({count_id})` → `items[]` berisi `system_qty`, `expected_version`,
`current_qty`, `current_version`, `changed_since_start`, `counted_qty`, `difference`, `cost_delta`.
`list_stock_counts_v1({status?, limit?, offset?})` → `rows`, `has_more`, `next_offset`.

Posting (OWNER):

```json
{"operation_id":"…","count_id":"…","reason":"Opname bulanan","items":[
  {"position_id":"…","counted_qty":"97.5","reason":"Terpotong tanpa nota"},
  {"position_id":"…","counted_qty":"12","acquisition_cost":"24000","cost_confirmed":true},
  {"position_id":"…","counted_qty":"51","zero_cost_reason":"Sisa ukur","new_label":"R002-K1"}]}
```

- `items` wajib mencakup setiap posisi hitungan tepat sekali; `counted_qty` desimal ≥0 kelipatan langkah stok.
- Versi posisi mana pun berubah sejak mulai → `VERSION_CONFLICT`, seluruh batch batal (buat hitungan baru).
- Selisih kurang → movement `COUNT_OUT` dengan modal lot posisi. Selisih lebih → lot koreksi `COUNT_IN` dengan modal
  terkonfirmasi atau alasan modal nol; produk roll wajib `new_label` (potongan baru).
- Satu dokumen `COUNT` untuk semua selisih. Hitungan POSTED tidak dapat diposting ulang → `ALREADY_FINALIZED`.
- Hasil: `status:"POSTED"`, `adjusted_lines`, `cost_delta`, `document_number` (null bila tanpa selisih).

### list_stock_positions_v1 / list_stock_movements_v1 (OWNER/STAFF/MAINTAINER)

- Posisi: `{product_id?, location?, condition?, include_empty?, query?, limit? (1-100), offset?}` → `rows[]`
  (`position_id`, `version`, `sku`, `name`, `location`, `condition`, `qty_base`, `label`, `segment_capacity`, `sealed`,
  `lot_id`, `lot_posted_at`; OWNER/MAINTAINER juga `lot_remaining_qty`, `lot_remaining_cost`), `has_more`, `next_offset`.
- Mutasi: wajib salah satu `product_id`/`position_id`/rentang tanggal; `{kind?, limit?, offset?}` → `rows[]` urut
  `occurred_at desc, id desc` dengan `kind`, `qty_delta`, `document_number`, `document_kind`, `reason`,
  `invoice_number`, `service_ticket_number`, `actor_name`; `cost_delta` hanya OWNER/MAINTAINER.

## Laporan dan beranda

### get_report_v1 (OWNER/STAFF/MAINTAINER; D2)

Input `{"start_date":"2026-09-01","end_date":"2026-09-30"}`. Keluaran (semua uang string):

```json
{"schema_version":2,"period":{"start_date":"2026-09-01","end_date":"2026-09-30","start_at":"…","end_at":"…"},
 "sales":{"invoice_total":"100000","invoice_count":1,"credit_total":"0","credit_count":0,"net":"100000"},
 "service":{"invoice_total":"75000","invoice_count":1,"credit_total":"0","credit_count":0,"net":"75000"},
 "customer_receipts":{"total":"175000","by_method":{"CASH":"145000","TRANSFER":"0","QRIS":"30000"},
   "sale":"100000","service":"75000","deposit_total":"30000","deposit_by_method":{"CASH":"0","TRANSFER":"0","QRIS":"30000"}},
 "customer_refunds":{"total":"0","by_method":{…},"sale":"0","service":"0"},
 "net_customer_receipts":"175000",
 "payment_corrections":{"reversal_total":"45000","replacement_total":"45000","net":"0","net_by_method":{"CASH":"-45000","TRANSFER":"45000","QRIS":"0"}},
 "net_by_method":{"CASH":"100000","TRANSFER":"45000","QRIS":"30000"},
 "sales_net":"100000","service_net":"75000","credit_total":"0","receipts":"175000","refunds":"0",
 "cost":{"sale_cogs_allocated":"20000","sale_cogs_reversed":"0","sale_cogs_net":"20000",
   "service_cogs_recognized":"12001","service_cogs_reversed":"0","service_cogs_net":"12001","cogs_net":"32001","rounding":"…"},
 "gross_profit":{"sale":"80000","service":"63000","total":"143000","note":"… BUKAN laba bersih …"},
 "stock_losses":{"disposal_cost":"10000","adjustment_out_cost":"0","adjustment_in_cost":"0","note":"…"},
 "cogs":"32001"}
```

Definisi (BR-13):
- Neto barang/servis = invoice diposting di periode − credit note diposting di periode (per `posted_at` masing-masing).
  Retur bulan berikutnya mengurangi bulan retur (boleh negatif); bulan jual tidak berubah.
- Penerimaan pelanggan = payment IN `SALE_RECEIPT`/`SERVICE_RECEIPT` per `occurred_at`; `deposit_total` = uang muka lama
  (penerimaan servis sebelum tagihan tiket diposting; sejak 18-09-2026 tidak ada uang muka baru). Refund = OUT `CUSTOMER_REFUND`. Koreksi metode dipisah (net nol).
- COGS barang = Σ `cost_allocations` untuk invoice SALE diposting di periode − Σ `credit_note_items.cost_reversal_amount`
  untuk credit note SALE diposting di periode (`cost_allocations.reversed_cost` tidak dipakai). COGS servis =
  Σ `service_cost_recognitions` invoice SERVICE di periode − reversal credit note SERVICE di periode.
  Dihitung 6 desimal, dibulatkan ke Rupiah pada agregat.
- Laba kotor = neto − COGS neto; bukan laba bersih. Kerugian disposal/koreksi stok terpisah.
- **STAFF**: kunci `cost`, `gross_profit`, `stock_losses`, `cogs` tidak ada sama sekali.
- Titik perluasan retur distributor (D5): tambahkan bagian terpisah di `private.ops_cost_summary` setelah tabel
  `supplier_returns` digabung; jangan dicampur ke omzet atau laba kotor penjualan.

### get_dashboard_v1 (OWNER/STAFF/MAINTAINER)

Input `{}`. "Hari ini" = `private.local_today()` WIB. Keluaran: `today` (struktur sama dengan ringkasan pendapatan di
atas), kunci ringkas lama (`sales_total`, `sales_count`, `service_total`, `refund_total`, `receipts_cash`,
`receipts_transfer` = TRANSFER+QRIS, `cash_session_open`, `low_stock`), `cash_sessions[]` per cashbox (`open`,
`opened_at`, `business_date`, `opened_by`; `expected_amount` hanya OWNER/MAINTAINER), `service`
(`active_by_status`, `active_total` — hanya layanan yang belum selesai, `receivable_count`, `receivable_total`, `receivables[]` maks 10 `{ticket_id, number, customer_name, completed_at, outstanding, note}` = piutang servis, `not_picked_up_count` + `not_picked_up[]` maks 10 — status terminal
READY/UNREPAIRABLE/CANCELLED/ONSITE_DONE dengan custody SHOP/FATHER walau lunas, `scheduled_today[]` maks 20),
`low_stock_items[]` maks 10, `backup` (`last_status`, `last_success_at`, `age_hours`, `stale` bila >24 jam), `refreshed_at`.

### export_csv_v1

```json
{"dataset":"invoices","start_date":"2026-08-01","end_date":"2026-08-31","limit":1000,"cursor":null}
```

- Keputusan peran: `invoices` untuk OWNER/STAFF/MAINTAINER (omzet, tanpa modal, D2); `products` hanya
  OWNER/MAINTAINER; `include_cost:true` (kolom `inventory_cost`) hanya OWNER.
- Halaman diambil dulu (`LIMIT limit+1`) baru diagregasi; urutan stabil `invoices: posted_at, id`,
  `products: lower(sku), id`. Pakai `cursor` (= `next_cursor` sebelumnya) **atau** `offset`, bukan keduanya. `limit` 1–1000.
- Keluaran: `columns` (urutan kolom), `rows` (objek), `count`, `has_more`, `next_cursor`, `next_offset`,
  `csv_header`, `csv_rows` (RFC 4180, semua sel dikutip, baris `\r\n`). Klien cukup menulis
  `BOM + csv_header + \r\n + csv_rows` per halaman.
- Kolom invoices: `number, kind, posted_at (WIB), customer, petugas, payment_methods (metode berlaku setelah koreksi),
  subtotal, discount, total`. Teks melewati `private.csv_safe`: diawali `= + - @`, tab, CR, atau spasi/kontrol
  lalu karakter formula → diberi prefiks `'`.

## Foto tiket

Policy `storage.objects` memanggil `storage_access.can_read_ticket_photo(name)` /
`storage_access.can_upload_ticket_photo(name)` (SECURITY DEFINER, `search_path=''`, USAGE+EXECUTE hanya
`authenticated`, akun aktif). Slot PENDING berlaku 30 menit.

- `prepare_attachment_v1` (OWNER/STAFF; target produk hanya OWNER):
  `{"operation_id","ticket_id","mime":"image/jpeg","byte_size":183422}` → `bucket`, `object_key` (acak
  `uuid/uuid.jpg`), `upload_expires_at`, `state:"PENDING"`. Kuota 5 per tiket = READY + PENDING belum kedaluwarsa
  → `STORAGE_LIMIT`. MIME JPEG/PNG/WebP, 1 byte–1 MiB → selain itu `ATTACHMENT_INVALID`.
- Unggah: `supabase.storage.from('ticket-photos').upload(object_key, file, {contentType})` — hanya pembuat slot aktif.
- `finalize_attachment_v1` (pembuat slot atau OWNER): `{"operation_id","attachment_id"}`. Wajib ada baris
  `storage.objects` (bucket `ticket-photos`, name = object_key) dengan `metadata.size` = byte_size dan
  `metadata.mimetype` = mime; selain itu `ATTACHMENT_INVALID`. Slot orang lain untuk STAFF → `NOT_FOUND`.
  Sudah READY → `ALREADY_FINALIZED`. Kuota READY diperiksa ulang.
- `list_attachments_v1({ticket_id}|{product_id})` dan `get_attachment_url_v1({attachment_id})` (semua peran aktif):
  hanya READY. Signed URL dibuat klien (300 detik); policy baca memvalidasi ulang.

**Verifikasi manual HTTP** (belum dapat diuji otomatis karena Storage API hanya melayani database `postgres`):
setelah migrasi diterapkan ke Supabase lokal, login staff di aplikasi → tiket → Tambah Foto. Harapan: upload 200,
tidak ada `permission denied for function`; `finalize` sukses; foto tampil (signed URL 200); akun maintainer dapat
melihat, akun nonaktif mendapat 400/403; unggah ke key acak lain ditolak 403 (RLS).

## Profil, pengaturan, kesehatan

- `get_current_profile_v1()` (peran aktif): `id`, `display_name`, `role`, `active`, `version`, `capabilities`
  (`view_cost`, `view_revenue`, `manage_stock`, `sell`, `export_invoices`, `export_products`, `manage_settings`,
  `view_health_detail`) — hanya panduan UI.
- `get_shop_settings_v1()` (peran aktif): `name`, `address`, `phone`, `currency`, `timezone`, `receipt_width`,
  `configured`, `configured_at`, `version`.
- `update_shop_settings_v1` (OWNER): `{"operation_id","expected_version":4,"name"?,"address"?,"phone"?,"receipt_width"?}`.
  `expected_version` wajib; nama 1–100, alamat ≤300, telepon ≤40 (angka, spasi, `+-.()`), lebar 58/80.
  Zona waktu/mata uang tidak dapat diubah lewat RPC ini.
- `get_health_v1()`: STAFF → `last_backup`, `last_successful_backup_at`, `backup_stale`; OWNER → + `db_size_bytes`,
  `detail` (jumlah data, foto, PENDING aktif/kedaluwarsa, status backup terakhir); MAINTAINER → + `technical`
  (versi PostgreSQL, error backup tersensor, 10 backup terakhir, tabel terbesar).

## Backup dan restore

Lihat runbook [OPS-04A](../08-OPERATIONS-RELEASE.md). Ringkas:

- `npm run backup` → folder `<label>` berisi dump aplikasi + platform + foto + manifest; status ke
  `private.backup_runs` (`BACKUP_RECORD_RUN=no` untuk sumber read-only); cermin ke `BACKUP_MIRROR_DIR` diverifikasi
  hash; retensi `BACKUP_RETENTION` backup SUCCEEDED. Kunci rahasia hanya dibaca dari env.
- `npm run restore` dengan `RESTORE_DB_URL` database kosong. Ditolak bila target = sumber atau bernama `postgres`
  tanpa `RESTORE_ALLOW_APP_DB=yes` + ketik ulang nama; selalu ditolak bila target sudah punya schema `private`.
  Verifikasi hash → restore platform (bila perlu) → data auth/storage → aplikasi → policy → cek baris, RPC, foto,
  invariant stok, RPC sebagai OWNER → `restore-report-<db>.json`.

## Catatan untuk UI (belum diubah di branch ini)

- `src/features/dashboard.tsx` tetap kompatibel (kunci lama dipertahankan) tetapi tanggal default memakai UTC dan
  ekspor CSV merakit teks tanpa escape; ganti dengan `csv_header`/`csv_rows` dan loop `has_more`.
- `src/features/photos.tsx` perlu memeriksa `upload_expires_at` dan menampilkan kode `STORAGE_LIMIT`/`ATTACHMENT_INVALID`.
- Payload `adjust_stock_v1` berubah: wajib `direction`; qty selalu positif.
