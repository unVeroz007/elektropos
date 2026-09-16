# 12 — Laporan Verifikasi Paket Dokumen

Tanggal: 15 September 2026. Versi landasan: 1.1. Ruang lingkup: dokumen dan aritmetika contoh. Aplikasi, database, hardware, hosting dan backup operasional belum diimplementasikan/dijalankan dalam pekerjaan ini.

## Pemeriksaan yang dijalankan

| Pemeriksaan | Hasil |
|---|---|
| `python scripts/validate_docs.py` | PASS: tautan lokal, code fence, ID dan pemetaan dokumen aktif |
| ID persyaratan | 24 fitur PRD, masing-masing memiliki pemetaan penerimaan |
| ID penerimaan | 30 kasus, seluruhnya dirujuk fitur; status uji aplikasi tetap NOT_RUN |
| Aturan dan keputusan | 14 bagian aturan bisnis; 19 keputusan (3 CONFIRMED, 8 DEFAULT, 8 OPEN) |
| Arsip PRD awal | SHA256 sama dengan berkas sebelum revisi |
| `python scripts/verify_spec_examples.py` | PASS: 14 contoh aritmetika, 1.000 skenario alokasi diskon, 1.000 skenario retur kumulatif |

Prompt awal untuk AI pengembang ditambahkan setelah paket dasar; pemeriksaan struktur mencakup dokumen prompt dan tautannya.

Hash arsip PRD v1.0: `F0F0B7DD1BF92CBE404ED3046836553368B405C7B8BFBBEFBEF860BA76BE4478`.

## Konsistensi yang ditinjau dan diperjelas

- Scope R1 membedakan scanner fisik dari OCR; piutang/tempo/offline penuh tidak terselip pada implementasi awal.
- Pembayaran, pengerjaan dan custody alat terpisah, termasuk kunjungan tanpa titipan dan pembatalan dengan DP.
- Modal dipilih dari lot/roll fisik dan disimpan sebagai alokasi historis, dengan satu sumber COGS servis.
- Diskon/retur parsial menggunakan pembagian/remainder eksak dan penutupan sisa pembulatan, bukan pecahan biner.
- Roll utuh dan potongan kontinu dibedakan dari sekadar jumlah meter total.
- Kas ayah dipisah dari drawer; transfer tidak menjadi pendapatan. Koreksi metode bayar tidak menjadi penerimaan pelanggan kedua.
- Logout/pergantian akun membersihkan draf sensitif; namespace akun saja tidak diklaim aman untuk perangkat bersama.
- Status UNKNOWN memakai key yang sama dan tidak dinyatakan gagal/sukses tanpa bukti server.
- Backup mencakup data/fungsi/izin, pemulihan identitas dan foto, dengan gate restore yang nyata.

## Batas verifikasi

Pemeriksa struktur tidak membuktikan semua makna bisnis benar atau semua kebijakan sudah disetujui pengguna. Pemeriksa aritmetika memeriksa spesifikasi secara independen dengan Python Fraction; implementasi Decimal.js/SQL kelak masih harus diuji terhadap vektor yang sama.

Paket ini adalah baseline yang dapat diimplementasikan dan diperiksa, bukan sertifikat bebas kesalahan. Pilihan DEFAULT harus dijelaskan saat UAT, sedangkan OPEN membutuhkan data/kebijakan nyata pada batas waktu yang tercatat. Hardware, kapasitas aktual, keamanan runtime dan pemulihan baru terbukti setelah gate aplikasi dilaksanakan.
