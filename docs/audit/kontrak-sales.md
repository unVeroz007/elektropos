# Kontrak RPC domain penjualan & katalog (perbaikan audit 2026-09)

Migrasi: `20260918001000_fix_sales_schema.sql` … `20260918001400_fix_catalog.sql`.
Uji: `supabase/tests/sales_*.sql`, `p1_at06.sql`, `p1_p2_extra.sql`.

## Aturan umum

- Semua RPC: `supabase.rpc('<nama>', { p_input: {...} })` (kecuali `list_categories_v1()` tanpa argumen).
- Angka uang/qty/persen **wajib string desimal** kanonik (`"2.5"`, `"18750"`); angka JSON, koma, titik ribuan,
  `NaN`, `Infinity`, negatif → `INVALID_NUMBER`.
- Field tidak dikenal → `INVALID_INPUT` (termasuk `cash_session_id` dari klien).
- Error: `message` = `'KODE: kalimat awam'`. Frontend memetakan dari awalan sebelum `:`; kalimat boleh ditampilkan.
  `PRICE_CHANGED` membawa `details` (JSON: `product_id`, `current_unit_id`, `label`, `sell_price`, `version`).
- Akun nonaktif → `ACCOUNT_INACTIVE`; peran salah → `FORBIDDEN` (SQLSTATE 42501).
- Perintah tulis wajib `operation_id` (UUID). Ulang payload identik = hasil identik. Payload beda dengan
  `operation_id` sama → `IDEMPOTENCY_CONFLICT`. Setelah timeout, cek dengan
  `get_operation_v1({ command: '<nama RPC>', operation_id })` — `command` **sama persis** dengan nama RPC.

| RPC | Peran |
|---|---|
| finalize_sale_v1, preview_sale_v1 | OWNER, STAFF |
| return_sale_v1 | OWNER |
| get_invoice_v1, list_invoices_v1, list_sellable_positions_v1 | OWNER, STAFF, MAINTAINER |
| search_products_v1, get_product_v1, find_by_barcode_v1, list_product_barcodes_v1, list_categories_v1 | OWNER, STAFF, MAINTAINER |
| upsert_product_v1, archive_product_v1, add/remove_product_barcode_v1, preview/commit_catalog_import_v1, upsert_category_v1 | OWNER |

---

## finalize_sale_v1 (berubah)

```json
{
  "operation_id": "uuid",
  "client_reference_id": "uuid (opsional, id keranjang; mencegah nota ganda)",
  "customer_id": "uuid (opsional)",
  "items": [
    { "product_unit_id": "uuid", "qty": "2", "expected_unit_version": 1 },
    { "product_unit_id": "uuid-satuan-m", "qty": "2.5", "expected_unit_version": 1,
      "position_id": "uuid-posisi-roll", "expected_position_version": 3,
      "discount_mode": "percent", "discount_value": "10" }
  ],
  "discount_mode": "amount", "discount_value": "1000",
  "reason": "wajib bila total 0",
  "payment": { "method": "CASH", "tendered": "50000" }
}
```

- `items` 1–100. Field baris: `product_unit_id`, `qty`, `expected_unit_version`?, `position_id`?,
  `expected_position_version`?, `discount_mode`?, `discount_value`?.
- **Diskon** (baris & nota) hanya OWNER. STAFF mengirim `discount_mode`/`discount_value` apa pun (termasuk `"0"`)
  → `FORBIDDEN`. Jangan kirim field diskon untuk STAFF (hapus key, bukan string kosong berisi nilai).
  `percent`: `"0"`–`"100"` maks 4 desimal. `amount`: Rupiah bulat. Diskon > nilai → `INVALID_INPUT`.
- **Roll (`track_segments=true`)**: setiap baris WAJIB `position_id` dari `list_sellable_positions_v1`
  (tanpa → `POSITION_REQUIRED`). Satu baris = satu potongan fisik. Dua potongan = dua baris.
  - Satuan dengan `factor_base > 1` (mis. "roll 100m") = **roll utuh**: `qty` harus `"1"`, posisi harus bersegel
    dengan kapasitas = faktor, dan tidak dipakai baris lain.
  - Satuan meter: jumlah semua baris pada posisi itu ≤ sisa posisi, selain itu `SEGMENT_TOO_SHORT`.
    Memotong roll bersegel membuka segelnya.
  - Barang bulk yang mengirim `position_id` → `INVALID_INPUT`.
- **Stok bulk**: server memakai FIFO lot; kebutuhan dijumlahkan per produk (semua satuan) → `INSUFFICIENT_STOCK`.
- **Total** (BR-04) dihitung server. Pakai `preview_sale_v1` untuk menampilkan angka sebelum bayar.
- **Pembayaran** (total > 0 wajib `payment`):
  - `CASH`: `tendered` wajib ≥ total (`INSUFFICIENT_PAYMENT`); laci toko harus terbuka (`CASH_SESSION_CLOSED`).
    Kembalian dihitung server.
  - `TRANSFER`/`QRIS`: `confirmed: true` (boolean JSON) wajib, kalau tidak `PAYMENT_NOT_CONFIRMED`.
    `reference` opsional ≤100. `tendered` diabaikan.
  - Metode lain → `INVALID_INPUT`.
- **Total 0**: hanya OWNER dan wajib `reason` (`APPROVAL_REQUIRED`). Tidak ada receipt; kirim `payment: null`
  (bila tetap mengirim `CASH`, laci tetap harus terbuka).

Output:

```json
{
  "ok": true, "entity_id": "uuid-nota", "document_number": "SALE-INV-20260918-000001",
  "operation_id": "uuid", "server_time": "…", "schema_version": 2,
  "subtotal": "25000", "discount": "1000", "total": "24000",
  "payment_id": "uuid|null", "payment_method": "CASH|TRANSFER|QRIS|null",
  "tendered": "50000|null", "change": "26000",
  "items": [{ "invoice_item_id": "uuid", "line_no": 1, "product_unit_id": "uuid", "description": "Lampu (pcs)",
    "unit_label": "pcs", "qty_sell": "2.000", "qty_base": "2.000", "unit_price": "15000.000000",
    "gross_exact": "30000.000000000", "line_discount": "0", "base_net": "30000",
    "invoice_discount_alloc": "1000", "net_total": "29000" }]
}
```

Kode error: `ACCOUNT_INACTIVE`, `FORBIDDEN`, `INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_QUANTITY`, `NOT_FOUND`
(satuan/produk arsip/posisi/pelanggan), `PRICE_CHANGED`, `POSITION_REQUIRED`, `SEGMENT_TOO_SHORT`,
`SEGMENT_NOT_SEALED`, `INSUFFICIENT_STOCK`, `VERSION_CONFLICT` (posisi), `APPROVAL_REQUIRED`,
`INSUFFICIENT_PAYMENT`, `PAYMENT_NOT_CONFIRMED`, `CASH_SESSION_CLOSED`, `ALREADY_FINALIZED`
(`client_reference_id`/`payment_intent_id` sudah dipakai), `IDEMPOTENCY_CONFLICT`.

## preview_sale_v1 (baru)

Input sama dengan `finalize_sale_v1` (`operation_id` boleh ada, diabaikan). Tidak menulis/mengunci apa pun.
Validasi harga, versi, qty, diskon & peran sama (error sama). Stok **tidak** divalidasi, hanya dilaporkan.

```json
{
  "ok": true, "server_time": "…", "schema_version": 2,
  "subtotal": "10201", "discount_mode": "percent", "discount_value": "12.5", "discount": "1275", "total": "8926",
  "requires_owner_reason": false,
  "tendered": "10000|null", "change": "1074|null",
  "items": [{ "line_no": 1, "product_id": "uuid", "product_unit_id": "uuid", "unit_version": 1,
    "description": "…", "unit_label": "pcs", "track_segments": false, "position_id": null,
    "qty_sell": "1", "qty_base": "1", "unit_price": "10001.000000", "discount_mode": null, "discount_value": null,
    "gross_exact": "10001.000000", "line_discount": "0", "base_net": "10001",
    "invoice_discount_alloc": "1250", "net_total": "8751", "available_base": "50.000" }]
}
```

## list_sellable_positions_v1 (baru)

Input `{ "product_id": "uuid" }`. Posisi SHOP + SALEABLE + sisa > 0, urut: potongan terbuka dulu, lalu bersegel,
lalu tanggal terima.

```json
{ "product_id": "uuid", "base_unit": "m", "track_segments": true,
  "positions": [{ "position_id": "uuid", "label": "R-001", "qty_base": "97.500", "segment_capacity": "100.000",
    "sealed": false, "version": 2, "received_at": "…" }] }
```

Kirim `position_id` + `version` sebagai `expected_position_version` di finalize.

## return_sale_v1 (berubah)

```json
{
  "operation_id": "uuid", "invoice_id": "uuid", "reason": "wajib, ≤500",
  "refund_method": "CASH|TRANSFER|QRIS (wajib bila ada refund)", "refund_reference": "opsional ≤100",
  "items": [
    { "invoice_item_id": "uuid", "qty_base": "1", "disposition": "SALEABLE|DAMAGED|NONE",
      "allocations": [{ "cost_allocation_id": "uuid", "qty_base": "1" }],
      "label": "opsional, hanya roll yang kembali ke stok" }
  ]
}
```

- `qty_base` dalam satuan dasar, kelipatan langkah stok produk (0,5 pcs → `INVALID_QUANTITY`). Kumulatif ≤ qty terjual
  (`REFUND_LIMIT_EXCEEDED`). Satu `invoice_item_id` sekali per permintaan.
- Refund baris dihitung server: `H(x)=round_half_up(neto×x/qty,0)` kumulatif. Klien tidak mengirim nilai uang.
- `NONE` (barang tidak kembali): refund tetap, stok & modal tidak berubah; `allocations` tidak boleh dikirim.
- `SALEABLE`/`DAMAGED`: modal dibalik per alokasi asal (kumulatif, 6 desimal); stok kembali sebagai **posisi baru**
  per alokasi (kondisi sesuai disposition, lokasi SHOP). Tanpa `allocations` → urutan alokasi asal (lot tertua dulu);
  dengan `allocations` (owner memilih fisik, id dari `get_invoice_v1.items[].cost_allocations`) jumlahnya harus = `qty_base`.
- Roll: posisi baru berlabel `label` atau otomatis `<nomor CRD>-<baris>[-k]`, tidak bersegel.
- Nota total 0 / refund 0: tanpa pembayaran; `refund_method` boleh tidak dikirim.
- `CASH`: laci toko harus terbuka dan saldonya cukup (`INSUFFICIENT_CASH`); dicatat mutasi `REFUND`.
- Refund dialokasikan ke receipt asal/pengganti yang masih bersaldo; melebihi → `REFUND_LIMIT_EXCEEDED`.

Output:

```json
{ "ok": true, "entity_id": "uuid-credit-note", "document_number": "CRD-20260918-000001", "invoice_id": "uuid",
  "refund_total": "33", "refund_payment_id": "uuid|null", "refund_method": "CASH|null",
  "items": [{ "invoice_item_id": "uuid", "qty_base": "1", "amount": "33", "disposition": "SALEABLE",
    "cost_reversal": "3333.333333",
    "positions": [{ "position_id": "uuid", "label": null, "qty_base": "1", "condition": "SALEABLE" }] }],
  "operation_id": "uuid", "server_time": "…", "schema_version": 2 }
```

Kode error: `ACCOUNT_INACTIVE`, `FORBIDDEN`, `INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_QUANTITY`, `NOT_FOUND`,
`REFUND_LIMIT_EXCEEDED`, `CASH_SESSION_CLOSED`, `INSUFFICIENT_CASH`, `IDEMPOTENCY_CONFLICT`.

## get_invoice_v1 (berubah)

Input: tepat satu dari `{ "invoice_id": "uuid" }` atau `{ "number": "SALE-INV-…" }` (tanpa beda huruf).

```json
{
  "id": "uuid", "number": "…", "kind": "SALE", "service_ticket_id": null, "posted_at": "…",
  "cashier_name": "Budi Staff", "customer": { "id": "uuid", "name": "…" } ,
  "subtotal_net_lines": "30000", "discount_total": "0", "total": "30000", "free_reason": null,
  "money": { "credit_total": "15000", "invoice_net": "15000", "received": "30000", "refunded": "15000",
    "corrections": "0", "net_received": "15000", "outstanding": "0", "refund_due": "0", "payment_status": "PAID" },
  "items": [{ "id": "uuid", "line_no": 1, "kind": "PRODUCT", "product_id": "uuid", "product_unit_id": "uuid",
    "description": "Lampu LED 10 Watt (pcs)", "unit_label": "pcs", "qty_sell": "2.000", "factor": "1.000",
    "qty_base": "2.000", "unit_price": "15000.000000", "discount_mode": null, "discount_value": null,
    "gross": "30000.000000000", "line_discount": "0", "base_net": "30000", "invoice_discount_alloc": "0",
    "net_total": "30000", "returned_qty": "1.000", "returnable_qty": "1.000",
    "cost_allocations": "[HANYA OWNER/MAINTAINER] [{ id, lot_id, lot_posted_at, origin_position_id, origin_label, qty_base, cost_amount, reversed_qty, reversed_cost }]" }],
  "payments": [{ "id": "uuid", "direction": "IN", "purpose": "SALE_RECEIPT", "method": "CASH", "amount": "30000",
    "tendered": "50000", "change": "20000", "reference": null, "original_payment_id": null,
    "actor_name": "Budi Staff", "occurred_at": "…" }],
  "credits": [{ "id": "uuid", "number": "CRD-…", "kind": "RETURN", "reason": "Rusak", "total": "15000",
    "posted_at": "…", "actor_name": "Ayah Owner",
    "items": [{ "invoice_item_id": "uuid", "qty_base": "1.000", "amount": "15000", "disposition": "DAMAGED",
      "cost_reversal": "[HANYA OWNER/MAINTAINER]" }],
    "refunds": [{ "payment_id": "uuid", "method": "CASH", "amount": "15000", "original_payment_id": "uuid", "occurred_at": "…" }] }],
  "schema_version": 2
}
```

`payments` kini juga untuk STAFF (struk: metode, dibayar, kembalian). STAFF tidak pernah menerima field modal.
`payment_status`: `UNPAID | PARTIAL | PAID | REFUND_DUE` (memperhitungkan credit note, refund, koreksi pembayaran).
Error: `INVALID_INPUT`, `NOT_FOUND`, `ACCOUNT_INACTIVE`.

## list_invoices_v1 (berubah)

```json
{ "start_date": "2026-03-10", "end_date": "2026-03-10", "query": "0310", "kind": "SALE", "limit": 25, "offset": 0 }
```

Semua opsional; bila salah satu tanggal dikirim keduanya wajib (`INVALID_DATE`, maks 366 hari). Rentang = hari
toko WIB `[awal start_date, awal hari setelah end_date)`. `query` mencari potongan nomor nota (tanpa beda huruf).
`limit` 1–100. Output tetap **array** (urut terbaru):

```json
[{ "id": "uuid", "number": "…", "kind": "SALE", "posted_at": "…", "subtotal_net_lines": "…",
   "discount_total": "…", "total": "…", "cashier_name": "Budi Staff", "customer_name": null,
   "payment_methods": ["CASH"], "has_return": false,
   "credit_total": "0", "invoice_net": "…", "received": "…", "refunded": "0", "corrections": "0",
   "net_received": "…", "outstanding": "0", "refund_due": "0", "payment_status": "PAID" }]
```

---

## upsert_product_v1 (berubah)

```json
{ "operation_id": "uuid", "product_id": "uuid (hanya ubah)", "expected_version": 3,
  "sku": "LMP-001", "name": "…", "specification": "", "base_unit": "pcs", "quantity_step": "1",
  "track_segments": false, "unit_label": "pcs", "factor_base": "1", "sale_step": "1", "sell_price": "15000",
  "barcode": "opsional", "shelf": "opsional ≤30", "category_id": "uuid opsional", "reason": "opsional" }
```

- Ubah produk: `expected_version` wajib (`VERSION_CONFLICT`). `base_unit`, `quantity_step`, `track_segments` tidak
  boleh berubah (`INVALID_INPUT`).
- Satuan default **hanya** diganti versi baru bila `unit_label`/`factor_base`/`sale_step`/`sell_price` berubah
  (satuan lama nonaktif, riwayat harga dicatat, barcode satuan lama pindah ke satuan baru). Ubah nama/rak/spesifikasi
  tidak menyentuh satuan → keranjang dengan versi lama tetap sah.
- `barcode` yang sudah milik produk ini tidak diduplikasi; milik produk lain → `DUPLICATE_BARCODE`.

Output: `{ ok, entity_id, version, unit_id, unit_version, unit_changed, operation_id, server_time, schema_version: 2 }`.
Error: `FORBIDDEN`, `INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_QUANTITY`, `NOT_FOUND`, `VERSION_CONFLICT`,
`DUPLICATE_SKU`, `DUPLICATE_BARCODE` (SQLSTATE 23505 untuk duplikat).

## archive_product_v1 (berubah)

`{ operation_id, product_id, expected_version, reason? }` → `{ ok, entity_id, version, operation_id, server_time }`.
Error: `NOT_FOUND`, `VERSION_CONFLICT`, `INVALID_INPUT` (sudah diarsip), `FORBIDDEN`.

## search_products_v1 (berubah)

`{ query?: ≤120, limit?: 1–100, category_id?: uuid }`. Cocok: bagian nama, awalan SKU, barcode **persis**
(nol depan dipertahankan), alias. Hasil persis (SKU/barcode) diurutkan pertama. Item menambah `category_id`, `version`.
Field unknown (mis. `cursor`) → `INVALID_INPUT`.

## get_product_v1 (berubah)

`{ product_id }`. Tambahan: `quantity_step`, `track_segments`, `shelf`, `category_id`, `units[].is_default`,
`barcodes` kini `[{ code, unit_id }]` (sebelumnya array string). `lots` hanya OWNER/MAINTAINER.
Error: `INVALID_INPUT`, `NOT_FOUND`.

## find_by_barcode_v1 / list_product_barcodes_v1

Bentuk output tidak berubah; kini wajib akun aktif. Input ketat (`{code}` / `{product_id}`).

## add_product_barcode_v1 / remove_product_barcode_v1

- add: `{ operation_id, product_id, product_unit_id?, code }` → `{ ok, entity_id, code, already, operation_id }`.
  Satuan harus milik produk & aktif. Error: `NOT_FOUND`, `INVALID_INPUT`, `DUPLICATE_BARCODE`, `FORBIDDEN`.
- remove: `{ operation_id, code }` → `{ ok, entity_id, code, operation_id }`. Error: `NOT_FOUND`, `FORBIDDEN`.

## preview_catalog_import_v1 / commit_catalog_import_v1

Baris (semua nilai teks): `sku, name, specification?, base_unit, quantity_step, track_segments? ("true"/"false"),
unit_label, factor_base, sale_step, sell_price, barcode?, shelf?`. 1–200 baris.

- preview `{ rows, import_hash? }` → `{ ok, total, valid, errors: [{ line, code, message }] }`. Kode baris:
  `INVALID_ROW, UNKNOWN_FIELD, INVALID_SKU, DUPLICATE_SKU (dalam batch tanpa beda huruf / sudah ada), INVALID_BARCODE,
  DUPLICATE_BARCODE, INVALID_NAME, INVALID_SPECIFICATION, INVALID_BASE_UNIT, INVALID_UNIT_LABEL, INVALID_SHELF,
  INVALID_TRACK_SEGMENTS, INVALID_QUANTITY_STEP, INVALID_FACTOR, INVALID_SALE_STEP, INVALID_PRICE, INVALID_CONVERSION`.
- commit `{ operation_id, rows, import_hash? }` memvalidasi ulang seluruh batch; ada masalah → `INVALID_INPUT`
  (tanpa efek; `details` berisi JSON daftar error). Sukses → `{ ok, count, ids, operation_id }`.

## upsert_category_v1 / list_categories_v1

- upsert `{ operation_id, category_id?, name, active? }` → `{ ok, entity_id, operation_id }`. Nama baru yang sama
  (tanpa beda huruf) dengan kategori ada → memakai/aktifkan kategori itu. Rename ke nama yang dipakai →
  `DUPLICATE_NAME`. `category_id` tidak ada → `NOT_FOUND`.
- list: tanpa argumen → `[{ id, name }]` aktif.

## Perubahan skema yang terlihat

- `invoices.free_reason`, `invoice_items.product_unit_id`, `unit_label_snapshot`, `item_discount_exact`.
- CHECK `cost_allocations.reversed_qty <= qty_base`, `reversed_cost <= cost_amount` (NOT VALID bila data lama rusak).
