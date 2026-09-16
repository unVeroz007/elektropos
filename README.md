# ElektroPOS — Landasan Proyek

Versi landasan: **1.1**, 15 September 2026. Bahasa produk: Indonesia. Zona waktu toko: Asia/Jakarta. Mata uang: IDR.

ElektroPOS membantu satu toko listrik menjalankan penjualan, persediaan, servis di toko, dan kunjungan rumah. PC menjadi kasir utama; ayah dan developer dapat memantau lewat HP. Dokumen ini adalah pintu masuk pekerjaan manusia maupun AI.

**Status saat ini: dokumentasi dan spesifikasi; aplikasi belum diimplementasikan atau diuji.** Kelengkapan dokumen tidak membuktikan aplikasi bebas kesalahan. Kesiapan operasional ditentukan oleh bukti pada kriteria penerimaan.

## Urutan membaca

1. [AGENTS.md](AGENTS.md): instruksi kerja AI dan aturan penyelesaian tugas.
2. [Scope dan keputusan](docs/01-SCOPE-DECISIONS.md): apa yang dibuat, ditunda, serta keputusan pengguna dan default rancangan.
3. [PRD v1.1](PRD-ElektroPOS.md): kebutuhan produk dan ID fitur.
4. Baca dokumen khusus sesuai pekerjaan pada tabel berikut.

Untuk AI pengembang yang baru masuk proyek, gunakan [prompt pertama siap tempel](PROMPT-PERTAMA.md). Prompt itu mengarahkan pembacaan dan langsung memulai Tahap P0.

| Dokumen | Menjadi acuan untuk |
|---|---|
| [Aturan bisnis](docs/02-BUSINESS-RULES.md) | Uang, satuan, diskon, modal, stok, pembayaran, retur, laporan |
| [Alur dan UX](docs/03-WORKFLOWS-UX.md) | Langkah pengguna, status servis, izin tindakan, kesalahan dan tampilan |
| [Arsitektur dan keamanan](docs/04-ARCHITECTURE-SECURITY.md) | Stack, batas komponen, RLS, sesi, akses, transaksi dan performa |
| [Model data](docs/05-DATA-MODEL.md) | Entitas, hubungan, tipe, constraint, indeks dan riwayat |
| [Kontrak API](docs/06-API-CONTRACTS.md) | Perintah server, input, output, idempotensi, konflik dan kesalahan |
| [Pengujian dan penerimaan](docs/07-TEST-ACCEPTANCE.md) | Skenario dengan hasil terukur dan bukti siap pakai |
| [Operasi dan rilis](docs/08-OPERATIONS-RELEASE.md) | Setup, backup, pemulihan, kapasitas, gangguan dan peluncuran |
| [Rencana implementasi](docs/09-IMPLEMENTATION-PLAN.md) | Urutan pekerjaan, keluaran setiap tahap dan batas selesai |
| [Keterlacakan](docs/10-TRACEABILITY.md) | Hubungan fitur ke aturan dan pengujian |
| [Sumber teknis](docs/11-SOURCES.md) | Referensi resmi, tanggal pemeriksaan dan batas klaim |
| [Verifikasi dokumen](docs/12-VALIDATION-REPORT.md) | Pemeriksaan yang sudah dijalankan dan batas hasilnya |
| [Template tugas AI](docs/templates/AI-TASK.md) | Format pemberian tugas yang terbatas dan dapat diverifikasi |

## Cara memakai landasan

- Untuk mulai mengembangkan: gunakan satu tahap dari rencana implementasi sebagai tugas; jangan memerintahkan AI menebak seluruh produk dari judul proyek.
- Untuk mengubah aturan: perbarui dokumen pemilik aturan, keputusan terkait, PRD/kontrak jika terdampak, dan kasus uji. Jangan menyisipkan perubahan bisnis hanya di kode.
- Untuk memeriksa dokumen: jalankan `python scripts/validate_docs.py` dari root proyek. Pemeriksaan ini memvalidasi tautan lokal, ID fitur/uji/keputusan, pemetaan fitur, dan arsip; bukan bukti kebenaran bisnis atau keamanan aplikasi.
- Untuk memeriksa contoh angka: jalankan `python scripts/verify_spec_examples.py`. Ini memeriksa aritmetika spesifikasi secara independen dengan rasio eksak; bukan pengujian kode aplikasi/SQL yang belum dibuat.
- Untuk menilai rilis: gunakan checklist operasional dan hasil uji aktual. Jangan menandai lulus berdasarkan rencana pengujian saja.

## Arti status keputusan

**CONFIRMED** berasal dari jawaban pengguna. **DEFAULT** adalah keputusan desain eksplisit yang dipakai sebagai baseline kerja, dapat direvisi sebelum penggunaan nyata. **OPEN** memerlukan informasi/kebijakan nyata; AI tidak boleh mengubahnya menjadi fakta. Detail dan dampak keputusan ada di dokumen scope.

Dokumen acuan ini bersifat normatif untuk implementasi baseline. DEFAULT tidak boleh diklaim sebagai kebijakan yang pernah dinyatakan ayah. OPEN tidak menghalangi pekerjaan lain yang tidak bergantung padanya.

## Dokumen historis

- [PRD v1.0 asli](docs/archive/PRD-ElektroPOS-v1.0.md) disimpan utuh sebagai arsip.
- [Review awal](REVIEW-PRD-ElektroPOS.md) dan [catatan diskusi](KEPUTUSAN-PRODUK-ElektroPOS.md) menjelaskan asal kebutuhan; bukan spesifikasi aktif setelah v1.1.
- Jika ada perbedaan, gunakan baseline v1.1 dan instruksi terbaru pengguna. Daftar OCR, piutang, offline penuh, stack Express/Prisma/Socket.io, serta roadmap lama tidak otomatis berlaku.

## Target

Target pembukaan: akhir September 2026, tanggal persis belum ditentukan. Target biaya hosting awal Rp0 selama memenuhi batas paket gratis. Kedua target ini tidak menghapus kebutuhan pengujian, pemulihan data, atau pembatasan akses.
