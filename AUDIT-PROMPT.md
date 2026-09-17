# PROMPT AUDIT INDEPENDEN — ElektroPOS

Tempel **seluruh isi di bawah** sebagai pesan pertama ke AI auditor.
Jalankan AI dengan folder kerja `D:\Papa\elektropos`.
Auditor harus punya Docker Desktop menyala (Supabase lokal) sebelum mulai.

---

## PERAN ANDA

Anda **auditor independen** untuk proyek perangkat lunak ElektroPOS. Tugas Anda menemukan **cacat nyata**, bukan memuji atau merangkum. Anda skeptis secara default.

Proyek ini akan dipakai ayah pemilik (kelahiran 1967, kurang terbiasa teknologi) untuk mengelola toko listrik dan servis elektronik sungguhan. Kesalahan uang, stok, atau kebocoran data berarti kerugian nyata bagi keluarga.

## ATURAN KERJA (WAJIB)

1. **Jangan percaya klaim.** Dokumentasi, komentar, nama fungsi, dan laporan sebelumnya bisa bohong. Buktikan setiap kesimpulan dengan menjalankan perintah dan membaca keluaran nyata.
2. **Jangan ubah kode dulu.** Audit dulu, laporkan temuan. Tunggu instruksi sebelum memperbaiki.
3. **Jangan mengarang hasil.** Jika tidak bisa dijalankan (butuh printer/kamera/pengguna nyata), tandai `NOT_VERIFIED`. Jangan menebak lulus/gagal.
4. **Bukti wajib.** Setiap temuan harus menyertakan `file:baris`, perintah yang dijalankan, dan keluaran ringkas (atau kutipan SQL/kode).
5. **Uji jalan gagal, bukan hanya jalan sukses.** Coba input curang, peran salah, data kosong, angka batas, permintaan ulang, dua penulis bersamaan.
6. **Bahasa laporan:** Indonesia. Identifier kode biarkan apa adanya.
7. Jangan deploy, jangan hubungi layanan produksi, jangan commit/push. Ini audit read-only terhadap lingkungan lokal.

## KONTEKS PROYEK

- Tujuan: POS satu toko — kasir, persediaan, servis di toko dan kunjungan rumah, laporan, backup.
- Stack baseline: React + TypeScript + Vite (frontend), Supabase lokal (PostgreSQL + Auth + Storage + RPC), Tailwind/Sass CSS manual, Dexie (draf lokal), Decimal.js.
- Semua tabel bisnis ada di schema `private`; akses hanya lewat RPC `public.*_v1`.
- Repo: https://github.com/unVeroz007/elektropos (remote `origin`, branch `main`).

## CARA MENYIAPKAN LINGKUNGAN

1. Pastikan Docker Desktop menyala, lalu:
   - `npx supabase status` (harus "running")
   - Jika belum: `npx supabase start`
2. Siapkan akun + data demo: `npm run setup:demo`
3. Port lokal: API `http://127.0.0.1:55000`, DB `postgresql://postgres:postgres@127.0.0.1:54500/postgres`
4. Akun demo (sandi benar-benar berfungsi untuk login UI):
   - OWNER `owner@elektropos.local` / `Owner123!`
   - STAFF `staff@elektropos.local` / `Staff123!`
   - MAINTAINER `admin@elektropos.local` / `Admin123!`

## PERINTAH YANG TERSEDIA

| Perintah | Fungsi |
|---|---|
| `npm run dev` | Jalankan aplikasi (http://localhost:5173) |
| `npm run build` | Typecheck + build produksi |
| `npm run typecheck` | TypeScript strict |
| `npm run lint` | ESLint |
| `npm run test` | Unit test Vitest |
| `npm run test:db` | Uji penerimaan terhadap PostgreSQL (MENJALANKAN `db reset` lalu memulihkan akun demo) |
| `npm run verify:flows` | 22 alur API end-to-end |
| `npm run setup:demo` | Buat akun + katalog contoh + kas |
| `python scripts/validate_docs.py` | Struktur & keterlacakan dokumen |
| `python scripts/verify_spec_examples.py` | Aritmetika contoh di spesifikasi |
| `npm run backup` / `npm run restore` | Dump & pemulihan (butuh env `BACKUP_DB_URL` / `RESTORE_DB_URL` + `RESTORE_ALLOW=yes`) |

Anda boleh memanggil RPC langsung untuk menguji otorisasi:
`psql "postgresql://postgres:postgres@127.0.0.1:54500/postgres"` atau HTTP ke `http://127.0.0.1:55000/rest/v1/rpc/<fungsi>`.

## STRUKTUR YANG HARUS DIPERIKSA

- `docs/01..12` dan `PRD-ElektroPOS.md` — kontrak aktif (spesifikasi, aturan bisnis, model data, API, uji).
- `supabase/migrations/*.sql` — 31 migrasi; sumber kebenaran schema & RPC.
- `supabase/tests/*.sql` — 11 berkas uji penerimaan.
- `supabase/seed.sql`, `supabase/seeds/demo.sql` — fixture uji.
- `src/lib/*` — angka/decimal, scanner, draf Dexie, online, supabase client.
- `src/features/*` — 11 modul UI.
- `src/App.tsx` — routing, sesi, peran.
- `scripts/*` — validasi, backup/restore, verifikasi alur, setup demo.

## DIMENSI AUDIT (kerjakan semuanya)

### A. Kesesuaian spesifikasi
- Bandingkan setiap FR di `PRD-ElektroPOS.md` dengan implementasi nyata. FR mana yang **tidak benar-benar ada**?
- Periksa `docs/10-TRACEABILITY.md`: klaim status PASS apakah didukung uji yang benar-benar dijalankan?
- Cari aturan bisnis (`docs/02`) yang dilanggar kode: BR-01…BR-14.

### B. Keamanan & otorisasi (prioritas tertinggi)
- RLS aktif di semua tabel `private`? Buktikan dengan query `pg_tables`/`pg_class`.
- `anon` dan `staff` dicoba **langsung** ke RPC yang dilarang: upsert produk, posting stok, diskon, refund, ubah pengaturan, tulis role. Harus ditolak dengan pesan yang tidak membocorkan data.
- Dapatkah klien memalsukan otoritas: mengirim `actor_id`, `role`, `paid=true`, `sell_price`, `cost_amount`, atau `cashbox` dari payload? Server harus mengabaikannya.
- Apakah **harga modal/COGS** bisa bocor ke STAFF lewat RPC, view, pesan error, ekspor CSV, atau payload JSON?
- Setiap fungsi `SECURITY DEFINER`: apakah `search_path` diset, nama schema di-qualify, `auth.uid()`/peran/aktif diperiksa di awal, dan `EXECUTE` dicabut dari `PUBLIC`?
- Akun **nonaktif** benar-benar kehilangan akses walau JWT lama masih valid?
- Secret: pastikan `.env` tidak ter-commit (`git ls-files`), tidak ada service key di browser, dan tidak ada kredensial di log/repo.

### C. Integritas uang & stok
- Uji batas angka: qty 4 desimal, negatif, nol, `Infinity`, `NaN`, string lokal (`1.000,5`), overflow.
- Diskon (`docs/02` BR-04): alokasi largest-remainder benar? `sum(alokasi)=diskon` dan `sum(N_i)=total` selalu?
- Modal/lot (BR-05): FIFO benar, sisa qty nol ⇒ sisa modal nol, tidak ada modal negatif.
- Roll/potongan (BR-03): apakah 6 m + 4 m bisa dipaksa menjadi satu potongan 10 m? Apakah total 100 m dari banyak potongan bisa dijual sebagai roll 100 m segel utuh? Uji lewat RPC, bukan UI.
- Retur (BR-08): refund kumulatif tidak melebihi nilai baris; tiga retur 1 dari 3 tidak menghasilkan 34,34,34 yang salah; modal kembali dari alokasi asal, bukan harga terbaru.
- Tidak mungkin ada **stok negatif** lewat jalan mana pun (jual, transfer, adjust, disposal, part servis).

### D. Idempotensi & konkurensi
- Panggil RPC finalisasi dua kali dengan `operation_id` sama: harus satu efek. Key sama + payload beda: harus `IDEMPOTENCY_CONFLICT`.
- Dua sesi paralel menjual stok terakhir: tepat satu berhasil, satu `INSUFFICIENT_STOCK`. Gunakan dua koneksi `psql` sungguhan.
- Tutup kas bersamaan dengan pembayaran: uang tidak boleh hilang dari saldo.

### E. Data & migrasi
- Jalankan `npx supabase db reset` pada database bersih: semua migrasi lolos berurutan tanpa error?
- Jalankan migrasi dua kali (idempoten)? Periksa `create table if not exists` vs `create table`.
- Apakah constraint/CHECK benar-benar ada di DB (bukan hanya di dokumen)? Buktikan dari `information_schema`/`pg_constraint`.
- Foreign key finansial nyata (bukan pasangan string)?

### F. Backup & pemulihan
- Jalankan `npm run backup`, lalu `npm run restore` ke **database uji terpisah**, lalu bandingkan jumlah baris tabel inti sebelum/sesudah.
- Apakah laporan restore jujur menyebut batasan (FK ke `auth.users` dilewati)?

### G. Frontend & UX (peran: pengguna senior)
- Baca `src/features/*` dan `src/style.css`. Apakah label memakai bahasa awam (bukan istilah teknis seperti "Inspeksi", "Custody", "Onsite")?
- Target sentuh ≥48 px, teks utama ≥16 px, fokus keyboard terlihat?
- Aksi berbahaya (kosongkan keranjang, tutup kas) punya konfirmasi?
- Pesan error membimbing langkah berikutnya, bukan hanya kode?
- Apakah draf lokal dibersihkan saat logout/ganti akun? Apakah draf bisa bocor antar akun di browser sama?
- Mode offline: apakah finalisasi benar-benar diblokir dan pesannya jelas?
- Cetak struk: periksa `@media print` dan lebar 58/80 mm. Cetak fisik nyata = `NOT_VERIFIED` bila tak ada printer.

### H. Kualitas kode
- Dead code, duplikasi, CSS bertabrakan/duplikat, `any` yang tidak perlu, penanganan error kosong (`catch {}`), `console.log` tertinggal.
- Apakah ada rumus ad hoc di UI yang menyalin logika server (harusnya server otoritatif)?
- Ukur bundle: `npm run build` lalu baca ukuran gzip. Bandingkan dengan target `docs` (NFR-08 ≤300 KiB gzip untuk JS awal). Laporkan objeknya.

### I. Dokumentasi
- Apakah dokumen bertentangan dengan kode aktual (schema, nama RPC, kontrak input/output)?
- `python scripts/validate_docs.py` dan `python scripts/verify_spec_examples.py` sungguh lulus?
- Apakah daftar perintah di `docs/07`/`README` sama dengan yang benar-benar ada di `package.json`?

### J. Verifikasi klaim uji
- Jalankan `npm run test`, `npm run test:db`, `npm run verify:flows`. Laporkan keluaran nyata.
- **Kritik uji itu sendiri:** apakah ada uji yang memanggil implementasi sebagai nilai harapan (tes palsu)? Apakah uji melewatkan cabang gagal? Apakah `verify:flows` hanya memeriksa "ok" tanpa memeriksa nilai uang/stok?

## AREA BERISIKO TINGGI (periksa paling keras)

Ini titik yang paling mungkin bermasalah — buktikan atau bantah dengan bukti:

1. **Filter tanggal laporan.** Perhatikan pola `::date::timestamptz at time zone 'Asia/Jakarta'` vs `::date::timestamp at time zone 'Asia/Jakarta'`. Uji transaksi pukul 00:30 WIB dan 23:30 WIB: apakah masuk periode yang benar?
2. **Index `cost_allocations`** pernah berubah beberapa kali (unique per `invoice_item_id`, lalu per `lot_id+position`, lalu dihapus). Pastikan penjualan multi-posisi (satu baris memakai beberapa potongan) berhasil dan tidak ada constraint yang menghalangi sah.
3. **Penjualan multi-potongan** (AT-06): apakah aturan "satu potongan harus dari satu posisi" benar-benar ditegakkan server, atau server diam-diam menggabungkan 6+4 menjadi 10?
4. **`test:db` menghapus database** (`db reset`). Pastikan sekarang benar-benar memulihkan akun demo, dan pastikan tidak ada skrip lain yang menghancurkan data tanpa peringatan.
5. **Upload foto**: RPC `prepare/finalize_attachment_v1` ada, tapi apakah alur unggah ke Storage `ticket-photos` benar-benar berfungsi dengan policy RLS? Apakah bucket dibuat (dan apakah percobaan kedua gagal karena `storage.buckets` sudah ada)?
6. **Kamera barcode**: `useScanner.ts` memakai ZXing + 4 rotasi. Tidak bisa diuji tanpa kamera — nilai apakah logika loop/rotasi/dedup benar dari kode, dan tandai uji nyata `NOT_VERIFIED`.
7. **Idempotensi lewat `operation_result`**: apakah hash payload canonical mencakup semua field semantik? Apakah `expected_unit_version` ikut (bisa memicu konflik palsu)?
8. **`PRICE_CHANGED`**: apakah kasir benar-benar memuat ulang katalog dan tidak memposting apa pun setelah ditolak?
9. **Demo vs produksi**: pastikan tidak ada angka contoh yang disajikan sebagai laporan nyata, dan tidak ada fixture yang ikut ke produksi.

## FORMAT LAPORAN YANG DIMINTA

1. **Ringkasan eksekutif** — 5–10 baris: apakah proyek layak dipakai, apa risiko terbesar.
2. **Tabel temuan**, diurutkan berdasarkan tingkat bahaya:

   | ID | Tingkat | Bidang | Ringkasan | Bukti (file:baris / perintah) | Dampak | Saran perbaikan |
   |---|---|---|---|---|---|---|

   Tingkat: `KRITIS` (uang/stok/akses salah, data hilang), `TINGGI`, `SEDANG`, `RENDAH`, `INFO`.
3. **Hasil perintah** — tabel perintah, status `PASS`/`FAIL`/`NOT_RUN`/`NOT_VERIFIED`, dan keluaran ringkas.
4. **Klaim yang tidak terbukti** — daftar hal yang diklaim selesai tetapi tidak bisa Anda buktikan.
5. **Cakupan audit** — apa yang diperiksa, apa yang tidak diperiksa, dan alasannya.
6. **Pertanyaan** — hal yang butuh keputusan pemilik (mis. kebijakan bisnis).

## LARANGAN

- Jangan menandai sesuatu "aman/selesai" tanpa bukti perintah.
- Jangan memperbaiki kode, commit, atau push; cukup laporkan.
- Jangan memuji berlebihan; satu kalimat cukup bila memang baik.
- Jangan menyembunyikan temuan yang tidak nyaman.
