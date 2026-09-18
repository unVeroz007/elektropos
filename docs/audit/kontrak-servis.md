# Kontrak RPC Servis & Pelanggan (perbaikan audit 2026-09)

Migrasi: `supabase/migrations/20260918003100..003500_service_*.sql`. Uji: `supabase/tests/service_*.sql`.
Temuan ditutup: K07, K08, K09, K12, T06, S05 (+ FR-SRV-01, FR-CUS-01, BR-09..BR-11).

## Aturan umum

- Panggil `supabase.rpc('<nama>', { p_input: {...} })`. Semua angka uang/qty dikirim **string desimal** (`"150000"`, `"2.5"`); angka JSON ditolak `INVALID_NUMBER`.
- **Kolom tak dikenal ditolak** (`INVALID_INPUT: Kolom "x" tidak dikenal`). Jangan kirim `cash_session_id`, `change`, `location` handover, dll.
- Perintah tulis wajib `operation_id` (UUID). Retry dengan payload sama → hasil sama (tanpa efek ganda); payload beda → `IDEMPOTENCY_CONFLICT`.
  Status operasi tak pasti: `get_operation_v1({command: '<nama RPC persis>', operation_id})`.
- `expected_version` = `version` tiket terbaru (dari get/list atau keluaran perintah sebelumnya). Setiap perintah tulis tiket mengembalikan `version` baru.
  Salah → `VERSION_CONFLICT` (muat ulang). Pembayaran/refund: `expected_version` opsional, tidak menaikkan versi.
- Error: `raise 'KODE: kalimat awam'`. Frontend memetakan kode = teks sebelum `:` pertama; tampilkan kalimatnya.
- Keluaran sukses tulis: `ok, operation_id, server_time, entity_id, version`, + field khusus.

### Peran

| RPC | OWNER | STAFF | MAINTAINER |
|---|---|---|---|
| create_service_ticket_v1, handover_service_v1, record_service_payment_v1 | ya | ya (tunai hanya SHOP_DRAWER) | tidak |
| update_service_details_v1 | ya (sebelum tagihan final) | hanya saat status NEW | tidak |
| transfer_service_custody_v1 | ya (SHOP/FATHER) | hanya CUSTOMER→SHOP saat NEW | tidak |
| transition, correct_status, schedule, record/approve_estimate, use/reverse part, finalize, credit, refund, close_onsite | ya | tidak | tidak |
| create_customer_v1, upsert_customer_v1 | ya | ya | tidak |
| get_service_ticket_v1, list_service_tickets_v1, get_service_payment_status_v1, search_customers_v1, find_similar_customers_v1, list_customer_history_v1 | ya | ya (tanpa modal) | ya (tanpa kontak pelanggan) |

Akun nonaktif: `ACCOUNT_INACTIVE`. Peran salah: `FORBIDDEN`.

### Kode error domain servis

`INVALID_INPUT`, `INVALID_NUMBER`, `INVALID_DATE`, `INVALID_PHONE`, `INVALID_QUANTITY`, `NOT_FOUND`, `VERSION_CONFLICT`, `IDEMPOTENCY_CONFLICT`,
`CUSTOMER_REQUIRED`, `CONTACT_REQUIRED`, `ADDRESS_REQUIRED`, `SCHEDULE_REQUIRED`, `TICKET_CLOSED`, `ALREADY_FINALIZED`,
`INVALID_TRANSITION`, `APPROVAL_REQUIRED`, `TEST_RESULT_REQUIRED`, `REASON_REQUIRED`, `INVALID_CUSTODY`,
`INSUFFICIENT_STOCK`, `SEGMENT_TOO_SHORT`, `PART_LINE_REQUIRED`, `INVOICE_REQUIRED`, `PAYMENT_OUTSTANDING`, `REFUND_DUE`,
`PAYMENT_AMOUNT_MISMATCH`, `ALREADY_SETTLED`, `TENDERED_REQUIRED`, `INSUFFICIENT_TENDERED`, `CONFIRMATION_REQUIRED`,
`CASH_SESSION_CLOSED`, `INSUFFICIENT_CASH`, `REFUND_LIMIT_EXCEEDED`, `FORBIDDEN`, `ACCOUNT_INACTIVE`.

### Status & label

| Kode | Label UI |
|---|---|
| NEW | Baru diterima |
| INSPECTING | Diperiksa |
| AWAITING_APPROVAL | Menunggu persetujuan biaya |
| WAITING_PARTS | Menunggu part |
| WORKING | Dikerjakan |
| READY | Siap Diambil (titip) / Selesai Dikerjakan (onsite) |
| UNREPAIRABLE | Tidak bisa diperbaiki |
| CANCELLED | Dibatalkan |

Transisi (WF-05): NEW→INSPECTING,CANCELLED · INSPECTING→AWAITING_APPROVAL,UNREPAIRABLE,CANCELLED · AWAITING_APPROVAL→WORKING,WAITING_PARTS,CANCELLED ·
WAITING_PARTS→WORKING,AWAITING_APPROVAL,UNREPAIRABLE,CANCELLED · WORKING→READY,WAITING_PARTS,AWAITING_APPROVAL,UNREPAIRABLE,CANCELLED.
Status akhir tidak maju/mundur (hanya `correct_service_status_v1`). `get_service_ticket_v1.allowed_transitions` memberi daftar siap pakai.

Custody: `CUSTOMER` (di pelanggan), `SHOP` (di toko), `FATHER` (dibawa ayah). Status bayar: `UNPRICED` (belum ada tagihan final),
`UNPAID`, `PARTIAL`, `PAID`, `REFUND_DUE`. Label "Belum diambil" = `not_picked_up` (status akhir + custody SHOP/FATHER + belum tutup).

---

## Tiket

### create_service_ticket_v1
```json
{ "operation_id": "uuid",
  "customer_id": "uuid (pelanggan ada) | hilang",
  "customer_name": "Joko", "customer_phone": "0812-3456-7890", "customer_alt_contact": "Tetangga", "customer_address": "Jl. ...",
  "parent_ticket_id": "uuid (keluhan kembali, opsional)",
  "service_location": "STORE | ONSITE (default STORE)",
  "equipment_type": "TV", "equipment_brand": "", "equipment_model": "", "equipment_serial": "",
  "complaint": "Layar gelap", "initial_condition": "Casing retak", "accessories": "Remote",
  "address": "ONSITE: wajib (atau dari alamat pelanggan)", "scheduled_at": "ONSITE: wajib ISO 8601" }
```
- Pelanggan: `customer_id` **atau** data baru (`customer_name` + HP/kontak lain), bukan keduanya. Jika hanya `parent_ticket_id`, pelanggan tiket asal dipakai.
- STORE: `initial_condition` wajib; alamat/jadwal ditolak. Custody `SHOP` + event CUSTOMER→SHOP. ONSITE: custody `CUSTOMER`, tanpa event.
- Keluhan kembali tidak mengubah tiket asal.
- Keluar: `{ ok, entity_id, ticket_id, number, document_number, version, customer_id, parent_ticket_id, work_status:"NEW", service_location, custody_location }`.
- Error: CUSTOMER_REQUIRED, CONTACT_REQUIRED, INVALID_PHONE, ADDRESS_REQUIRED, SCHEDULE_REQUIRED, INVALID_DATE, NOT_FOUND, INVALID_INPUT.

### transition_service_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, target_status, reason?, test_result? }`
- `WORKING`/`WAITING_PARTS` wajib revisi estimasi terbaru APPROVED (`APPROVAL_REQUIRED`).
- `READY` wajib `test_result` nyata (≥3 huruf; `"OK"` ditolak) → `TEST_RESULT_REQUIRED`. `test_result` di target lain ditolak.
- `reason` wajib untuk AWAITING_APPROVAL, WAITING_PARTS, UNREPAIRABLE, CANCELLED (`REASON_REQUIRED`).
- Ditolak bila tiket tutup (`TICKET_CLOSED`) atau tagihan final (`ALREADY_FINALIZED`); pasangan di luar tabel → `INVALID_TRANSITION`.
- Keluar: `{ ok, entity_id, from_status, to_status, version }`.

### correct_service_status_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, reason }` — hanya status akhir, sebelum tagihan final & tutup. Mengembalikan ke status sebelum status akhir menurut log; `test_result` dihapus bila dari READY.
Keluar `{ ok, from_status, to_status, version }`.

### update_service_details_v1
`{ operation_id, ticket_id, expected_version, reason?, equipment_type?, equipment_brand?, equipment_model?, equipment_serial?, complaint?, initial_condition?, accessories?, address? }`
Kolom yang dikirim di-set (string kosong mengosongkan kolom opsional; kolom wajib tidak bisa dikosongkan). `address` hanya ONSITE. STAFF hanya saat NEW. Kontak pelanggan diubah via `upsert_customer_v1`.

### update_service_schedule_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, scheduled_at, reason }` — hanya ONSITE; alasan + jadwal lama/baru tercatat di audit.

### transfer_service_custody_v1
`{ operation_id, ticket_id, expected_version, to_location: "SHOP|FATHER", condition_note?, accessories_note?, reason? }`
`CUSTOMER` ditolak (pakai serah terima). Contoh onsite dibawa pulang: CUSTOMER→FATHER→SHOP. Keluar `{ from_location, custody_location, version }`.

### record_estimate_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, description, min_amount?: "80000", max_amount: "120000" }`
Revisi dinomori server; revisi PROPOSED lama → SUPERSEDED. Status otomatis: NEW→INSPECTING→AWAITING_APPROVAL; INSPECTING/WAITING_PARTS/WORKING→AWAITING_APPROVAL (biaya baru perlu persetujuan). Status akhir tidak diubah (boleh untuk biaya penyelesaian).
Keluar `{ estimate_id, revision, estimate_version: 1, work_status, version }`.

### approve_estimate_v1 (OWNER)
`{ operation_id, estimate_id, expected_version (versi ESTIMASI), agreed_limit: "100000", method: "IN_PERSON|PHONE|WHATSAPP|OTHER", consent_note? (wajib bila OTHER) }`
Hanya revisi terbaru berstatus PROPOSED; `agreed_limit` bulat ≥0 dan ≤ `max_amount` revisi (lebih besar → catat revisi baru). Persetujuan lama → SUPERSEDED.
Keluar `{ estimate_id, revision, approved_limit, estimate_version, version (tiket) }`.

## Part

### use_service_part_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, position_id, qty: "2.5" (satuan dasar), charge_unit_price?: "7500", reason? }`
Syarat: status WORKING + persetujuan aktif; posisi SALEABLE di SHOP atau FIELD_FATHER; qty kelipatan `quantity_step` (`INVALID_QUANTITY`); roll memakai posisi eksplisit (`SEGMENT_TOO_SHORT`), bulk `INSUFFICIENT_STOCK`.
Efek: stok & modal lot berkurang, movement `SALE_OUT` (sumber `service_part_event_id`), cost_allocation. Keluar `{ part_event_id, product_id, qty, cost, position_qty_after, version }`.

### reverse_service_part_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, use_event_id, qty, target_location?: "SHOP|FIELD_FATHER" (default SHOP), target_condition?: "SALEABLE|DAMAGED" (default SALEABLE), reason }`
- Qty ≤ sisa bersih USE (`REFUND_LIMIT_EXCEEDED`). Modal dipulihkan kumulatif: `round_half_up(C × x/Q, 6)`, penuh saat seluruh qty kembali.
- Bulk ke lokasi/kondisi sama dengan asal → posisi asal; selain itu/roll → posisi baru (roll: label `<label asal>-Kxxxxxx`, tidak bersegel).
- Movement `RETURN_IN`, `cost_allocations.reversed_*`, `part_reversal_allocations`.
- **Setelah tagihan final ditolak** (`ALREADY_FINALIZED`): pengembalian fisik part setelah final belum tersedia; koreksi harga via credit note.
- Keluar `{ part_event_id, use_event_id, qty, cost_restored, target_location, target_condition, target_position_id, version }`.

## Tagihan

### finalize_service_invoice_v1 (OWNER)
```json
{ "operation_id": "uuid", "ticket_id": "uuid", "expected_version": 7,
  "approved_estimate_revision": 1,
  "waiver_reason": "hanya untuk tagihan 0 tanpa persetujuan",
  "charge_lines": [
    { "kind": "LABOR", "description": "Ganti kapasitor", "quantity": "1", "unit_price": "135000" },
    { "kind": "PART", "service_part_event_id": "uuid-USE", "unit_price": "15000" } ] }
```
- Status akhir; satu tagihan per tiket (`ALREADY_FINALIZED`). `kind` ∈ LABOR/PART/VISIT/DIAGNOSIS. Nilai baris = round_half_up(qty × harga).
- PART: `service_part_event_id` USE milik tiket, qty = qty bersih (boleh dihilangkan), deskripsi default nama produk, harga boleh `"0"`. Setiap USE bersih wajib tepat satu baris (`PART_LINE_REQUIRED`); USE yang sudah direverse penuh tidak boleh ditagih.
- `approved_estimate_revision` wajib = revisi APPROVED aktif dan total ≤ `approved_limit` (`APPROVAL_REQUIRED`). Tanpa revisi hanya bila total 0, status CANCELLED/UNREPAIRABLE dan `waiver_reason` diisi.
- Tiket **tidak ditutup**. COGS servis = modal bersih pemakaian (setelah reversal) diakui sekali di `service_cost_recognitions`.
- Keluar `{ invoice_id, document_number, total, cost_recognized (hanya untuk OWNER), payment: {status,...}, version }`.

### credit_service_invoice_v1 (OWNER)
`{ operation_id, invoice_id, expected_version (tiket), reason, lines: [{ invoice_item_id, amount: "30000" }] }`
Per baris ≤ sisa nilai baris (setelah credit sebelumnya), total ≤ sisa tagihan (`REFUND_LIMIT_EXCEEDED`). Tidak me-refund otomatis; `refund_due` dihitung ulang.
Keluar `{ credit_note_id, document_number, total, payment, version }`.

## Pembayaran

### record_service_payment_v1 (OWNER/STAFF)
```json
{ "operation_id": "uuid", "ticket_id": "uuid", "payment_intent_id": "uuid (opsional)",
  "purpose": "SETTLEMENT (opsional; DEPOSIT ditolak)",
  "amount": "50000", "method": "CASH | TRANSFER | QRIS",
  "cashbox": "SHOP_DRAWER (default) | FATHER_WALLET (OWNER saja)", "tendered": "100000",
  "confirmed": true, "reference": "opsional", "expected_version": "opsional" }
```
- Keputusan pemilik 18-09-2026: **tanpa uang muka**. Sebelum tagihan dibuat → `INVOICE_REQUIRED`. Sesudahnya boleh dicicil: 0 < `amount` ≤ sisa (`PAYMENT_AMOUNT_MISMATCH` bila melebihi); lunas → `ALREADY_SETTLED`. Tiket tertutup (lunas) → `TICKET_CLOSED`. Boleh juga pada layanan yang sudah selesai (piutang servis); pembayaran yang melunasi layanan selesai menutup tiket otomatis.
- CASH: `tendered` wajib ≥ amount (`TENDERED_REQUIRED`/`INSUFFICIENT_TENDERED`); kembalian dihitung server; sesi kas OPEN dikunci (`CASH_SESSION_CLOSED`); `confirmed` tidak boleh dikirim.
- TRANSFER/QRIS: `confirmed: true` wajib dari centang petugas (`CONFIRMATION_REQUIRED`); `cashbox`/`tendered` ditolak.
- Keluar (untuk kuitansi): `{ payment_id, purpose, method, cashbox, amount, tendered, change, occurred_at, ticket_number, actor_name, payment: {status, invoice_total, invoice_net, net_received, outstanding, refund_due, ...}, closed_at, version }` (`closed_at` terisi bila pembayaran ini menutup tiket).

### refund_service_payment_v1 (OWNER)
`{ operation_id, ticket_id, amount, method, cashbox? (CASH), confirmed (non-tunai), reference?, reason, expected_version? }`
- Batas: `refund_due` (setelah final) atau seluruh uang muka lama bila tiket CANCELLED tanpa tagihan final; selain itu `INVOICE_REQUIRED`. Refund yang membuat tagihan pas lunas menutup layanan yang sudah selesai. `credit_service_invoice_v1` berlaku sama.
- CASH: sesi terkunci, saldo sistem ≥ amount (`INSUFFICIENT_CASH`, coba lagi dengan operation_id sama setelah tambah dana).
- Dialokasikan ke receipt yang masih bersaldo (terlama dulu, bisa beberapa receipt; receipt yang dikoreksi metode diganti receipt penggantinya).
- Keluar `{ payment_id, amount, method, cashbox, allocations: [{payment_id, amount}], payment, version }`.

### get_service_payment_status_v1
`{ ticket_id }` → `{ ticket_id, status, invoice_id, invoice_number, invoice_total, credit_total, invoice_net, received_total, refunded_total, correction_net, net_received, outstanding, refund_due }`
Rumus BR-10: `invoice_net = total − credit notes`; `net_received = Σ masuk − Σ keluar` (SERVICE_RECEIPT, CUSTOMER_REFUND, PAYMENT_REVERSAL, PAYMENT_REPLACEMENT); outstanding/refund_due `null` sebelum final. Invoice 0 + net 0 = PAID.

## Penutupan

### handover_service_v1 (OWNER/STAFF)
`{ operation_id, ticket_id, expected_version, receiver_name, condition_note?, accessories_note?, allow_unpaid?, unpaid_note? }`
Syarat: layanan belum selesai (`TICKET_COMPLETED`/`TICKET_CLOSED`), custody SHOP/FATHER (`INVALID_CUSTODY`), status akhir (`INVALID_TRANSITION`), tagihan final (`INVOICE_REQUIRED`), refund_due 0 (`REFUND_DUE`), sisa 0 (`PAYMENT_OUTSTANDING`) — kecuali `allow_unpaid: true` oleh OWNER (STAFF → `FORBIDDEN`) dengan `unpaid_note` ≥ 3 huruf (`REASON_REQUIRED`). Lokasi selalu CUSTOMER (tidak dari klien).
Efek atomik: custody CUSTOMER, `completed_at`, `closed_at` hanya bila lunas (selain itu `receivable_note` = catatan, piutang servis), event custody `is_handover=true` + nama penerima; audit mencatat sisa tagihan. Keluar `{ custody_location, receiver_name, completed_at, closed_at, outstanding, version }`.

### close_onsite_service_v1 (OWNER)
`{ operation_id, ticket_id, expected_version, completion_note?, allow_unpaid?, unpaid_note? }` — custody harus CUSTOMER (alat tidak dititipkan), syarat tagihan/sisa/piutang sama dengan serah terima. Keluar `{ completed_at, closed_at, outstanding, version }`.

Setelah layanan selesai, perintah pekerjaan (transisi, estimasi, part, tagihan, custody, jadwal, data tiket) → `TICKET_COMPLETED`; pembayaran, nota kredit, dan refund tetap dapat dicatat.

## Pembacaan

### list_service_tickets_v1
`{ status?: "READY" | ["READY","WORKING"], query?: "nomor / nama / HP", include_closed?: false, not_picked_up?: false, receivable?: false, service_location?, limit?: 25 (≤100), cursor? }`
Default (tanpa `include_closed`) memuat tiket yang belum ditutup, termasuk piutang servis. `receivable: true` = hanya layanan selesai yang belum lunas.
Urut terbaru. Keluar `{ items: [...], next_cursor: "string|null" }` (kirim `cursor` untuk halaman berikut). Item:
`id, number, customer_id, customer_name, customer_phone, customer_alt_contact, equipment_type, equipment_brand, equipment_model, complaint (≤200), work_status, service_location, custody_location, scheduled_at, parent_ticket_id, created_at, closed_at, completed_at, receivable, version, not_picked_up, payment_status, invoice_total (net), net_received, outstanding, refund_due`.
Pencarian HP menormalisasi (`+62 812…` = `0812…`).

### get_service_ticket_v1
`{ ticket_id }` → tiket lengkap:
`id, number, version, work_status, service_location, custody_location, equipment_*, complaint, initial_condition, accessories, address, scheduled_at, terminal_reason, test_result, created_at, closed_at, completed_at, receivable, receivable_note, mechanic_name,
customer {id,name,phone,alternate_contact,address,version}, parent_ticket {id,number,work_status,...}, child_tickets [...], not_picked_up, allowed_transitions [...],
approval {latest_revision, latest_status, active, approved_revision, approved_limit},
status_events [{from_status,to_status,kind,reason,actor_name,occurred_at}], custody_events [{from_location,to_location,condition_note,accessories_note,receiver_name,is_handover,actor_name,occurred_at}],
estimates [{id,revision,description,min_amount,max_amount,status,approved_limit,approved_method,approved_at,approved_by_name,consent_note,version}],
part_events [{id,kind,product_id,product_name,sku,base_unit,qty,net_qty,charge_unit_price,reverses_event_id,reason,actor_name,occurred_at,invoiced,source_location,source_label,cost}],
payments [{id,direction,purpose,method,amount,tendered,change,cashbox,reference,original_payment_id,actor_name,occurred_at}],
invoice {id,number,total,posted_at,items [{id,line_no,kind,description,quantity,unit_price,net_total,service_part_event_id,credited}], credit_notes [...], cost_recognized} | null,
payment {status,...}`.
`cost`/`cost_recognized` = null untuk STAFF; kontak/alamat = null untuk MAINTAINER. Foto dari domain lampiran.

## Pelanggan

### create_customer_v1 / upsert_customer_v1 (OWNER/STAFF)
create: `{ operation_id, name, phone?, alternate_contact?, address? }`; upsert: sama + `customer_id?` + `expected_version` (wajib bila `customer_id`).
HP atau kontak lain wajib (`CONTACT_REQUIRED`); HP dinormalisasi (`INVALID_PHONE`). Nomor sama boleh untuk pelanggan berbeda; **tidak ada merge otomatis**.
Keluar `{ customer_id, version, phone, similar_customers: [...] }`.

### find_similar_customers_v1
`{ name?, phone? }` → `{ candidates: [{id,name,phone,alternate_contact,address,version,match:["PHONE","NAME"]}] }`. Panggil sebelum membuat pelanggan baru; biarkan pengguna memilih.

### search_customers_v1
`{ query?, phone?, limit? }` → **array** `[{id,name,phone,alternate_contact,address,version,open_tickets,last_ticket_at}]`. Query berisi angka dianggap HP (ternormalisasi, mengandung); selain itu nama mengandung.

### list_customer_history_v1
`{ customer_id, limit? }` → `{ customer, tickets: [{id,number,equipment_type,complaint,work_status,service_location,parent_ticket_id,created_at,closed_at,payment_status,invoice_total}], sale_invoices: [{id,number,posted_at,total}] }`.

## Catatan untuk frontend (perubahan kontrak)

- `create_service_ticket_v1` STORE sekarang wajib `initial_condition`; `list_service_tickets_v1` mengembalikan objek `{items,next_cursor}` (dulu array).
- `record_service_payment_v1`/`refund_service_payment_v1` tidak lagi menerima `cash_session_id`/`change`; gunakan `cashbox` + `tendered` + `confirmed` dari centang nyata.
- `handover_service_v1` tidak menerima `location`. `transfer_service_custody_v1` memakai `to_location`.
- `use_service_part_v1` memakai `qty` (bukan `qty_base`/`product_unit_id`) + `expected_version`; `reverse_service_part_v1` wajib `ticket_id`, `expected_version`, `reason`.
- `approve_estimate_v1.method` kini kode: IN_PERSON/PHONE/WHATSAPP/OTHER. `record_estimate_v1` wajib `expected_version`.
- `finalize_service_invoice_v1` wajib `approved_estimate_revision` (atau `waiver_reason` untuk nol) dan baris PART untuk setiap part terpakai; tidak menutup tiket.
