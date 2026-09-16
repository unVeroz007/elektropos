# 11 — Sumber Teknis dan Batas Klaim

Diperiksa pada 15 September 2026. Referensi mendukung kemampuan/batas teknologi; pilihan scope, rumus bisnis, ambang operasional dan ukuran uji adalah keputusan desain ElektroPOS. Provider dapat berubah; periksa kembali sebelum deployment/upgrade.

| Sumber resmi | Hal yang digunakan dalam rancangan |
|---|---|
| [Supabase Pricing](https://supabase.com/pricing) | Paket Free: database500MB, sharedCPU/RAM500MB, Storage1GB, egress5GB dan cached egress tersendiri; backup otomatis tidak termasuk |
| [Supabase Project Pausing](https://supabase.com/docs/guides/platform/free-project-pausing) | Proyek Free dengan aktivitas rendah selama tujuh hari dapat dijeda |
| [Database size](https://supabase.com/docs/guides/platform/database-size) | Kapasitas database/disk perlu diukur, termasuk komponen penyimpanan terkait |
| [Database Backups](https://supabase.com/docs/guides/platform/backups) | Free perlu ekspor/cadangan sendiri; backup database tidak menyertakan objek Storage |
| [Database Functions](https://supabase.com/docs/guides/database/functions) | Operasi database dapat dipanggil melalui RPC; privilege/security definer harus dikendalikan |
| [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) | Pembatasan akses baris pada PostgreSQL/Supabase |
| [API Keys](https://supabase.com/docs/guides/getting-started/api-keys) | Publishable key untuk client; secret key untuk komponen tepercaya |
| [Securing API](https://supabase.com/docs/guides/api/securing-your-api) | Grants dan RLS adalah lapisan berbeda; keduanya perlu dirancang |
| [PostgreSQL NUMERIC](https://www.postgresql.org/docs/current/datatype-numeric.html) | Desimal eksak; tetapkan precision/scale dan aturan pembulatan |
| [PostgreSQL explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html) | Row lock dan deadlock; gunakan urutan resource konsisten |
| [Cloudflare Pages](https://www.cloudflare.com/en-gb/developer-platform/products/pages/) | Kandidat hosting antarmuka dengan paket Free dan SSL |
| [Pages limits](https://developers.cloudflare.com/pages/platform/limits/) | Kuota build/file dan batas paket harus diperiksa saat setup |
| [Pages Functions pricing](https://developers.cloudflare.com/pages/functions/pricing/) | Request fungsi server memiliki perhitungan/kuota tersendiri |
| [Vite](https://vite.dev/guide/) | Dev server dan build frontend; periksa versi Node yang dibutuhkan saat bootstrap |
| [TanStack Query](https://tanstack.com/query/latest/docs/framework/react/overview) | Pengelolaan server state/cache pada React |
| [shadcn/ui](https://ui.shadcn.com/docs) | Komponen UI yang dapat disesuaikan |
| [Decimal.js](https://mikemcl.github.io/decimal.js/) | Presisi dan mode pembulatan desimal pada JavaScript |
| [Dexie](https://dexie.org/docs/) | Wrapper IndexedDB; bukan sinkronisasi Supabase otomatis |
| [Vitest](https://vitest.dev/guide/) | Pengujian unit |
| [Playwright](https://playwright.dev/docs/intro) | Pengujian browser |
| [MDN storage quotas](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria) | Penyimpanan browser memiliki kuota dan dapat dihapus; tidak menggantikan backup |
| [MDN Web Bluetooth](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API) | Dukungan browser/perangkat terbatas; label Bluetooth printer tidak membuktikan kompatibel PWA |

Tidak ada klaim bahwa 500MB pasti cukup sekian tahun, bahwa Rp0 berlaku selamanya, atau bahwa provider menjamin performa target PRD. Benchmark, kebutuhan riil dan dashboard kuota menjadi dasar keputusan kapasitas.
