# 10 — Keterlacakan Fitur ke Aturan dan Bukti

Baseline 1.1. Semua baris berstatus **NOT_IMPLEMENTED / NOT_RUN** sampai ada implementasi dan laporan uji aktual. Nomor AT merupakan definisi pada [pengujian](07-TEST-ACCEPTANCE.md), bukan hasil lulus.

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
