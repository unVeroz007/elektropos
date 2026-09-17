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

Per 16 September 2026, implementasi berikut telah diuji dan PASS pada database PostgreSQL lokal (27 AT).

### P0 — Bootstrap & autentikasi
- AT-01: owner login multi-perangkat, akun nonaktif ditolak, anon ditolak
- AT-02: staff/maintainer ditolak write bisnis & baca modal via RPC langsung

### P1 — Mesin hitung & persediaan
- AT-03: barcode fisik terdaftar, duplikat ditolak, satuan presisi
- AT-04: satuan meter dengan konversi dan harga per unit
- AT-05: presisi 0.1 m × 10 kali sisa tepat 0, lot modal habis; qty 4 desimal ditolak
- AT-06: roll segel 100m terverifikasi; sisa potongan tidak dianggap roll utuh
- AT-11: INSUFFICIENT_STOCK saat stok habis
- AT-14: lot/posisi/movement invariant terpenuhi
- AT-15: stok awal idempoten (key sama = 1x posting); OPENING tidak membuat purchase payment
- AT-16: transfer SHOP→FIELD, disposal, versi konflik ditolak

### P2 — Kasir & pembayaran
- AT-07: diskon baris + diskon nota (BR-04 largest-remainder); sum alokasi = total
- AT-08: PRICE_CHANGED saat versi satuan berubah, katalog dimuat ulang
- AT-09: finalisasi tunai atomik, kembalian benar
- AT-10: idempotensi operation_id (key+hash sama = 1 nota)
- AT-13: retur parsial refund, stok/modal kembali sesuai alokasi asal
- AT-24: kas laci sesuai BR-12, sesi buka/tutup, variance
- AT-25: tutup kas + koreksi metode pembayaran

### P3 — Servis
- AT-17: tiket toko/onsite, custody, kontak wajib
- AT-18: transisi status WF-05, estimasi PROPOSED→APPROVED, WORKING
- AT-19: USE + REVERSE part, cost allocation tercatat
- AT-20: DP, pelunasan, status UNPRICED/PAID
- AT-21: refund_due 20rb, refund melebihi ditolak (BR-10)
- AT-22: handover dengan nama penerima, closed_at atomik
- AT-23: tiket keluhan kembali, tiket asal tidak berubah

### P4 — Pengaturan & data
- AT-03 tambahan: find_by_barcode satuan tepat, daftar/hapus barcode, idempoten
- AT-26: laporan periode, staff tidak terima COGS
- AT-27: CSV aman formula (prefix `'`), foto validasi mime/size, anon ditolak
- AT-29: pengaturan toko checklist, validasi lebar struk, health per peran, backup manifest
- AT-28: offline deteksi, draft quota handling

### Verifikasi API (npm run verify:flows)
22 alur via REST API: beranda, katalog, scan barcode, daftar barcode, sesi kas, jual, struk, riwayat, laporan, COGS tersembunyi, servis/tiket/transisi, pelanggan, pengaturan, kesehatan, keamanan anon.
