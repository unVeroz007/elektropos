# Kontrak RPC — Kas, Pembelian, Distributor (perbaikan audit 2026-09)

Untuk agent frontend. Migrasi: `supabase/migrations/20260918002100..002500_*.sql`.
Uji: `supabase/tests/cash_*.sql`, `supabase/tests/supplier_*.sql`, `npm run test:db:cash-concurrency`.

## Konvensi umum

- Panggil `supabase.rpc('<nama>', { p_input: {...} })`. Semua angka uang/qty dikirim **string desimal** (`"150000"`, `"37.5"`); `limit/offset` juga string. `expected_version` boleh angka.
- Perintah tulis wajib `operation_id` (UUID, dibuat **sekali per niat pengguna**, dipakai ulang saat kirim ulang). Status operasi yang tidak pasti: `get_operation_v1({command: '<nama RPC>', operation_id})` — `command` = nama RPC persis.
- Field yang tidak dikenal ditolak `INVALID_INPUT` (termasuk `cash_session_id`/`session_id` pada perintah mutasi kas: server selalu memakai sesi OPEN cashbox yang dikunci).
- Error: `KODE: kalimat awam`. Tampilkan kalimatnya; logika UI memakai kode. Pengecualian lama: `IDEMPOTENCY_CONFLICT` (tanpa titik dua, dari helper lama).
- Cashbox: `SHOP_DRAWER` (laci toko), `FATHER_WALLET` (dompet ayah).

| Kode | Arti / tindakan UI |
|---|---|
| `FORBIDDEN`, `ACCOUNT_INACTIVE` | Peran/akun tidak boleh |
| `INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_DATE` | Perbaiki isian |
| `NOT_FOUND` | Data tidak ada / nonaktif |
| `VERSION_CONFLICT` | Muat ulang data lalu ulangi |
| `CASH_SESSION_CLOSED` | Kas belum dibuka / sudah ditutup — buka kas |
| `CASH_SESSION_ALREADY_OPEN` | Kas masih terbuka (pesan memuat "Kas masih terbuka") |
| `NOTE_REQUIRED` | Ada selisih; wajib isi keterangan |
| `INSUFFICIENT_CASH` | Saldo kas sistem kurang (pesan menyebut saldo & kebutuhan) |
| `INSUFFICIENT_CREDIT` | Saldo kredit distributor kurang |
| `INSUFFICIENT_STOCK` | Qty melebihi stok posisi |
| `PAYMENT_NOT_CONFIRMED` | TRANSFER/QRIS wajib `confirmed: true` dari **centang manual pengguna** (jangan otomatis — T02) |
| `PAYMENT_MISMATCH` | Jumlah bayar ≠ total modal barang |
| `LABEL_TAKEN` | Label roll sudah dipakai (label unik global) |
| `ALREADY_CORRECTED` | Pembayaran sudah dikoreksi; koreksi pembayaran penggantinya |
| `REFUND_LIMIT_EXCEEDED` | Pembayaran sudah dikembalikan penuh |
| `ALREADY_SETTLED` | Retur distributor sudah diselesaikan |
| `DUPLICATE_NAME` | Nama distributor sudah ada |
| `CASH_HISTORY_IMMUTABLE` | (DB) mutasi kas tidak boleh diubah |

## Izin (D1)

| RPC | OWNER | STAFF | MAINTAINER |
|---|---|---|---|
| open/close_cash_session_v1 | semua kas | hanya SHOP_DRAWER | – |
| get_cash_session_v1 | semua | hanya SHOP_DRAWER | baca |
| list_cash_sessions_v1 | ✓ | – | baca |
| review_cash_session_v1, record_cash_adjustment_v1, transfer_cash_v1, correct_payment_v1 | ✓ | – | – |
| post_stock_receipt_v1, post_opening_stock_v1 | ✓ | – | – |
| upsert_supplier_v1, create/settle_supplier_return_v1 | ✓ | – | – |
| list_suppliers_v1, list_supplier_returns_v1 | ✓ | – | baca |

---

## Sesi kas

### open_cash_session_v1 (berubah)
```json
{"operation_id":"…","cashbox_code":"SHOP_DRAWER","opening_amount":"200000","note":"Tambah receh dari rumah"}
```
- `opening_amount` wajib (bulat ≥ 0). Dibandingkan dengan `counted_amount` sesi CLOSED terakhir cashbox itu; jika beda, `note` wajib (`NOTE_REQUIRED`), selisih disimpan `opening_variance` dan sesi ditandai `needs_review`.
- Tampilkan `last_counted_amount` dari `get_cash_session_v1` sebagai isian awal.

Keluaran: `{ok, entity_id, cashbox_code, opening_amount, previous_counted_amount, opening_variance, needs_review, version, server_time, operation_id}`
Error: FORBIDDEN, INVALID_NUMBER, INVALID_INPUT, NOTE_REQUIRED, CASH_SESSION_ALREADY_OPEN.

### close_cash_session_v1 (berubah)
```json
{"operation_id":"…","session_id":"…","expected_version":1,"counted_amount":"149000","note":"Kurang seribu"}
```
Sesi dikunci; status dicek dan saldo sistem dihitung **setelah** kunci. `note` wajib bila `variance ≠ 0`; selisih menandai `needs_review`.
Keluaran: `{ok, entity_id, cashbox_code, expected, counted, variance, needs_review, version, server_time, operation_id}`
Error: NOT_FOUND, FORBIDDEN, CASH_SESSION_CLOSED, VERSION_CONFLICT, NOTE_REQUIRED, INVALID_NUMBER.
UI: tampilkan konfirmasi berisi saldo sistem/terhitung/selisih sebelum kirim (S10).

### get_cash_session_v1 (berubah)
Input `{}` (default SHOP_DRAWER), `{"cashbox_code":"FATHER_WALLET"}`, atau `{"session_id":"…"}`.
Tanpa sesi terbuka: `{"open":false,"cashbox_code":"SHOP_DRAWER","last_session_id":"…","last_closed_at":"…","last_counted_amount":"149000"}`.
Dengan sesi:
```json
{"id":"…","cashbox_code":"SHOP_DRAWER","cashbox_label":"Laci toko","status":"OPEN","open":true,
 "business_date":"2026-09-18","opened_at":"…","opened_by_name":"Budi Staff","opening_amount":"200000",
 "previous_session_id":"…","previous_counted_amount":"149000","opening_variance":"51000","opening_note":"…",
 "expected":"201000","total_in":"1000","total_out":"0",
 "closed_at":null,"closed_by_name":null,"counted_amount":null,"variance":null,"close_note":null,
 "needs_review":true,"review_pending":true,"reviewed_at":null,"review_note":null,"version":1,
 "movements":[{"id":"…","direction":"IN","kind":"OWNER_ADD","label":"Tambah uang kas oleh pemilik","amount":"1000",
   "reason":"…","occurred_at":"…","actor_name":"Ayah Owner","reference":"INV-…|SRV-…|RECEIPT-…|SUPPLIER_RETURN-…"}]}
```
`expected` sesi CLOSED = snapshot saat tutup. Label `kind`: CUSTOMER_PAYMENT, REFUND, PURCHASE, EXPENSE, OWNER_ADD, OWNER_WITHDRAW, TRANSFER (masuk/keluar), CORRECTION (masuk/keluar), SUPPLIER_REFUND.
Catatan: STAFF melihat total pembelian tunai dari laci (uang fisik keluar), tanpa rincian modal per barang.

### list_cash_sessions_v1 (baru)
```json
{"start_date":"2026-09-01","end_date":"2026-09-30","cashbox_code":"SHOP_DRAWER","review_pending":true,"limit":"50","offset":"0"}
```
Filter `business_date` (maks 366 hari). `cashbox_code`, `review_pending`, `limit` (≤200, default 50), `offset` opsional.
Keluaran: `{"total": 3, "items": [<objek sesi seperti get tanpa movements>]}`.

### review_cash_session_v1 (baru)
`{"operation_id":"…","session_id":"…","expected_version":2,"note":"Sudah dicek"}` — owner menandai selisih buka/tutup sudah ditinjau (boleh pada sesi CLOSED; angka sesi tidak berubah).
Keluaran `{ok, entity_id, version, …}`. Error: NOT_FOUND, VERSION_CONFLICT, INVALID_INPUT (tidak menunggu tinjauan).

### record_cash_adjustment_v1 (berubah: pakai cashbox, bukan session_id)
```json
{"operation_id":"…","cashbox_code":"SHOP_DRAWER","direction":"OUT","kind":"EXPENSE","amount":"30000","reason":"Bayar listrik"}
```
`direction` IN → `kind` OWNER_ADD (default); OUT → OWNER_WITHDRAW (default) atau EXPENSE. `reason` wajib.
Keluaran: `{ok, entity_id (id mutasi), session_id, cashbox_code, direction, kind, amount, expected, …}`.
Error: CASH_SESSION_CLOSED, INSUFFICIENT_CASH, INVALID_INPUT, INVALID_NUMBER.

### transfer_cash_v1 (berubah: pakai cashbox)
```json
{"operation_id":"…","source_cashbox":"SHOP_DRAWER","target_cashbox":"FATHER_WALLET","amount":"70000","reason":"Dibawa belanja"}
```
Kedua sesi harus OPEN (dikunci urut id). Keluaran: `{ok, entity_id, transfer_group_id, source_session_id, target_session_id, amount, …}`.
Error: CASH_SESSION_CLOSED, INSUFFICIENT_CASH, INVALID_INPUT.

## Koreksi pembayaran — correct_payment_v1 (berubah)
```json
{"operation_id":"…","original_payment_id":"…","method":"CASH","cashbox":"FATHER_WALLET","reason":"Dibayar ke ayah"}
{"operation_id":"…","original_payment_id":"…","method":"TRANSFER","confirmed":true,"reference":"BCA 123","reason":"Ternyata transfer"}
```
- Hanya penerimaan pelanggan IN (`SALE_RECEIPT`, `SERVICE_RECEIPT`, atau `PAYMENT_REPLACEMENT` hasil koreksi sebelumnya). Satu koreksi per pembayaran (`ALREADY_CORRECTED`).
- `cashbox` wajib untuk CASH, dilarang untuk non-tunai. Pasangan (metode, pemegang) harus berbeda dari yang lama — CASH→CASH beda cashbox diperbolehkan.
- **Efek kas di sesi OPEN saat ini** (bukan sesi asal): pembalikan tunai hanya bila penerimaan asal tercatat masuk kas; saldo harus cukup (`INSUFFICIENT_CASH`). Pengganti tunai butuh sesi terbuka (`CASH_SESSION_CLOSED`).
- **Keputusan refund sebagian:** yang dikoreksi = sisa `amount − refund teralokasi`; bagian yang sudah direfund tidak diubah; refund berikutnya mengacu pembayaran pengganti. Refund penuh → `REFUND_LIMIT_EXCEEDED`.

Keluaran: `{ok, entity_id (=replacement), original_payment_id, reversal_payment_id, replacement_payment_id, amount, already_refunded, old_method, old_cashbox, new_method, new_cashbox, …}`.

## Barang masuk & stok awal

### post_stock_receipt_v1 (berubah)
```json
{"operation_id":"…","supplier_id":"…","source_note":"Nota 77","source_date":"2026-09-17","reason":"Barang masuk",
 "items":[
   {"product_unit_id":"<pcs>","qty":"10","acquisition_cost":"120000","note":"…"},
   {"product_unit_id":"<roll 100m>","qty":"3","acquisition_cost":"900000",
    "rolls":{"count":"3","capacity":"100","label_prefix":"NYA-A"}},
   {"product_unit_id":"<meter>","qty":"137.5","acquisition_cost":"400000",
    "rolls":{"count":"1","capacity":"100"},
    "positions":[{"label":"SISA-1","qty_base":"37.5","segment_capacity":"100","sealed":false}]}
 ],
 "payment":{"method":"CASH","cashbox":"SHOP_DRAWER","amount":"1420000","reference":"…"}}
```
- Field top-level: `operation_id, supplier_id?, source_note?, source_date?, reason?, items, payment`. Baris: `product_unit_id, qty, acquisition_cost, free_reason?, note?, rolls?, positions?`.
- `acquisition_cost` = **total modal baris**, Rupiah bulat, wajib. `"0"` hanya dengan `free_reason`.
- `payment` wajib bila total > 0; `amount` = Σ `acquisition_cost` (`PAYMENT_MISMATCH`).
  - `CASH`: `cashbox` wajib; sesi dikunci; saldo cukup; tercatat mutasi `PURCHASE` + `purchase_payments`.
  - `TRANSFER`/`QRIS`: `confirmed: true` wajib; tanpa `cashbox`.
  - `SUPPLIER_CREDIT`: `supplier_id` wajib; saldo kredit distributor cukup.
- `supplier_id` opsional; bila diisi harus distributor aktif (`NOT_FOUND`).
- **Roll (`track_segments`, BR-03/T08):** wajib `rolls` dan/atau `positions`; Σ panjang = qty dasar (qty × faktor).
  - `rolls`: N posisi bersegel @`capacity`, label `<label_prefix>-01..N`. Tanpa `label_prefix` → `<SKU>-<YYMMDD>-<noUrutDok>L<baris>-01`.
  - `positions`: label wajib, `qty_base ≤ segment_capacity`, `sealed` (default false) hanya bila `qty_base = segment_capacity`.
  - Label unik global (`LABEL_TAKEN`). Semua posisi satu baris berada di **satu lot**; modal lot dicatat pada gerakan pertama (ledger `cost_delta` = saldo modal lot).
  - Barang bukan roll: jangan kirim `rolls/positions`.

Keluaran:
```json
{"ok":true,"entity_id":"…","document_number":"RECEIPT-20260918-000001","total_cost":"1420000",
 "payment_method":"CASH","cashbox":"SHOP_DRAWER","cash_session_id":"…",
 "lines":[{"line_no":2,"item_id":"…","lot_id":"…","product_id":"…","qty_base":"300.000",
   "positions":[{"position_id":"…","label":"NYA-A-01","qty_base":"100.000","segment_capacity":"100.000","sealed":true}]}],
 "server_time":"…","operation_id":"…"}
```
Pakai `lines[].positions[].label` untuk mencetak/menulis label roll.
Error: FORBIDDEN, INVALID_INPUT, INVALID_NUMBER, INVALID_DATE, NOT_FOUND, PAYMENT_MISMATCH, PAYMENT_NOT_CONFIRMED, CASH_SESSION_CLOSED, INSUFFICIENT_CASH, INSUFFICIENT_CREDIT, LABEL_TAKEN.

### post_opening_stock_v1 (berubah)
Sama seperti di atas tanpa `supplier_id` dan **tanpa `payment`** (dikirim → `INVALID_INPUT`). Tidak membuat pembayaran/mutasi kas.
Perbaikan: idempotensi barang masuk kini memakai command `post_stock_receipt_v1` (sebelumnya `post_receipt_stock_v1`).

## Distributor

### upsert_supplier_v1 (baru)
Buat: `{"operation_id":"…","name":"CV Sumber Listrik","contact":"0811…","address":"…"}`
Ubah: `{"operation_id":"…","supplier_id":"…","expected_version":1,"name":"…","contact":"…","address":"…","active":false}` (field teks yang tidak dikirim menjadi kosong — kirim nilai lengkap).
Keluaran `{ok, entity_id, name, active, version, …}`. Error: DUPLICATE_NAME (tanpa beda huruf/spasi), NOT_FOUND, VERSION_CONFLICT, INVALID_INPUT.

### list_suppliers_v1 (baru)
`{"query":"sumber","include_inactive":false}` →
`{"items":[{"id","name","contact","address","active","version","credit_balance":"12000","pending_return_count":1,"pending_claim_value":"105000.000000"}]}`

### create_supplier_return_v1 (baru)
```json
{"operation_id":"…","supplier_id":"…","reason":"Lampu mati",
 "items":[{"position_id":"…","qty_base":"3","expected_version":1},{"position_id":"…","qty_base":"25","expected_version":2}]}
```
Posisi dari lokasi SHOP/FIELD_FATHER, kondisi SALEABLE/DAMAGED; satu posisi sekali per dokumen. Modal keluar per BR-05 (`cost_for_exit_lot`), stok keluar (mutasi `SUPPLIER_RETURN_OUT`, segel roll terbuka), dokumen `PENDING` dengan `claim_value` = Σ modal (6 desimal).
Keluaran `{ok, entity_id, document_number:"SUPPLIER_RETURN-…", status:"PENDING", claim_value:"105000.000000", version:1, …}`.
Error: VERSION_CONFLICT, INSUFFICIENT_STOCK, NOT_FOUND, INVALID_INPUT, INVALID_NUMBER.

### settle_supplier_return_v1 (baru) — satu penyelesaian penuh per dokumen
Umum: `{"operation_id","supplier_return_id","expected_version","outcome","note?"}`; field lain sesuai hasil (field hasil lain ditolak).
- `REFUND`: `{"amount":"100000","method":"CASH","cashbox":"SHOP_DRAWER"}` atau `{"amount":"100000","method":"TRANSFER","confirmed":true,"reference":"…"}`. CASH → sesi dikunci, mutasi IN `SUPPLIER_REFUND`.
- `CREDIT`: `{"amount":"12000","reference":"…"}` → saldo kredit distributor bertambah; dipakai sebagai `payment.method = "SUPPLIER_CREDIT"` pada pembelian.
- `REPLACEMENT`: `{"items":[{"product_unit_id","qty","rolls?","positions?","note?","acquisition_cost?"}]}` → dokumen `SUPPLIER_REPLACEMENT`, lot baru (mutasi `SUPPLIER_REPLACEMENT_IN`). Modal total = nilai klaim: isi `acquisition_cost` (6 desimal) di **semua** baris dengan jumlah = klaim, atau kosongkan semua → dibagi proporsional qty dasar (sisa 0,000001 ke pecahan terbesar lalu nomor baris).
- `REJECTED`: `note` wajib; klaim menjadi kerugian.

`settlement_difference` = uang/kredit diterima − klaim (REFUND/CREDIT), 0 (REPLACEMENT), −klaim (REJECTED). Laba/rugi retur distributor terpisah dari laba kotor penjualan.
Keluaran: `{ok, entity_id, status:"SETTLED", outcome, claim_value, settled_amount, settlement_difference, cash_session_id, credit_entry_id, replacement_document_id, replacement_document_number, lines, version, …}`.
Error: ALREADY_SETTLED, VERSION_CONFLICT, PAYMENT_NOT_CONFIRMED, CASH_SESSION_CLOSED, INVALID_INPUT, INVALID_NUMBER, LABEL_TAKEN, NOT_FOUND.

### list_supplier_returns_v1 (baru)
`{"status":"PENDING","supplier_id":"…","start_date":"2026-09-01","end_date":"2026-09-30","limit":"50","offset":"0"}` (semua opsional; tanggal berdasarkan waktu dibuat) →
```json
{"items":[{"id","document_number","supplier_id","supplier_name","status","reason","claim_value","created_at",
  "outcome","settled_amount","settlement_method","settlement_cashbox","settlement_reference","settlement_difference",
  "settlement_note","settled_at","replacement_document_number","version",
  "items":[{"line_no","product_id","sku","name","qty_base","unit","cost","source_location","condition","position_label"}]}]}
```

## Jaring pengaman database

- Trigger `cash_movements_guard`: INSERT ke sesi yang tidak OPEN ditolak `CASH_SESSION_CLOSED` (mengunci baris sesi sehingga bentrok dengan penutupan); UPDATE mutasi kas ditolak.
- Trigger `cash_sessions_guard`: sesi CLOSED tidak dapat diubah selain kolom tinjauan.
- Uji konkurensi dua koneksi: `TEST_DB_NAME=elektropos_test_cash npm run test:db:cash-concurrency`.
