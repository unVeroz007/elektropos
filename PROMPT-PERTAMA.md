# Prompt Pertama untuk AI Pengembang

Tempel **isi blok di bawah** sebagai pesan pertama pada AI yang bekerja di folder proyek ini. Jalankan AI dengan folder kerja `D:\Papa\elektropos` agar path dokumen dan perintah valid.

---

Saya ingin Anda mulai **membangun ElektroPOS sekarang** di folder kerja ini. Proyek saat ini berisi spesifikasi, belum aplikasi yang berjalan. Jangan berhenti pada ringkasan dokumen atau rencana.

Pertama baca, dalam urutan ini:

1. `AGENTS.md` — aturan kerja untuk AI.
2. `README.md` — peta seluruh dokumen dan mana yang menjadi acuan aktif.
3. `docs/01-SCOPE-DECISIONS.md` — keputusan pengguna, default rancangan, dan batas R1.
4. `PRD-ElektroPOS.md` — kebutuhan produk aktif.
5. `docs/09-IMPLEMENTATION-PLAN.md` dan `docs/10-TRACEABILITY.md` — urutan pekerjaan, ID fitur, dan bukti yang harus dipenuhi.

Setelah itu baca **dokumen terkait tugas yang sedang dikerjakan** berdasarkan pemetaan di `docs/10-TRACEABILITY.md`. Pada P0, baca bagian akun/izin di `docs/04-ARCHITECTURE-SECURITY.md`, model profil di `docs/05-DATA-MODEL.md`, kontrak auth/read di `docs/06-API-CONTRACTS.md`, serta AT-01/AT-02 di `docs/07-TEST-ACCEPTANCE.md`. Saat masuk P1, baca seluruh aturan uang/satuan/stok pada `docs/02-BUSINESS-RULES.md` sebelum membuat schema atau rumus. Dokumen arsip dan review historis bukan acuan implementasi.

Mulai langsung dari **Tahap P0**. Periksa isi folder, runtime Node/Python, lalu buat aplikasi React + TypeScript + Vite yang benar-benar bisa dijalankan secara lokal. Siapkan routing, UI dasar berbahasa Indonesia, konfigurasi lint/typecheck/test/build, Supabase lokal atau project uji terpisah, migrasi awal untuk profil/izin, login akun individual dan pembacaan data uji nyata melalui RPC berizin. Buat fixture akun/data **khusus uji**. Kerjakan jalur data dan keamanan yang nyata; jangan menampilkan mock sebagai transaksi atau integrasi selesai. Gunakan lockfile dan contoh konfigurasi tanpa secret.

Jalankan pemeriksaan yang tersedia, termasuk `python scripts/validate_docs.py` dan `python scripts/verify_spec_examples.py`, lalu command build/typecheck/test aplikasi yang sudah Anda buat. Uji AT-01 dan AT-02 terhadap database, termasuk panggilan langsung staff/anon yang harus ditolak. Jika P0 lulus, **lanjutkan P1 secara mandiri** sesuai rencana implementasi sampai katalog, satuan/konversi, lot/posisi dan mutasi stok memiliki bukti AT yang relevan. Jangan mulai finalisasi kasir P2 bila aturan hitung/stok P1 belum lulus.

Pakai layanan lokal/uji ketika kredensial Supabase/Cloudflare produksi, model scanner/printer, identitas toko, dan katalog nyata belum tersedia. Tandai hal yang memerlukan data tersebut sebagai OPEN dan tetap lanjutkan pekerjaan yang independen. Jangan membeli layanan/perangkat, menulis transaksi ke produksi, atau deploy dengan data toko nyata hanya berdasarkan prompt ini.

Setiap hasil kerja harus menyebut perilaku yang benar-benar berjalan, FR/AT yang tercapai, file yang diubah, command yang dijalankan beserta hasil PASS/FAIL/NOT_RUN, serta pekerjaan yang tersisa. Jika ada konflik spesifikasi, berikan contoh kasus, perbaiki dokumen pemilik aturan bersama kode/tes, lalu jalankan pemeriksaan dokumen lagi. Pertahankan file atau perubahan pengguna yang sudah ada.

---

Prompt ini mengarahkan AI melakukan P0 lalu P1. Setelah itu gunakan [template tugas](docs/templates/AI-TASK.md) dan [rencana implementasi](docs/09-IMPLEMENTATION-PLAN.md) untuk melanjutkan tahap berikutnya berdasarkan bukti yang telah lulus.
