# 01 — Scope dan Register Keputusan

Baseline 1.1 · 15 September 2026. Acuan proses: [AGENTS](../AGENTS.md). Fitur: [PRD](../PRD-ElektroPOS.md).

## Produk dan batas rilis

**R1** adalah rilis pertama untuk satu toko listrik dan servis elektronik, kasir PC, satu karyawan, ayah sebagai mekanik, dan developer sebagai pengelola. Pemantauan HP tersedia dari internet dengan akun berizin. R1 menggunakan IDR dan Asia/Jakarta.

Target akhir September tidak berarti seluruh daftar v1.0 harus dimasukkan. Semua FR pada PRD v1.1 adalah cakupan R1; pembagian tahap implementasi bukan izin mengklaim tahap yang belum selesai sebagai produk siap operasional penuh.

## Termasuk R1

- Akun individual owner/staff/maintainer, PC dan HP, pembatasan izin serta penonaktifan akun.
- Produk/SKU/variasi, barcode fisik, pencarian, satuan/konversi, pecahan, roll utuh dan potongan yang dapat dibedakan.
- Penerimaan pembelian lunas tanpa wajib PO, supplier sederhana, stok awal, transfer part ke ayah, pemakaian, penyesuaian, stok opname terbatas.
- Keranjang/draf, diskon oleh owner, pembayaran lunas barang tunai/transfer/QRIS manual, struk/cetak ulang, retur sebagian dan refund.
- Servis di toko/rumah, jadwal/alamat, estimasi/persetujuan, ongkos fleksibel, part, DP opsional, pelunasan, penyerahan, dan keluhan kembali yang tertaut.
- Pelanggan seperlunya, foto kondisi alat privat, ringkasan HP, laporan transaksi/penerimaan/laba kotor sederhana, ekspor CSV.
- Kas laci dan kas dibawa ayah, tutup hari, audit, backup, restore, pantauan kuota, penanganan koneksi gagal, pengujian perangkat nyata.

## Di luar R1

| Fitur | Alasan/batas |
|---|---|
| Cicilan, Bayar Nanti, piutang pelanggan | Pengguna meminta tidak dibuat; DP sebelum finalisasi servis tetap termasuk |
| Tempo supplier, PO bertahap kompleks, retur pembelian ke supplier | Kebijakan belum ditetapkan; penerimaan lunas dan koreksi stok bertanda alasan sudah termasuk |
| OCR label/nota dan scan kamera | Scanner fisik yang diminta; tidak diperlukan untuk pembukaan |
| Finalisasi transaksi offline/sinkronisasi penjualan offline | Default desain R1 online; draf lokal tetap termasuk |
| Tarif/masa garansi otomatis | Kebijakan belum ditentukan; keluhan kembali dapat dicatat |
| Akuntansi penuh, pajak/PPN otomatis, payroll | Laporan operasional/laba kotor saja |
| Multi-cabang/multi-tenant, marketplace, loyalty, native mobile | Tidak dibutuhkan oleh toko pertama |
| GPS langsung, optimasi rute, booking publik | Jadwal kunjungan dan alamat cukup |
| Payment gateway dan WhatsApp API otomatis | Pembayaran diverifikasi manusia; teks struk boleh disalin/dibagikan manual |
| Harga grosir bertingkat/kontrak tukang | Belum diputuskan; owner dapat memberikan diskon terotorisasi |
| Grafik analitik rumit, ekspor XLSX/PDF laporan massal | CSV dan cetak laporan sederhana cukup |

Jangan menambahkan tabel/alur kredit sekadar “untuk jaga-jaga”. Perubahan kebutuhan berikutnya masuk versi dan migrasi tersendiri.

## CONFIRMED — berasal dari pengguna

### DEC-U01 — Perangkat dan pemakai

PC sudah ada. Ayah dan satu karyawan kurang terbiasa teknologi. Ayah dan developer memantau melalui HP. Scanner barcode fisik dan printer akan dipilih/dibeli kemudian.

### DEC-U02 — Cara usaha

Menjual barang listrik dengan variasi dan potongan; ayah mekanik untuk servis toko dan panggilan rumah. Biaya menurut kerusakan/kesulitan setiap pekerjaan. DP boleh ada/tidak. Cicilan/utang pelanggan tidak dibuat.

### DEC-U03 — Biaya dan waktu

Internet/listrik dinyatakan aman. Developer merawat aplikasi. Target pembukaan akhir September 2026. Utamakan hosting gratis; pengguna menerima arah stack ringan Cloudflare Pages/Supabase. Anggaran Rp0 untuk layanan awal bukan harga hardware.

## DEFAULT — keputusan rancangan untuk implementasi baseline

Default berikut dibuat eksplisit agar AI dapat bekerja konsisten; bukan klaim bahwa pengguna menetapkan setiap detail. Perubahan harus memperbarui dokumen pemilik aturan dan pengujiannya.

### DEC-D01 — Online pada R1

Finalisasi membutuhkan server; draf lokal tidak mengurangi stok atau mencatat pembayaran. Perbedaan ini menggantikan janji offline penuh PRD v1.0 dan wajib diterangkan saat uji penerimaan pemilik.

### DEC-D02 — Stack dan akun

React/TypeScript/Vite; Tailwind/shadcn seperlunya; Router, TanStack Query, React Hook Form/Zod, Zustand, Decimal.js, Dexie; Supabase Auth/Postgres/Storage dan RPC; Pages Free. Tiga akun awal owner, staff, maintainer. Maintainer memantau dan mengelola teknis; tidak otomatis menjadi kasir atau pemilik bisnis.

### DEC-D03 — Izin bisnis

Owner menetapkan harga, diskon, penerimaan barang, penyesuaian, retur, refund, dan penutupan tagihan servis. Staff menjual dengan harga berlaku, menerima servis/DP/pelunasan yang telah ditentukan, mencetak, serta menyerahkan barang yang sudah boleh diserahkan. Rincian pada arsitektur.

### DEC-D04 — Hitungan

Kuantitas maksimum tiga desimal, langkah jual per produk; nilai harga enam desimal bila dibutuhkan; tagihan/pembayaran IDR bulat; pembulatan half-up pada baris bersih. Diskon total dialokasikan dengan sisa terbesar. Spesifikasi tunggal di aturan bisnis.

### DEC-D05 — Stok dan modal

Tidak ada stok negatif atau override stok. Modal per lot penerimaan; pemilihan FIFO untuk barang bulk, pemilihan roll fisik untuk barang potongan yang dilacak. Snapshot alokasi modal saat keluar dipertahankan. Ini pilihan desain untuk menelusuri modal/retur, bukan akuntansi pajak resmi.

### DEC-D06 — Kas dan pembayaran

Barang harus lunas saat transaksi selesai. Satu metode bayar per pembayaran; pembayaran campuran untuk satu penjualan barang ditunda. Servis boleh beberapa DP lalu pelunasan; setelah tagihan final harus lunas sebelum penyerahan/penutupan layanan. Kas ayah saat kunjungan dipisah dari laci toko.

### DEC-D07 — Kontinuitas dan akses

Login melalui Supabase Auth dengan email/password akun yang disiapkan; UI dapat mengingat email pada perangkat pribadi tanpa menampilkan sandi. PC/HP dapat memakai akun ayah bersamaan. Bukan implementasi username/password custom atau satu akun bersama.

### DEC-D08 — Sasaran operasional

Backup minimal sekali per hari dengan target RPO 24 jam dan target RTO 4 jam, baru dinyatakan terpenuhi setelah drill. Alarm kapasitas 70% dan tindakan sebelum 85% dari kuota aktif. Ini ambang internal, bukan SLA provider.

## OPEN — jangan diisi dengan fakta buatan

| ID | Keputusan/data | Cara melanjutkan | Dibutuhkan paling lambat |
|---|---|---|---|
| DEC-O01 | Model/driver printer, scanner, lebar struk dan anggaran hardware | Bangun jalur keyboard + browser print, uji dengan perangkat saat tersedia | Sebelum gate hardware |
| DEC-O02 | Nama/alamat/nomor toko dan akun email nyata | Gunakan fixture terpisah bertanda contoh | Sebelum setup produksi |
| DEC-O03 | Katalog, stok/modal awal, faktor roll/pak, langkah potong nyata | Implementasikan validasi; blokir penjualan produk belum lengkap | Sebelum produk tersebut dipakai |
| DEC-O04 | Lama/cakupan garansi | Catat keluhan ulang; owner memutuskan biaya per kasus | Sebelum mencetak janji garansi |
| DEC-O05 | Kebijakan pembatalan/biaya diagnosis/refund DP | Tidak ada DP otomatis hangus; owner memasukkan hasil penyelesaian yang disetujui | Saat kasus terjadi |
| DEC-O06 | Tempo supplier dan harga grosir | Di luar R1; jangan tampilkan opsi yang belum didukung | Sebelum memperluas scope |
| DEC-O07 | Tujuan backup, secret, media kedua, kanal pemberitahuan | Buat runbook/script dengan konfigurasi; jangan mengklaim backup aktif | Sebelum gate pemulihan |
| DEC-O08 | Tanggal pembukaan pasti dan penanggung jawab input awal | Ikuti urutan dependensi; jangan menjanjikan tanggal tanpa hasil uji | Sebelum jadwal rilis final |

## Perubahan dari v1.0

- Scanner fisik menggantikan OCR sebagai kebutuhan utama.
- Menambah kunjungan rumah, tracking kas ayah, serta pemantauan HP dari luar toko.
- Membedakan progres servis, finalisasi tagihan, pembayaran, penguasaan alat, dan penyerahan.
- Mengeluarkan piutang pelanggan; menunda tempo supplier dan offline penuh.
- Mengganti backend terpisah dengan Supabase dan operasi server atomik.
- Memajukan audit, koreksi, ketelitian, backup dan restore menjadi syarat rilis.
- Membolehkan akun ayah di PC/HP; tidak memakai larangan satu akun satu perangkat.

## Aturan mengubah scope

Sebut kebutuhan pengguna, fitur terdampak, dampak uang/stok/izin/kuota, migrasi, serta uji yang berubah. Jangan mengubah baseline hanya untuk mempermudah implementasi. Persetujuan fitur baru mengikuti instruksi pengguna pada tugas terkait; keputusan default rutin tidak memerlukan pertanyaan ulang jika sudah ditetapkan di sini.
