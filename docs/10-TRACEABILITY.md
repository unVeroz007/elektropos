# 10 — Keterlacakan Fitur ke Aturan dan Bukti

Baseline 1.1. Tabel pemetaan di bawah adalah kontrak: setiap FR harus punya kasus penerimaan. Status bukti aktual dicatat pada bagian **Status bukti** di akhir dokumen; nomor AT tetap merujuk definisi pada [pengujian](07-TEST-ACCEPTANCE.md).

| Fitur PRD | Pemilik aturan/kontrak | Kasus penerimaan | Tahap |
|---|---|---|---|
| FR-AUTH-01 | SEC-01/02/03, API-01 | AT-01, AT-02 | P0 |
| FR-CAT-01 | BR-01/02/03, DATA-02, API-04 | AT-03, AT-04, AT-05, AT-06 | P1 |
| FR-CAT-02 | BR-02/03, WF-01, API-03 | AT-03, AT-06, AT-12 | P1/P2 |
| FR-INV-01 | BR-05/06, DATA-03, API-04 | AT-14, AT-15 | P1 |
| FR-INV-02 | BR-03/05/06, WF-04, API-04 | AT-06, AT-16, AT-19 | P1/P3 |
| FR-INV-03 | BR-06, DATA-03, API-04 | AT-16 | P1 |
| FR-POS-01 | BR-04, WF-01, UX-02 | AT-07, AT-08, AT-28 | P2 |
| FR-POS-02 | BR-04/05/07, API-02/05 | AT-09, AT-10, AT-11 | P2 |
| FR-POS-03 | WF-01, ARC-05 | AT-12 | P2/P5 |
| FR-POS-04 | BR-08, API-05 | AT-13, AT-14 | P2 |
| FR-SRV-01 | WF-03/04, DATA-04, API-06 | AT-17 | P3 |
| FR-SRV-02 | BR-09, WF-05, API-06 | AT-18 | P3 |
| FR-SRV-03 | BR-05/09, DATA-04/05, API-06 | AT-19, AT-16 | P3 |
| FR-SRV-04 | BR-07/09/10, API-06 | AT-20, AT-21 | P3 |
| FR-SRV-05 | BR-11, WF-06/07, API-06 | AT-22, AT-23 | P3 |
| FR-CUS-01 | DATA-02, WF-03, API-07 | AT-17, AT-23 | P3 |
| FR-CASH-01 | BR-12, WF-09, API-07 | AT-24, AT-25 | P2/P4 |
| FR-RPT-01 | BR-13, ARC-03, API-03 | AT-26, AT-30 | P4 |
| FR-RPT-02 | BR-05/13, API-03 | AT-14, AT-26 | P4 |
| FR-DATA-01 | SEC-04, API-04/07 | AT-15, AT-27 | P4 |
| FR-RES-01 | UX-02, API-02/08, ARC-03 | AT-10, AT-28 | P2 |
| FR-OPS-01 | OPS-03/04/05/06 | AT-29, AT-30 | P4/P5 |
| FR-SEC-01 | BR-14, SEC-01/02/03/04 | AT-01, AT-02, AT-27 | Semua |
| FR-SET-01 | DEC-O02/03, OPS-02, API-07 | AT-29, AT-12 | P4/P5 |

NFR-01/02/03/04/08 diperiksa AT-30 dan beban konkurensi AT-11. NFR-05/10 diperiksa seluruh kasus money/stock. NFR-06/07 melalui AT-12/30. NFR-09 melalui AT-29/30.

Saat menambah FR, tambahkan definisi PRD, scope, aturan/API/data bila terkait, kasus AT dengan expected result, dan baris di tabel ini. Pemeriksa dokumen akan menolak FR tanpa pemetaan atau AT yang tidak dikenal.

## Status bukti aktual

Per 18 September 2026 (branch `fix/audit-menyeluruh`), setelah audit independen 17 September dan perbaikannya
([dokumen perbaikan](audit/PERBAIKAN-AUDIT-2026-09.md)). Status lama 16 September dicabut: beberapa uji waktu itu
mengesahkan bug (mis. AT-06 menerima potongan 6 m + 4 m sebagai 10 m).

Bukti otomatis: `npm run test:db` (30 berkas SQL di database uji terpisah), `npm run test` (Vitest unit + komponen),
`npm run verify:flows` (46 pemeriksaan HTTP pada Supabase lokal), `npm run test:db:cash-concurrency`, dua koneksi
`psql` untuk stok terakhir, dan backup→restore ke database terpisah. **PASS** = dibuktikan uji otomatis;
**SEBAGIAN** = logika terbukti, perangkat/pengguna nyata belum; **NOT_VERIFIED** = belum ada bukti.

| AT | Status | Bukti |
|---|---|---|
| AT-01 | SEBAGIAN | `p0_auth_access.sql`, JWT akun nonaktif ditolak semua RPC (`require_role`); login PC+HP bersamaan belum diuji di perangkat |
| AT-02 | PASS | `p0_auth_access.sql`, `sales_*`, `service_guards.sql`, `report_period.sql`, `verify:flows` (diskon staff, jual oleh akun teknis, retur staff) |
| AT-03 | PASS | `p4_barcode.sql`, `sales_catalog.sql` |
| AT-04 | PASS | `sales_catalog.sql`, `p1_p2_extra.sql` |
| AT-05 | PASS | `p1_p2_extra.sql`, `numbers.test.ts` |
| AT-06 | PASS | `p1_at06.sql` (ditulis ulang), `sales_roll.sql` (termasuk satuan ikat 10 m tanpa tanda roll utuh), `sales_catalog.sql` (tanda `whole_roll`), `cart.test.ts`, `productForm.test.ts`, `verify:flows` (SEGMENT_TOO_SHORT/NOT_SEALED, tanda satuan) |
| AT-07 | PASS | `sales_finalize.sql` (vektor BR-04), `cart.test.ts` |
| AT-08 | PASS | `p2_price_changed.sql`, `sales_catalog.sql`, `cart.test.ts` (muat ulang harga) |
| AT-09 | PASS | `sales_finalize.sql`, `verify:flows` (total, kembalian, saldo laci, stok) |
| AT-10 | PASS | `sales_finalize.sql`, `verify:flows` (kirim ulang, konflik isi, `get_operation_v1`) |
| AT-11 | PASS | `sales_finalize.sql`, dua koneksi paralel: satu nota, satu `INSUFFICIENT_STOCK`, stok akhir 0 |
| AT-12 | SEBAGIAN | Data struk lengkap (`sales_read.sql`, `verify:flows`); cetak fisik 58/80 mm dan scanner/kamera nyata NOT_VERIFIED |
| AT-13 | PASS | `sales_return.sql` (multi-lot, kumulatif, NONE, pecahan, T=0), `returns.test.ts`, `verify:flows` |
| AT-14 | PASS | invariant ledger di `p1_p2_extra.sql`, `supplier_returns.sql`, restore (0 selisih) |
| AT-15 | PASS | `p1_stock.sql`, `supplier_purchase.sql` |
| AT-16 | PASS | `stock_mutations.sql`, `stock_count.sql`, `countModel.test.ts` |
| AT-17 | PASS | `service_flow.sql`, `service_customers.sql`, `verify:flows` |
| AT-18 | PASS | `service_guards.sql` (64 pasangan WF-05), `logic.test.ts` |
| AT-19 | PASS | `service_parts.sql` (pakai + kembalikan part memulihkan stok & modal) |
| AT-20 | PASS | `service_flow.sql`, `service_money.sql`, `logic.test.ts`, `verify:flows` (bayar sebelum tagihan ditolak, cicilan, melebihi sisa ditolak, kembalian server) |
| AT-21 | PASS | `service_money.sql` (nota kredit ->refund lintas receipt, batal tanpa tagihan, uang muka lama) |
| AT-22 | PASS | `service_flow.sql`, `service_money.sql`, `logic.test.ts`, `verify:flows` (serah terima sebelum tagihan ditolak; sisa tagihan hanya owner; piutang tampil di beranda; lunas menutup tiket) |
| AT-23 | PASS | `service_flow.sql` |
| AT-24 | PASS | `cash_sessions.sql`, `test:db:cash-concurrency`, `verify:flows` |
| AT-25 | PASS | `cash_correct_payment.sql`, `cash_adjust_transfer.sql` |
| AT-26 | PASS | `report_period.sql` (batas jam WIB, retur lintas bulan), `report_dashboard.sql`, `verify:flows` (staff tanpa modal) |
| AT-27 | PASS | `report_export.sql`, `attach_storage.sql`, `verify:flows` (unggah foto ke Storage nyata, tanpa slot ditolak) |
| AT-28 | SEBAGIAN | Blok bayar saat offline & hasil tak diketahui (`payment.test.ts`, `useCommand`); putus jaringan nyata NOT_VERIFIED |
| AT-29 | PASS | `p4_setup_health.sql`; backup→restore SUCCEEDED ke database terpisah (baris, 78 RPC, foto, invariant); restore menolak database aplikasi & target tidak kosong |
| AT-30 | SEBAGIAN | JS awal 174 KiB gzip (≤300, NFR-08); performa p95 dengan fixture besar dan uji pengguna senior NOT_VERIFIED |

Belum ada: Playwright (alur browser, viewport HP/PC, cetak), UAT dengan ayah/karyawan, pemulihan ke instance Supabase kedua.
