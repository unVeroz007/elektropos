# ElektroPOS — Hasil Diskusi Kebutuhan

> **Catatan historis diskusi.** Isi berikut merekam tahap sebelum konsolidasi. Acuan aktif kini [landasan v1.1](README.md), [PRD](PRD-ElektroPOS.md), dan [register keputusan](docs/01-SCOPE-DECISIONS.md). Status “belum direvisi” dan “draft” di bawah adalah status saat catatan dibuat, bukan status paket terbaru.

Tanggal pencatatan: 15 September 2026  
Dasar: dua putaran jawaban pengguna atas pertanyaan review PRD.  
Status: kebutuhan terkonfirmasi dan usulan untuk revisi PRD v1.1. PRD v1.0 belum direvisi; jika ada perbedaan, keputusan pengguna yang dicatat di sini menjadi acuan diskusi terbaru.

## 1. Kebutuhan yang dikonfirmasi pengguna

| Area | Keputusan/kondisi |
|---|---|
| Perangkat kasir | PC sudah tersedia dan menjadi perangkat utama |
| Akses HP | Ayah dan pengguna sebagai developer perlu memantau seluruh aktivitas toko melalui HP, termasuk dari luar toko, menggunakan akun yang memiliki akses |
| Perangkat tambahan | Scanner barcode fisik untuk memudahkan input barang masuk dan keluar, serta printer; model belum dipilih. OCR teks tidak diminta dalam klarifikasi ini |
| Pengguna toko | Ayah menangani kasir; direncanakan satu karyawan. Keduanya masih kurang terbiasa dengan teknologi |
| Barang | Ada penjualan potongan dan berbagai variasi/satuan; aturan hitung harus rinci, konsisten, dan dapat diuji. Ketelitian fisik dan faktor konversi per produk belum diberikan |
| Servis | Melayani perbaikan di toko dan kunjungan ke rumah pelanggan; ayah adalah mekanik yang menangani panggilan |
| Biaya servis | Ditentukan per pekerjaan sesuai kerusakan/kesulitan; tidak menggunakan tarif kunjungan/pemeriksaan tetap yang diasumsikan sistem |
| DP | Opsional; servis dapat diterima dengan atau tanpa uang muka |
| Cicilan/utang pelanggan | Tidak dibuat untuk cakupan awal, walaupun mungkin ada kebutuhan kelak |
| Garansi | Pelanggan membawa kembali barang jika ada masalah; belum ada ketentuan durasi atau rincian cakupan garansi |
| Internet/listrik | Menurut pengguna sudah aman |
| Pemeliharaan | Pengguna sendiri merawat aplikasi, menerima laporan backup gagal, dan membantu ayah saat ada masalah |
| Anggaran | Mengutamakan layanan gratis dengan target biaya hosting awal Rp0; localhost dapat digunakan pada awal pengembangan. Harga/anggaran perangkat fisik belum ditetapkan |
| Database | Pengguna mengusulkan Supabase agar data dapat diakses lewat internet oleh perangkat/pengguna yang berhak |
| Pembukaan | Direncanakan akhir September 2026; tanggal pasti belum diberikan |
| Kebijakan yang belum ditentukan | Durasi/cakupan garansi dan tempo supplier |

## 2. Implikasi langsung untuk revisi PRD

### PC dan HP

- Alur kasir utama dirancang untuk PC.
- Tampilan HP harus tetap mudah digunakan untuk membuka dan memantau informasi toko.
- Pemantauan dari luar toko merupakan kebutuhan; localhost saja tidak memenuhi kebutuhan ini tanpa jalur akses tambahan.
- Ayah dan developer memiliki akun masing-masing; aplikasi boleh diakses dari perangkat yang berbeda setelah autentikasi dan pemeriksaan izin.
- Ketentuan satu akun hanya satu perangkat pada PRD awal perlu direvisi agar ayah dapat memakai PC dan HP. Daftar sesi dan pencabutan akses perangkat menjadi usulan pengaman.
- Ayah menangani servis/kunjungan. Usulan peran karyawan: menjaga kasir dan menerima titipan ketika ayah pergi; rincian izin barang masuk/pengaturan belum ditetapkan.

### Kesederhanaan penggunaan

- Ayah dan karyawan menjadi pengguna utama untuk pengujian kemudahan penggunaan.
- Istilah, jumlah isian wajib, dan konfirmasi perlu mengikuti pekerjaan sehari-hari.
- Target kasir paralel dan dukungan perangkat pada PRD awal perlu disesuaikan dengan kebutuhan pembukaan, tanpa mengasumsikan dua orang berarti dua kasir aktif bersamaan.

### Satuan dan variasi barang

- Kuantitas pecahan untuk barang potongan merupakan kebutuhan nyata.
- Aturan konversi satuan harus ditulis sebelum implementasi; jumlah isi roll/pak tidak boleh diasumsikan sama untuk semua produk.
- Contoh uji: beli roll berisi 100 meter, jual 2,5 meter, stok tersisa 97,5 meter. Angka ini ilustrasi pengujian, bukan ketentuan seluruh produk.
- Variasi yang berbeda harus dapat dibedakan pada pencarian, struk, dan stok.
- Harga grosir, harga pelanggan langganan, dan tawar-menawar belum diputuskan.

### DP dan pembayaran

- Terima servis tanpa DP harus tetap menjadi alur yang sah.
- Bila ada DP, catat waktu, jumlah, metode pembayaran, dan tiket servis terkait.
- Pada pembayaran akhir, tampilkan total tagihan, DP yang sudah masuk, dan sisa bayar.
- DP servis tidak diperlakukan sebagai fitur cicilan atau kredit pelanggan.
- FR-CUS-03, laporan piutang, saldo piutang pelanggan, serta hak kasir mencatat piutang harus dikeluarkan dari cakupan awal revisi PRD.
- Pembelian supplier tempo belum diputuskan; usulan cakupan awal hanya pembelian lunas, sementara tempo ditunda sampai kebijakannya jelas.

### Servis kunjungan rumah

- PRD perlu mencakup dua jenis layanan: servis di toko dan kunjungan rumah.
- Nota titipan dan status Diambil hanya relevan bila alat benar-benar dititipkan/dibawa ke toko.
- Pekerjaan di rumah pelanggan memerlukan cara penyelesaian yang sesuai tanpa menandai alat seolah dititipkan.
- Ayah adalah mekanik untuk kunjungan; penugasan awal dapat terisi otomatis ke ayah tanpa memaksa pilihan berulang.
- Biaya diisi per pekerjaan setelah pemeriksaan atau sebagai estimasi. Belum ditentukan tidak sama dengan gratis: tampilkan “Belum ditentukan” sampai nominal dipastikan.
- Aturan pembatalan dan pengembalian DP belum dijawab secara khusus; jangan otomatis menganggap DP hangus atau selalu dikembalikan penuh.

## 3. Usulan desain untuk didiskusikan

Bagian ini berisi rekomendasi, bukan keputusan pengguna.

### Layar kerja toko

- Tindakan utama: Jual Barang, Terima Servis, Daftar Servis, Tutup Hari.
- Form singkat, tombol besar, angka total/kembalian menonjol, dan pencarian produk dengan spesifikasi pembeda.
- Data tambahan dilengkapi kemudian bila tidak diperlukan pada langkah awal.
- Simpan keranjang dan cegah pembayaran ganda akibat ketukan ulang.

### Pemantauan melalui HP

- Ringkasan penjualan dan penerimaan hari ini, servis aktif, kunjungan terjadwal, stok menipis, dan status backup.
- Pisahkan informasi bisnis yang dilihat pemilik dari tindakan teknis pemeliharaan.
- Usulan tambahan untuk ayah di lokasi pelanggan: melihat alamat/jadwal, mencatat hasil pemeriksaan, mengubah status, dan mencatat pembayaran. Pemantauan sudah diminta; rincian aksi ini masih rancangan yang diusulkan.
- HP menampilkan waktu pembaruan terakhir. Data yang belum terkirim saat koneksi putus tidak boleh ditampilkan seolah sudah diketahui seluruh perangkat.

### Kunjungan rumah sederhana

- Gunakan modul Servis yang sama dengan pilihan lokasi layanan.
- Data tambahan: alamat, nomor kontak, jadwal, petugas, keluhan, dan biaya kunjungan bila berlaku.
- Alur contoh: Dijadwalkan → Dikerjakan → Selesai, dengan pembatalan/jadwal ulang bila diperlukan.
- Jika alat kemudian dibawa ke toko, lanjutkan tiket yang sama dengan catatan perpindahan dan kondisi titipan.
- Bila spare part dibawa ke lokasi, bedakan dibawa, terpakai, dan dikembalikan; barang yang dibawa belum tentu terjual/terpakai.
- Pelacakan GPS langsung dan optimasi rute tidak diperlukan untuk rancangan awal yang diusulkan.

### Garansi praktis

- Cari servis lama melalui nama/nomor HP/nomor nota.
- Tambahkan tindakan Catat Keluhan Kembali yang membuat catatan terkait servis asal dan mempertahankan riwayat lama.
- Tentukan gratis atau berbayar setelah pemeriksaan/kebijakan toko; jangan otomatis menganggap semua keluhan ulang gratis.
- Durasi garansi tidak diisi dengan angka buatan sebelum kebijakan toko disepakati.

### Keandalan dan pilihan offline

- Karena internet/listrik dinyatakan aman, pertimbangkan operasional utama online dengan penyimpanan draf dan pemulihan saat koneksi terganggu.
- Ini usulan penyederhanaan; kebutuhan offline pada PRD v1.0 belum dibatalkan oleh pengguna.
- Jika offline penuh tetap diperlukan, masukkan aturan pembayaran, stok, sinkronisasi, dan sesi pengguna sejak rancangan awal.
- Backup otomatis dan uji pemulihan tetap menjadi rekomendasi sebelum penggunaan nyata. Laporan kegagalan diarahkan kepada pengguna sebagai pengelola aplikasi.

## 4. Hal yang belum diputuskan

1. Model scanner/printer dan anggaran perangkat fisik. Pembelian printer memerlukan uji kompatibilitas terhadap PC serta jalur cetak yang dipilih.
2. Detail tindakan yang tersedia di HP serta izin karyawan untuk penerimaan barang dan koreksi.
3. Ketelitian potongan nyata, faktor konversi tiap produk, harga grosir/tawar. Usulan aturan pembulatan ada pada bagian 7.
4. Kebijakan pembatalan/refund DP dan persetujuan perubahan estimasi.
5. Durasi/cakupan garansi dan tempo supplier.
6. Persetujuan arsitektur hosting serta cakupan offline. Supabase di internet belum membuat aplikasi localhost otomatis dapat diakses di luar toko.
7. Tanggal pasti pembukaan pada akhir September dan siapa yang menyiapkan katalog/stok awal.

Pertanyaan ini dapat dijawab bertahap; tidak semuanya perlu dibahas sekaligus.

## 5. Langkah berikutnya

Susun revisi PRD v1.1 berdasarkan keputusan yang telah dikonfirmasi, dengan usulan teknis pada bagian 6–8 tetap diberi status draft. Validasi contoh layar dan data barang nyata bersama ayah. Belum ada implementasi aplikasi, pembuatan akun layanan, atau deployment pada tahap diskusi ini.

## 6. Usulan arsitektur biaya awal Rp0

Status: rekomendasi untuk diputuskan; batas layanan diperiksa melalui dokumentasi resmi pada 15 September 2026.

### Komponen

| Komponen | Usulan | Tujuan |
|---|---|---|
| Antarmuka | React + Vite, responsif untuk PC/HP | Satu aplikasi untuk toko dan pemantauan |
| Hosting antarmuka | Cloudflare Pages Free dan alamat bawaan layanan | Aplikasi bisa dibuka lewat internet tanpa membeli domain |
| Data, akun, foto | Supabase Free: Postgres, Auth, Storage | Sumber data bersama dan akses berdasarkan akun |
| Transaksi kritis | Operasi tepercaya pada database/server | Memvalidasi harga, izin, pembayaran, dan stok bersama-sama |
| Pengembangan | Localhost dengan data uji terpisah | Mengembangkan dan menguji tanpa mengubah transaksi toko |
| Backup | Pekerjaan terjadwal yang dikelola developer | Cadangan database dan lampiran terpisah serta uji pemulihan |

Cloudflare menyediakan paket Pages Free dan SSL. Paket ini dapat menjadi kandidat hosting antarmuka; fitur server tambahan tetap mengikuti kuotanya sendiri. Sumber: [Cloudflare Pages](https://www.cloudflare.com/en-gb/developer-platform/products/pages/).

Supabase Free saat diperiksa mencakup database 500 MB dan penyimpanan berkas 1 GB, dengan batas penggunaan lain. Backup otomatis tidak termasuk; proyek dengan aktivitas rendah selama tujuh hari dapat dijeda. Target biaya layanan awal Rp0 berlaku selama memenuhi batas paket, bukan jaminan kapasitas atau biaya selamanya. Sumber: [Supabase Pricing](https://supabase.com/pricing) dan [Project Pausing](https://supabase.com/docs/guides/platform/free-project-pausing).

Foto perlu dikompresi dan pemakaian kapasitas dipantau. Ukuran katalog, jumlah transaksi, dan foto belum diketahui sehingga kecukupan paket belum terbukti melalui pengukuran.

### Perbedaan localhost dan hosting

- Localhost adalah alamat pada perangkat yang menjalankan aplikasi. HP yang membuka localhost akan mengarah ke HP itu sendiri.
- Server pengembangan dapat dibuka lewat alamat jaringan PC jika dikonfigurasi, tetapi itu tidak dengan sendirinya menyediakan akses dari luar toko.
- Menyimpan database di Supabase menyediakan sisi data online. Berkas aplikasi tetap memerlukan hosting/jalur akses agar dapat dibuka di HP dari luar toko.
- Dengan antarmuka dan data di cloud, pemantauan HP tidak bergantung pada PC toko menyala. Transaksi yang belum tersimpan online tetap tidak akan terlihat di HP.
- Usulan ini mengganti kebutuhan backend Express/Prisma/Socket.io terpisah dari PRD awal dengan layanan Supabase dan operasi database/server yang sesuai. Belum merupakan perubahan stack yang disetujui pengguna.

### Akses dan transaksi

- Akun aplikasi disediakan untuk ayah, karyawan, dan developer sesuai izin; pendaftaran publik tidak diperlukan.
- Gunakan Supabase Auth dan kebijakan akses data (RLS). Menyembunyikan tombol pada tampilan saja tidak membatasi akses database.
- Publishable key dapat berada di aplikasi dengan izin yang benar; secret key tetap pada komponen tepercaya. Sumber: [Supabase API Keys](https://supabase.com/docs/guides/getting-started/api-keys) dan [Securing your API](https://supabase.com/docs/guides/api/securing-your-api).
- Proses penjualan memvalidasi harga/otorisasi diskon dan menyimpan nota, pembayaran, serta mutasi stok sebagai satu operasi: seluruhnya berhasil atau seluruhnya dibatalkan.
- Pengiriman ulang menggunakan identitas transaksi yang sama agar tidak membuat penjualan ganda. Status hasil yang belum pasti harus diperiksa sebelum mencoba transaksi baru.
- Foto pelanggan/servis memakai penyimpanan privat dan izin akses yang sesuai.
- Developer menguji dengan data contoh terpisah dan tidak menjadikan database produksi tempat percobaan perubahan.

### Backup pada layanan gratis

Supabase menyarankan ekspor rutin dan cadangan di luar layanan untuk paket Free. Backup database tidak menyertakan berkas foto pada Storage. Sumber: [Database Backups](https://supabase.com/docs/guides/platform/backups).

Usulan: pencadangan terjadwal database dan foto ke lokasi terpisah yang aksesnya dikelola developer. Bila dijalankan dari PC, jadwal harus menangani PC mati, kegagalan, dan proses yang terlewat. Tampilkan waktu backup sukses terakhir, bukan hanya status pekerjaan sudah dijadwalkan. Lakukan uji pemulihan sebelum pembukaan. Media/tujuan penyimpanan dan sasaran pemulihan belum dipilih; ekspor Excel saja tidak dianggap backup lengkap.

## 7. Draft aturan perhitungan yang dapat diuji

Status: rancangan awal untuk ditinjau menggunakan contoh barang nyata. Keinginan pengguna akan hitungan sempurna diterjemahkan menjadi aturan dan bukti pengujian; belum ada implementasi yang dinyatakan bebas kesalahan.

### Satuan dan kuantitas

1. Setiap SKU memiliki satuan stok dasar, misalnya meter atau pcs. Setiap variasi yang berbeda memiliki identitas stok sendiri.
2. Konversi pembelian/penjualan ditentukan per produk: contoh roll A = 100 meter, roll B = 50 meter. Faktor tidak diasumsikan global.
3. Usulan kemampuan sistem: hingga tiga angka desimal untuk kuantitas meter, dengan kelipatan jual per produk seperti 0,1 m atau 0,01 m. Nilai nyata mengikuti ukuran yang dapat diukur toko; tiga desimal bukan janji ketelitian fisik.
4. Barang pcs menggunakan bilangan bulat kecuali satuan produknya memang berbeda. Kuantitas yang tidak sesuai ketelitian/kelipatan ditolak dengan pesan jelas, tidak diam-diam dibulatkan.
5. Hitungan memakai desimal eksak atau satuan terkecil berupa bilangan bulat yang didefinisikan, dengan aturan pembulatan eksplisit untuk pembagian; hindari akumulasi pecahan biner pada uang/stok.
6. Simpan satuan, faktor konversi, harga, dan biaya modal terkait transaksi. Mengubah pengaturan tidak mengubah transaksi yang sudah selesai.
7. Untuk penjualan roll utuh, ketersediaan roll utuh perlu dibedakan dari sisa potongan bila keduanya dijual. Total meter saja belum cukup.

### Harga, diskon, dan pembulatan

1. Tampilkan harga per satuan yang dijual. Harga roll boleh berbeda dari harga meter dikalikan isi jika ditetapkan pemilik; konversi stok tetap sama.
2. Usulan nominal tagihan akhir dalam Rupiah bulat. Subtotal baris dihitung dari kuantitas × harga, dikurangi diskon item, lalu dibulatkan setengah ke atas ke Rp1. Aturan ini draft, belum keputusan pengguna.
3. Diskon nominal item diartikan sebagai diskon seluruh baris dan diberi label demikian. Diskon persen dihitung dari nilai kuantitas × harga baris. Diskon tidak boleh membuat nilai baris negatif.
4. Diskon transaksi diterapkan setelah diskon item. Untuk laporan/retur, bagikan secara proporsional terhadap nilai bersih baris; selisih pembulatan dibagikan dengan urutan sisa terbesar dan urutan baris sebagai pemecah seri. Jumlah alokasi harus persis sama dengan diskon transaksi.
5. Total nota = jumlah baris setelah diskon item − diskon transaksi. Nilai yang ditampilkan, disimpan, dicetak, dan dilaporkan harus sama.
6. Potongan karena tawar/pembulatan ke Rp500 atau Rp1.000, jika nanti diperbolehkan, menjadi diskon/penyesuaian yang terlihat dan tercatat; tidak dilakukan diam-diam.
7. Biaya modal memakai ketelitian tersendiri. Kebijakan pembagian/penilaian modal ditetapkan sebelum laporan laba diterima; pembulatan tagihan pelanggan tidak digunakan untuk membulatkan modal per unit secara sembarang.
8. Retur memakai harga serta alokasi diskon transaksi asal. Retur sebagian memperhitungkan retur sebelumnya; sisa pembulatan diselesaikan pada retur terakhir sehingga total refund tidak melampaui nilai asal.

### Stok, pembayaran, dan servis

- Scan pada kasir menambah barang ke keranjang, scan pada barang masuk memilih barang penerimaan. Stok berubah setelah tindakan terkait dikonfirmasi, bukan setiap kali kode terbaca.
- Scan kabel meminta panjang; barcode produk tidak mengetahui panjang potongan yang diminta pelanggan.
- Stok tidak boleh negatif tanpa kebijakan pengecualian yang eksplisit. Harga dan stok diverifikasi kembali ketika transaksi diselesaikan.
- DP dihitung sebagai pembayaran terkait tiket. Jika total akhir lebih kecil dari DP, tampilkan kelebihan pembayaran dan proses refund berdasarkan keputusan pemilik.
- Lunas tidak sama dengan alat diserahkan. Pembayaran servis tidak mengurangi lagi spare part yang sudah dicatat terpakai.
- Pembatalan, retur, dan koreksi tetap menyimpan catatan asal dan tindakan penyesuaiannya.

### Contoh bukti penerimaan

| Kasus | Hasil yang diharapkan |
|---|---|
| Kabel 100 m dijual 2,5 m dengan harga Rp7.500/m | Subtotal Rp18.750, stok tersisa 97,5 m |
| Stok 1 m dijual 0,1 m sebanyak 10 transaksi | Sisa tepat 0 m |
| Barang pcs dimasukkan 1,5 | Ditolak dengan penjelasan bahwa kuantitas harus bulat |
| Nilai baris Rp10.001 diberi diskon 10% | Nilai Rp9.000,9 dibulatkan menjadi Rp9.001 menurut draft aturan |
| DP Rp50.000 dan tagihan final Rp150.000 | Sisa bayar Rp100.000 |
| DP Rp100.000 dan tagihan final Rp80.000 | Kelebihan Rp20.000 terlihat dan memerlukan penyelesaian refund |
| Retur seluruh barang dalam beberapa kali retur | Jumlah refund tepat sama dengan nilai neto yang memang dapat dikembalikan |
| Dua perangkat mencoba menjual stok terakhir bersamaan | Hanya transaksi yang memenuhi stok yang berhasil; tidak ada stok negatif/pembayaran tercatat ganda |

## 8. Usulan cakupan menjelang pembukaan akhir September

Jendela waktu sekitar dua minggu dari tanggal diskusi. Ini target bisnis, bukan jaminan seluruh PRD awal selesai pada tanggal tersebut.

Prioritas pembukaan yang diusulkan:

1. Login, akun/izin, katalog, satuan/variasi, stok awal, dan pencarian/scan barcode.
2. Penjualan, pembayaran, struk/cetak ulang, barang masuk sederhana, koreksi/retur dasar, serta audit perubahan penting.
3. Servis toko/kunjungan, estimasi dan biaya aktual, spare part, DP/pelunasan, serta penyerahan bila dititipkan.
4. Pemantauan HP, laporan harian sederhana, kas buka/tutup, backup dan uji pemulihan.
5. Uji alur bersama ayah/karyawan dan uji perangkat cetak sebelum digunakan dengan data transaksi nyata.

Usulan ditunda: OCR teks, cicilan/piutang pelanggan, tempo supplier yang belum diputuskan, garansi dengan aturan otomatis, grafik lanjutan, dan PO kompleks. Offline penuh tetap keputusan terbuka; bila ditunda, versi awal harus secara jelas memerlukan koneksi untuk finalisasi transaksi, menyimpan draf, dan tidak menyatakan pembayaran/transaksi berhasil saat server belum mengonfirmasi. Perubahan ini perlu dicantumkan sebagai perubahan cakupan terhadap PRD v1.0.

Syarat siap pakai: hitungan dan stok lulus skenario penerimaan, izin akun diuji, tidak ada duplikasi saat pengiriman ulang, struk dapat digunakan pada perangkat terpilih, data dapat dipulihkan, dan ayah/karyawan mampu menjalankan tugas utama. Jika belum terpenuhi, batasi peluncuran pada uji coba terkontrol, bukan menganggap tanggal sebagai bukti siap.
