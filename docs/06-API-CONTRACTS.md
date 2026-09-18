# 06 — Kontrak RPC dan Penanganan Kegagalan


> **Pembaruan 18 September 2026:** kontrak RPC yang sudah diimplementasikan dan diuji dijelaskan rinci di [penjualan](audit/kontrak-sales.md), [kas & pembelian](audit/kontrak-kas-pembelian.md), [servis](audit/kontrak-servis.md) dan [stok, laporan, foto](audit/kontrak-stok-laporan-foto.md). Bila berbeda dengan dokumen ini, kontrak tersebut yang berlaku karena sesuai kode dan uji.

Baseline 1.1. Kontrak ini harus diwujudkan dalam fungsi/migrasi dan diuji; nama di bawah belum merupakan endpoint yang sudah tersedia. [Keamanan](04-ARCHITECTURE-SECURITY.md), [model data](05-DATA-MODEL.md), dan [aturan bisnis](02-BUSINESS-RULES.md) berlaku bersama.

## API-01 — Protokol umum

- Supabase RPC melalui HTTPS, menggunakan session JWT pengguna dan publishable key aplikasi. Tidak ada kredensial database/secret dalam frontend.
- Nama fungsi versioned `*_v1`; kontrak berubah secara breaking melalui fungsi versi baru/migrasi kompatibel. Envelope input tunggal `p_input` JSON dengan validasi strict; unknown fields ditolak untuk perintah bisnis.
- Desimal berbentuk string kanonik; ID UUID; tanggal ISO8601. Server tidak menerima identitas actor/role dari payload.
- Input perintah write: `operation_id` UUID, `intent_id`/`client_reference_id` bila berlaku, `expected_version` untuk entitas mutable, `reason` bila perlu, dan field khusus command.
- Output sukses memuat `ok=true`, `operation_id`, `entity_id`, `document_number` bila ada, `server_time`, `version`/`schema_version`, ringkasan typed yang boleh dibaca role.
- Error bisnis terkontrol dipetakan dari SQLSTATE/detail yang terstruktur ke kode API. SQL exception harus membuat seluruh write rollback; jangan menangkap error lalu commit separuh operasi.
- Error yang dikirim tidak memuat SQL, stack trace, secret, biaya modal terlarang, atau data pelanggan lain. Detail teknis disimpan terfilter pada log operasional.

Contoh bentuk input (fixture kontrak, bukan data produksi):

```json
{
  "operation_id": "22222222-2222-4222-8222-222222222222",
  "client_reference_id": "33333333-3333-4333-8333-333333333333",
  "items": [{"product_unit_id": "44444444-4444-4444-8444-444444444444", "qty": "2.500", "expected_unit_version": 1}],
  "payment": {"method": "CASH", "tendered": "20000", "cash_session_id": "55555555-5555-4555-8555-555555555555"}
}
```

Harga final dibaca server dari unit dan versi; potongan/roll membutuhkan position allocations sesuai command. Contoh di atas hanya struktur dasar, bukan request yang pasti valid tanpa produk/posisi fixture.

## API-02 — Idempotensi dan konkurensi

1. Validasi auth aktif dan izin command, bentuk input, lalu hash canonical payload (tanpa token; field semantik termasuk intent dan expected versions).
2. Gunakan key `(auth.uid, command, operation_id)` dengan unique constraint. Serialisasikan operasi key sama menggunakan lock yang deterministik lalu baca result committed.
3. Key sama + hash sama: kembalikan hasil dokumen yang sama, tidak mengulangi stok/uang/audit bisnis. Key sama + hash berbeda: IDEMPOTENCY_CONFLICT.
4. Dapatkan seluruh root dokumen/target dan set resource yang diperlukan sebelum mutation. Lock urutan global: operation key; root business entities menurut `(type,id)`; cash_sessions menurut id; products menurut id; inventory_lots menurut id; stock_positions menurut id; original payments menurut id; document_sequences menurut `(kind,business_date)`. RPC lintas resource memakai urutan yang sama. Nomor dokumen diambil setelah seluruh lock bisnis yang diperlukan, bukan sebaliknya.
5. Baca ulang versi, stok, role bisnis relevan, saldo refund dan status setelah lock. Jika kebutuhan resource berubah, ulang perencanaan sebelum writes, bukan mengambil lock terbalik.
6. Simpan semua efek dan operation_result dalam satu transaksi. Tambahkan batas unique business intent untuk invoice/receipt agar refresh UI tidak membuat dokumen kedua dengan key baru.
7. Retry deadlock/serialization dengan key sama dan payload sama, backoff terbatas. Stock/version conflict butuh tinjauan ulang, bukan retry tanpa batas.

`get_operation_v1` mengembalikan COMMITTED atau NOT_FOUND untuk actor sendiri (maintainer dapat lookup melalui diagnostik berizin yang redacted). NOT_FOUND saat request aktif belum commit bukan bukti aman menerima pembayaran baru. Klien boleh retry operasi identik dengan key sama, bukan menghasilkan key baru.

UNKNOWN setelah timeout disimpan di Dexie bersama key/payload hash dan draf. Setelah login/koneksi kembali: lookup, lalu retry identik bila perlu. UI tidak memberi status gagal final sebelum server memastikan penolakan.

## API-03 — Pembacaan

| Fungsi | Input utama | Output/batas |
|---|---|---|
| get_current_profile_v1 | Tidak menerima uid pihak lain | Nama/role/active pengguna sendiri, kemampuan UI |
| search_products_v1 | query, barcode nullable, cursor, limit, category | Harga jual/satuan, spesifikasi, stok SHOP/FIELD terpisah; tanpa modal untuk staff |
| get_product_v1 | product_id | Unit, barcode, posisi roll ringkas; cost hanya owner/maintainer |
| list_invoices_v1 | range, cursor, customer_id nullable | Staff dibatasi ringkasan pekerjaannya hari ini; lookup nomor tepat untuk cetak/pelunasan yang relevan tetap tersedia tanpa margin |
| get_invoice_v1 | invoice_id atau number | Snapshot detail + payments/returns yang diizinkan, bukan semua kolom internal |
| list_service_tickets_v1 | status/location/schedule/query, cursor | Status kerja, pembayaran derived, custody, kontak sesuai peran |
| get_service_ticket_v1 | ticket_id | Riwayat, estimasi, part, tagihan, pembayaran, status selesai/piutang, lampiran melalui izin |
| get_cash_session_v1 | session_id | Staff hanya drawer; owner semua; maintainer baca |
| get_dashboard_v1 | date/range terbatas | Ringkasan sesuai role dan refreshed_at |
| get_report_v1 | report_type, start/end, cursor bila detail | Agregasi server; max31 hari interaktif; privilege cost diperiksa |
| export_csv_v1 | dataset, range <=366 hari, cursor | Chunk max1000 row, hanya owner/maintainer; formulasi CSV aman |
| get_health_v1 | Tidak menerima secret | Backup/kuota terakhir; owner ringkasan, maintainer detail terfilter |

List default25/max100, sort allowlist dan cursor stabil `(sort_value,id)`. Jangan izinkan nama kolom/SQL bebas dari payload. Pencarian dibatasi panjang 120 karakter; catatan panjang dibatasi di command validation. Total count exact hanya bila diperlukan untuk UI dan biaya kuerinya terukur.

## API-04 — Katalog dan stok

| Command | Input khusus | Efek atomik/output |
|---|---|---|
| upsert_product_v1 | product/unit/barcode fields, expected_version, reason perubahan harga | Owner; master/price history/audit; tidak mengubah snapshot transaksi |
| archive_product_v1 | product_id, expected_version | Owner; active=false, histori utuh |
| preview_catalog_import_v1 | baris CSV normalized, import_hash | Owner; validasi seluruh batch, daftar error; tidak memosting stok |
| commit_catalog_import_v1 | batch <=200 baris, import_hash, operation_id | Owner; atomic per batch, unique SKU/barcode; manifest batch untuk retry |
| post_stock_receipt_v1 | supplier/nota/items, costs, payment, draft_version | Owner; dokumen/lot/positions/movements/purchase payment/cash/audit |
| post_opening_stock_v1 | product/items, qty/cost, positions | Owner; dokumen OPENING dan lot; tanpa payment/cash |
| transfer_stock_v1 | posisi asal, qty, lokasi tujuan, ticket reference opsional | Owner; pasangan mutasi dan posisi tujuan, cost lot total tetap |
| adjust_stock_v1 | position/product, delta/count, expected_version, cost untuk positif, reason | Owner; koreksi terotorisasi dan lot baru bila positif |
| post_stock_count_v1 | count_id, seluruh expected_versions | Owner; seluruh batch hitung atomik atau conflict, ledger penyesuaian |
| dispose_stock_v1 | posisi/qty, reason | Owner; keluarkan stock/cost, catat kerugian disposal terpisah |

CSV batch tidak boleh dianggap impor penuh selesai bila sebagian batch belum berhasil. Setiap batch hasilnya ditampilkan; proses dapat dilanjutkan tanpa duplikasi dengan import_hash + nomor batch.

## API-05 — Penjualan dan pembayaran

### finalize_sale_v1

Owner/staff. Input client_reference_id keranjang, items product_unit_id/qty/expected_unit_version/position_id untuk roll, diskon jika owner, payment method/tendered/confirmation/cash_session. Customer opsional. Maksimum100 baris.

Server memvalidasi jumlah, step/factor, produk aktif, harga/versi, diskon, stok, sesi kas; menghitung BR-04, mengalokasikan stok/modal, membuat invoice/items, payment, cash movement, audit dan operation_result. Gratis oleh owner menghasilkan invoice tanpa payment. Output nota/total/kembalian dan qty stok terbaru terbatas izin, tanpa modal staff.

### return_sale_v1

Owner. Input invoice_id, invoice_item_ids/qty_base, disposition, original allocation choice bila diperlukan, reason, refund method/cash_session. Server menghitung batas qty, nilai dan modal asal serta receipt tersedia. Atomik credit note + return movements + refund/allocation + cash + audit. Jangan menerima nilai refund/COGS dari klien sebagai sumber benar.

### correct_payment_v1

Owner. Input original_payment_id, metode/pemegang yang benar, konfirmasi/alasan. Hanya receipt pelanggan IN yang belum pernah direfund/dikoreksi. Pembalikan PAYMENT_REVERSAL dan catatan PAYMENT_REPLACEMENT memulihkan net_received target yang sama; efek kas mengikuti sesi saat ini. Keduanya tertaut original_payment_id, nilai sama, dan bukan penerimaan/refund pelanggan baru. Tidak mengubah invoice/stok atau menghapus original. R1 menolak receipt yang sudah direfund/dikoreksi dan koreksi pembayaran supplier melalui command ini.

## API-06 — Servis

| Command | Input khusus | Guard/efek |
|---|---|---|
| create_service_ticket_v1 | customer/equipment/complaint/location/custody, address/schedule bila onsite, parent_ticket_id opsional | Owner/staff; tiket/log custody awal; tidak otomatis invoice/payment |
| update_service_details_v1 | ticket_id, expected_version, field allowlist | Owner seluruh draft relevan; staff kontak/kondisi intake sebelum INSPECTING; audit |
| update_service_schedule_v1 | ticket_id, expected_version, schedule, reason | Owner; jadwal dan audit |
| record_estimate_v1 | ticket_id, revision, scope/min/max | Owner; versi estimasi, tidak memosting pendapatan |
| approve_estimate_v1 | estimate_id, expected_version, agreed_limit, method, consent_note | Owner mencatat persetujuan pelanggan; audit; tidak mengizinkan biaya tanpa persetujuan nyata |
| transition_service_v1 | ticket_id, expected_version, target_status, reason/test_result | Owner; hanya transisi WF-05 |
| correct_service_status_v1 | ticket_id, expected_version, reason | Owner; hanya exception sebelum invoice/closed sesuai workflow |
| use_service_part_v1 | ticket_id, source position(s), qty, price draft | Owner; stock USE/cost allocation satu kali; guard approval dan status WORKING |
| reverse_service_part_v1 | use_event_id, qty, condition/reason | Owner; sebelum invoice gunakan reversal biasa; sesudah invoice wajib jalur koreksi tertaut invoice dan recognition |
| finalize_service_invoice_v1 | ticket_id, expected_version, charge lines, approved_estimate_revision | Owner; status terminal, biaya disepakati; invoice dan cost recognition saja, tidak mengurangi stok |
| record_service_payment_v1 | ticket_id, payment_intent_id, amount, method, tendered/cash_session | Owner/staff; hanya setelah tagihan dibuat, cicilan 0 < amount <= sisa (DEC-U04); label sesuai status, cash sesuai pemegang |
| refund_service_payment_v1 | ticket_id, reason, receipt allocations, cash_session/method | Owner; batasi refund_due/excess yang sah; tidak mengurangi revenue tanpa credit note |
| credit_service_invoice_v1 | invoice_id, line credits, physical part returns opsional, reason | Owner; kurangi invoice_net dengan credit note; cost hanya dibalik jika event part/qty yang benar dikembalikan; tidak otomatis refund dua kali |
| transfer_service_custody_v1 | ticket_id, expected_version, location, condition/accessories | Owner untuk ambil/bawa; staff boleh intake SHOP saat NEW; handover melalui command khusus |
| handover_service_v1 | ticket_id, expected_version, receiver_name | Owner/staff; terminal + final + tidak ada outstanding/refund_due; CUSTOMER dan closed_at atomik |
| close_onsite_service_v1 | ticket_id, expected_version, completion_note | Owner; custody CUSTOMER, terminal, final dan settled; closed_at |

Pada finalize_service_invoice_v1, approved_estimate_revision hanya boleh null untuk penyelesaian nol dengan pembebasan biaya/alasan owner sesuai BR-09. Biaya belum diketahui tidak dipetakan ke invoice nol; input keputusan pembebasan harus eksplisit.

Part reversal sesudah invoice menggunakan satu command internal bersama credit_service_invoice sehingga pemulihan stock/cost/credit konsisten; jangan menjalankan dua write terpisah dari UI. Credit harga saja tidak memulihkan part/modal.

## API-07 — Kas, pelanggan dan file

- `open_cash_session_v1`: opening_amount/box; unique sesi OPEN per box; owner/staff sesuai matrix.
- `close_cash_session_v1`: counted_amount, expected_version, reason jika selisih; snapshot expected/variance dan lock session. Concurrent payment harus commit sebelum snapshot atau ditolak karena sesi closed.
- `transfer_cash_v1`: source_session, target_session, amount>0, reason; owner, dua event atomik; tidak boleh source=target atau jumlah melampaui saldo sistem sumber.
- `record_cash_adjustment_v1`: owner; IN/OUT type/reason, nilai positif; arus manual di luar payment. Tidak menghapus selisih session closed.
- `upsert_customer_v1`: owner/staff, expected_version, kontak; kandidat duplikat ditampilkan, tidak auto-merge.
- `update_shop_settings_v1`: owner, allowlist identitas/struk, expected_version. Konfigurasi teknis dan role memakai jalur maintainer terpisah.
- `prepare_attachment_v1` dan `finalize_attachment_v1`: target entity, mime, size, operation_id; role/slot/key divalidasi. `get_attachment_url_v1`: izin baca lalu signed URL terbatas.
- Provisioning/nonaktif/reset akun bukan RPC publik bebas. Runner/Edge endpoint khusus memverifikasi maintainer dan memakai Admin Auth API, mencatat audit tanpa password. Browser hanya menerima status, tidak secret.

## API-08 — Kode kesalahan minimum

| Kode | Arti dan tindakan UI |
|---|---|
| AUTH_REQUIRED / ACCOUNT_DISABLED | Login diperlukan/akses nonaktif; hentikan write |
| FORBIDDEN | Tindakan tidak sesuai peran; jangan menyarankan membuka RLS |
| VALIDATION_ERROR | Field, kode alasan dan pesan Indonesia; draf tetap ada |
| NOT_FOUND | Entitas tidak ada/tidak boleh ditampilkan tanpa bocor data |
| VERSION_CONFLICT / PRICE_CHANGED | Muat data baru, tinjau ulang; operasi baru setelah perubahan input |
| INSUFFICIENT_STOCK / SEGMENT_TOO_SHORT | Tampilkan qty/posisi yang boleh diketahui; tidak memosting efek |
| CASH_SESSION_CLOSED | Buka/pilih sesi yang benar, jangan mengubah sesi lama |
| APPROVAL_REQUIRED / INVALID_TRANSITION | Persetujuan/status belum memenuhi syarat |
| ALREADY_FINALIZED / ALREADY_SETTLED | Tampilkan dokumen/status yang sudah ada jika user berhak |
| REFUND_LIMIT_EXCEEDED | Nilai/qty melebihi hak tersisa; muat ulang sumber |
| IDEMPOTENCY_CONFLICT | Key dipakai payload berbeda; hentikan dan periksa konteks |
| RETRYABLE_CONFLICT | Deadlock/serialization, retry payload/key sama terbatas |
| STORAGE_LIMIT / ATTACHMENT_INVALID | Foto/draf gagal disimpan; jelaskan tindak lanjut |
| INTERNAL_ERROR | Pesan aman + correlation id; tidak ada klaim transaksi gagal bila hasil belum diketahui |

HTTP/network timeout diperlakukan UNKNOWN, bukan kode penolakan bisnis. UI boleh memetakan kode PostgREST/Auth ke kategori di atas tanpa mengganti makna atomisitas.
