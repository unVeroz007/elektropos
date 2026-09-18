# 05 — Model Data Logis dan Constraint

Baseline 1.1. Ini kontrak desain schema, **bukan migrasi SQL yang sudah diterapkan**. Implementer wajib menerjemahkan ke DDL/RLS/RPC dan menguji. Aturan angka/kejadian: [aturan bisnis](02-BUSINESS-RULES.md).

## DATA-01 — Konvensi

- PK UUID, FK eksplisit; actor mengacu profil Auth yang tetap dipertahankan setelah akun nonaktif. Timestamp `timestamptz`, waktu server. Tabel mutable memiliki `version bigint` untuk optimistic concurrency.
- Uang/qty sesuai BR-01. Amount untuk receipt/refund positif; arah/type menyatakan tanda pada agregasi. Semua CHECK melarang nonfinite/out-of-range, bukan sekadar `>=0`.
- `invoice_items.gross_exact` memakai `numeric(38,9)` untuk produk qty3desimal × harga6desimal; intermediate fungsi memakai NUMERIC tanpa cast ke skala uang sebelum langkah pembulatan BR-04. Jangan menaruh gross_exact pada kolom harga6desimal dan kehilangan tiga digit sebelum menghitung diskon.
- Jangan menaruh total finansial/kuantitas hanya dalam JSON. JSONB dipakai untuk snapshot terstruktur nonotoritatif, metadata input atau audit terfilter dengan schema version.
- Semua tabel bisnis `private`, fungsi publik mengendalikan akses. Kolom biaya tidak diekspos ke staff.
- Referensi invoice, service, payment, receipt, stock document menggunakan FK nyata. Jangan memakai pasangan string type/id tanpa constraint untuk relasi finansial utama.
- Perubahan posted append-only melalui dokumen koreksi; master dapat diarsip. FK riwayat ON DELETE RESTRICT. Tidak menggunakan CASCADE delete dari produk/pelanggan ke transaksi.

## DATA-02 — Entitas inti

| Entitas | Kolom penting dan aturan |
|---|---|
| app_profiles | id FK auth.users, display_name, role OWNER/STAFF/MAINTAINER, active, version, created_at; role/active hanya jalur privileged |
| shop_settings | singleton id, nama/alamat/kontak, currency IDR, timezone Asia/Jakarta, receipt_width, configured_at, version; bukan tabel multi-toko |
| categories | id, name, active; kategori berproduk diarsip, tidak dihapus |
| products | id, sku, name, specification, aliases, category_id, base_unit, quantity_step, track_segments, min_stock, shelf, active, version; tidak menyimpan saldo stok authoritative di sini |
| product_units | id, product_id, label, factor_base, sale_step, sell_price, whole_roll (roll utuh bersegel; hanya barang roll dengan factor_base > 1), active, version; base immutable setelah digunakan, versi opsi lama dipertahankan |
| product_barcodes | id, product_id, product_unit_id nullable, code text unique; unit harus milik produk yang sama |
| product_price_history | id, unit_id, before_price, after_price, reason, actor_id, created_at; perubahan harga bukan edit riwayat |
| customers | id, name, phone_normalized nullable, alternate_contact nullable, address nullable, active; minimal kontak untuk servis, nomor tidak unique |
| suppliers | id, name, contact, address, active; tidak ada total_hutang atau fasilitas tempo R1 |

Indeks awal: unique lower(sku); unique barcode code; product(category_id,active); pencarian nama prefix terindeks bila sesuai query; phone_normalized nonunique. Alias substring/trigram hanya jika kebutuhan dan hasil pengukuran membenarkannya.

## DATA-03 — Dokumen stok, lot dan posisi fisik

| Entitas | Kolom penting dan aturan |
|---|---|
| stock_documents | id, number unique, kind RECEIPT/OPENING/TRANSFER/ADJUSTMENT/COUNT/DISPOSAL/REVERSAL, status DRAFT/POSTED, supplier_id nullable, source_note, source_date, posted_at, actor_id, reason, corrects_document_id nullable, operation_id, version |
| stock_document_items | id, document_id, line_no, product_id, unit_snapshot, qty_input, factor_snapshot, qty_base, acquisition_cost nullable, source/destination location, condition, note; unique(document_id,line_no) |
| inventory_lots | id, product_id, origin_item_id FK, posted_at, original_qty, original_cost, remaining_qty, remaining_cost, version; original immutable; remaining disesuaikan RPC dengan ledger |
| stock_positions | id, lot_id, location SHOP/FIELD_FATHER, condition SALEABLE/DAMAGED, qty_base, label nullable unique bila terisi, segment_capacity nullable, sealed boolean, version |
| stock_movements | id, group_id, lot_id, position_id, qty_delta, cost_delta, kind, stock_document_item_id nullable, invoice_item_id nullable, service_part_event_id nullable, credit_item_id nullable, actor_id, occurred_at, operation_id |
| stock_counts | id, owner_id, status DRAFT/POSTED, created_at, posted_document_id nullable |
| stock_count_items | count_id, position_id, expected_version, system_qty, counted_qty, reason; unique(count_id,position_id) |

Constraint/aggregate wajib:

- Satu lot memiliki banyak posisi; product diturunkan dari lot, hindari FK product yang dapat tidak cocok.
- `sum(position.qty_base) = lot.remaining_qty`; `sum(movement.qty_delta untuk posisi) = position.qty_base`. Posisi awal juga berasal dari movement receipt/opening, bukan saldo tanpa ledger.
- Lot remaining_cost sama dengan net cost_delta seluruh movement lot; nilai tidak duplikat pada setiap posisi. Transfer posisi/condition memakai cost_delta=0 pada level lot.
- Gerakan penjualan/part/return memiliki sumber valid tepat satu dari FK sumber. Transfer/koreksi memakai stock_document_item_id. Mutasi otomatis bukan insert bebas dari client.
- Sealed hanya untuk track_segments dengan qty=segment_capacity dan satu posisi satu roll. Posisi yang dipotong tidak dapat sealed. Posisi bulk dapat mengelompokkan beberapa pcs dalam lot/lokasi/kondisi yang sama.
- Transfer parsial membuat posisi tujuan tersendiri dan dua movements qty sama berlawanan; transfer full dapat memakai posisi tujuan baru agar sejarah location posisi immutable. Posisi source qty jadi 0; jangan mengganti lokasi lama tanpa ledger.
- `remaining_qty=0 => remaining_cost=0`; kedua nilai >=0. Konsistensi aggregate dijaga function/constraint trigger dan diuji, bukan CHECK yang mencoba membaca tabel lain.
- Stock_document posted tidak diedit/dihapus. Penghitungan stok fisik tidak menetapkan modal otomatis nol.

Indeks: inventory_lots(product_id,posted_at,id); positions(lot_id,location,condition), partial qty>0 sesuai query; movements(lot_id,occurred_at), (position_id,occurred_at), seluruh FK sumber untuk drilldown. Jangan membangun indeks duplikat unique/PK.

## DATA-04 — Servis

| Entitas | Kolom penting dan aturan |
|---|---|
| service_tickets | id, number unique, customer_id, mechanic_id FK profile owner, parent_ticket_id nullable, service_location STORE/ONSITE, custody_location CUSTOMER/SHOP/FATHER, equipment_type/brand/model/serial, complaint, initial_condition, accessories, address nullable, scheduled_at nullable, work_status, terminal_reason nullable, test_result nullable, completed_at nullable (layanan selesai), closed_at nullable (selesai dan lunas; CHECK closed_at ⇒ completed_at), receivable_note nullable, version, created_at |
| service_status_events | id, ticket_id, from_status, to_status, kind TRANSITION/CORRECTION, reason, actor_id, occurred_at; append-only |
| service_custody_events | id, ticket_id, from_location, to_location, condition_note, accessories_note, receiver_name nullable, actor_id, occurred_at; handover flag eksplisit |
| service_estimates | id, ticket_id, revision unique per tiket, description, min_amount nullable, max_amount, status DRAFT/PROPOSED/APPROVED/SUPERSEDED/REJECTED, approved_limit nullable, approved_method/time/actor, customer_consent_note, version |
| service_part_events | id, ticket_id, product_id, kind USE/REVERSE, qty_base, charge_unit_price snapshot, reverses_event_id nullable, reason, actor_id, occurred_at, recognized_invoice_id nullable |
| part_reversal_allocations | id, reversal_event_id, original_cost_allocation_id, qty_base, cost_amount, target_position_id; membuktikan modal/posisi yang dipulihkan pada reversal sebelum invoice |
| service_charge_drafts | id, ticket_id, line_no, kind LABOR/VISIT/DIAGNOSIS/PART, description, quantity, unit_price, part_event_id nullable, version; draft bisa diedit sebelum invoice final |

USE punya movement stok dan alokasi modal. REVERSE mengacu USE dan mengembalikan qty/modal sesuai bagian yang memang dipulihkan; total reverse <= use. Part event net yang sudah recognized tidak dipakai di invoice kedua. Draft part charge menautkan penggunaan tetapi tidak menjadi mutasi kedua.

Work status tidak menyimpan paid/collected. Payment state derived dari invoice/payments. Custody tetap bisa SHOP setelah invoice lunas. Onsite address/schedule wajib sesuai langkah workflow; field boleh null sebelum form lengkap tapi submit intake ONSITE harus valid.

Self-reference parent_ticket_id tidak boleh diri sendiri atau membentuk siklus. Tiket closed tidak diedit untuk pekerjaan baru. Schedule changes dicatat audit; status events hanya progres teknis.

## DATA-05 — Invoice, alokasi modal, pembayaran dan retur

| Entitas | Kolom penting dan aturan |
|---|---|
| invoices | id, number unique, kind SALE/SERVICE, service_ticket_id nullable unique, customer_id nullable, actor_id, posted_at, subtotal_net_lines, discount_total, total, client_reference_id unique, operation_id, corrects_invoice_id nullable; posted immutable |
| invoice_items | id, invoice_id, line_no, kind PRODUCT/PART/LABOR/VISIT/DIAGNOSIS, product_id nullable, service_part_event_id nullable, description_snapshot, qty_sell, factor_snapshot, qty_base nullable, unit_price_snapshot, item_discount_mode/value, gross_exact, base_net, invoice_discount_alloc, net_total |
| cost_allocations | id, lot_id, origin_position_id, invoice_item_id nullable, service_part_event_id nullable, qty_base, cost_amount, reversed_qty/cost summary, occurred_at; tepat satu sumber cost allocation |
| service_cost_recognitions | id, invoice_id SERVICE, part_event_id USE unique, cost_amount; nilai net USE dikurangi reversal sebelum invoice, bukan cost allocation baru; reversal setelah invoice melalui credit note |
| credit_notes | id, number unique, invoice_id, kind RETURN/PRICE_CORRECTION, reason, total, actor_id, posted_at, operation_id |
| credit_note_items | id, credit_note_id, invoice_item_id, qty_return_base nullable, amount, cost_reversal_amount, disposition SALEABLE/DAMAGED/NONE, line_no |
| return_cost_allocations | id, credit_item_id, original_cost_allocation_id, qty_base, cost_amount, target_position_id; menyimpan pemulihan sumber modal |
| payments | id, direction IN/OUT, purpose SALE_RECEIPT/SERVICE_RECEIPT/CUSTOMER_REFUND/PURCHASE_PAYMENT/PAYMENT_REVERSAL/PAYMENT_REPLACEMENT, invoice_id nullable, service_ticket_id nullable, stock_document_id nullable, original_payment_id nullable, method CASH/TRANSFER/QRIS, amount, tendered nullable, change nullable, cash_session_id nullable, reference nullable, confirmed_by, occurred_at, intent_id unique, operation_id |
| refund_allocations | id, refund_payment_id, original_payment_id, amount, credit_note_id nullable; unique refund/source pasangan; jumlah terikat pembayaran |

Aturan relasi:

- Invoice SALE tidak memiliki service_ticket_id; invoice SERVICE wajib tiket dan satu final invoice per tiket.
- Payment SALE menunjuk invoice SALE; payment SERVICE menunjuk tiket (uang muka lama sebelum invoice dan cicilan sesudahnya satu target yang sama). Pembayaran purchase menunjuk stock_document RECEIPT. CHECK target eksklusif menurut purpose.
- Refund SALE menunjuk invoice dan credit note melalui alokasi; refund servis menunjuk tiket. SUM refund allocations = outgoing amount; tidak melebihi net penerimaan asal. Payment reversal memiliki original-payment link melalui refund allocation untuk pembalikan keluar atau correction reference pada event pengganti; tidak memakai credit note jika invoice tidak berubah.
- PAYMENT_REVERSAL OUT dan PAYMENT_REPLACEMENT IN sama-sama memiliki original_payment_id FK dan target yang sama; unique pasangan per original pada R1. Replacement tidak boleh bernilai berbeda dari reversal. Penerimaan/refund pelanggan mengabaikan purpose koreksi, sementara net_received dan rekonsiliasi metode memasukkannya sesuai BR-07. R1 correct_payment hanya untuk receipt pelanggan IN yang belum punya refund/koreksi.
- Invoice total dan item allocation sesuai BR-04; gunakan constraint/function dan invariant checks untuk aggregate. `line_no` stabil/unique.
- qty/biaya part tidak dihitung lagi dari invoice_items untuk COGS; gunakan service_cost_recognitions. SALE COGS berasal cost_allocations terkait invoice_item.
- Pengurangan harga jasa boleh cost reversal=0. Pengembalian fisik part setelah service final menggunakan owner credit/reversal operation yang menautkan pemakaian asal; jangan menerima cost_reversal dari client.
- PART invoice line menautkan satu USE dan jumlah bersihnya; unique service_part_event_id bila terisi. Reversal setelah final menyimpan return_cost_allocations terkait credit item dan event REVERSE; tidak sekaligus membuat part_reversal_allocations kedua untuk qty yang sama. Tambahkan reversal_event_id nullable FK pada return_cost_allocations untuk bukti hubungan ini.
- Harga/nama/satuan pada invoice adalah snapshot. Mengarsipkan produk tidak mengubah nota.

Indeks: invoices(posted_at,id), (customer_id,posted_at); invoice_items(invoice_id,line_no); payments(target FK,occurred_at); credits(invoice_id,posted_at); setiap FK allocation untuk agregasi/refund locks. Unique intent dan client_reference mencegah duplikasi bisnis tambahan terhadap operation id.

## DATA-06 — Kas, audit dan operasional

| Entitas | Kolom penting dan aturan |
|---|---|
| cashboxes | id/code SHOP_DRAWER/FATHER_WALLET unique, label, custodian, active |
| cash_sessions | id, cashbox_id, opened_by, opened_at, business_date, opening_amount, status OPEN/CLOSED, closed_at/by, counted_amount nullable, expected_snapshot nullable, variance nullable, note, version; unique partial satu OPEN per box |
| cash_movements | id, session_id, direction IN/OUT, kind CUSTOMER_PAYMENT/REFUND/PURCHASE/EXPENSE/OWNER_ADD/OWNER_WITHDRAW/TRANSFER/CORRECTION, amount, payment_id nullable unique, transfer_group_id nullable, reason, actor_id, occurred_at, operation_id |
| operation_results | id, actor_id, command, operation_id, request_hash, result_entity_type/id, committed_at, result_version; unique(actor_id,command,operation_id); tidak menyimpan token/full payload |
| audit_events | id, actor_id, action, entity_type/id, operation_id nullable, redacted_changes, reason nullable, occurred_at; append-only |
| attachments | id, ticket_id nullable, product_id nullable, object_key unique, mime, byte_size, state PENDING/READY/FAILED, created_by, created_at; target tepat satu |
| backup_runs | id, started_at, completed_at nullable, status RUNNING/SUCCEEDED/FAILED, db/object manifests reference, counts/hashes, redacted_error, restore_verified_at nullable; write hanya runner |
| document_sequences | document_kind, business_date, next_value; nomor dihasilkan server dan unique pada dokumen |

Kas selalu positif amount; tanda ditentukan direction. Payment tunai dan cash movement satu-ke-satu ketika terjadi perpindahan uang. Invoice gratis tidak membuat payment/cash event nol. Transfer dua cash movements group sama jumlah sama berlawanan, tanpa payment pelanggan.

Document number contoh `TRX-20260915-000001`, `SRV-20260915-000001`, `RET-20260915-000001`. Prefix untuk receipt/stock juga unik per jenis. ID UUID adalah identitas utama; nomor boleh punya gap dan tidak boleh memakai `max()+1` tanpa lock. Kapasitas counter bukan batas empat digit.

Operation_results hanya committed; operasi yang rollback tidak meninggalkan efek finansial. Query NOT_FOUND tidak membuktikan request lain tidak sedang berjalan, karena record belum committed mungkin belum terlihat.

## DATA-07 — Migrasi dan integritas

- Bootstrap membuat tabel, indeks, grants/RLS, fungsi, enum/check, dan seed konfigurasi sistem (cashbox/status) dalam urutan dependensi. Seed contoh produk/transaksi terpisah dari produksi.
- Uji migrasi pada database kosong dan snapshot versi sebelumnya. Simpan backup, versi schema dan kompatibilitas frontend sebelum rilis.
- Tipe generated TS diperbarui setelah migrasi; validasi runtime tetap wajib. Tipe TS bukan constraint database.
- Perubahan schema yang memengaruhi money/qty/enum atau function signature harus memperbarui kontrak dan fixture uji. Jangan menambah tabel histori redundan tanpa kebutuhan sumber kebenaran yang jelas.
