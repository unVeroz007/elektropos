# 02 — Aturan Bisnis dan Perhitungan

Baseline 1.1. Acuan normatif rumus dan invariant; PRD menjelaskan kebutuhan, dokumen ini menentukan hasil. Default terkait: [register keputusan](01-SCOPE-DECISIONS.md). Nama entitas: [model data](05-DATA-MODEL.md).

## BR-01 — Representasi angka dan waktu

- API menerima/mengembalikan uang, persentase dan kuantitas sebagai string desimal kanonik: `"2.500"`, `"18750"`; pemisah desimal titik, tanpa pemisah ribuan.
- UI Indonesia menerima input koma desimal pada kuantitas lalu menormalisasi. Input ambigu seperti `1.000,5` ditangani parser locale eksplisit; jangan sekadar menghapus semua titik pada semua jenis input.
- Simpan qty/factor `numeric(18,3)`, harga satuan dan nilai modal `numeric(24,6)`, nominal tagihan/pembayaran IDR `numeric(20,0)`, persen `numeric(7,4)`. Validasi rentang bisnis lebih sempit sebelum database membulatkan/coerce input.
- Tolak NaN, Infinity, negatif yang tidak sesuai jenis kejadian, pecahan berlebih, overflow, faktor nol, qty nol pada baris barang, persen di luar 0–100. Jangan memakai float/JavaScript Number untuk aritmetika uang.
- Decimal.js dan NUMERIC mengikuti operasi serta pembulatan yang sama. Presisi Decimal.js minimal 50 significant digits; pembagian menggunakan presisi tersebut sebelum quantize pada batas yang disebutkan. Properti persamaan frontend/server diuji dengan vektor bersama.
- Untuk pembagian yang menentukan uang/modal/alokasi, hasil akhir ditentukan dengan rasio bilangan bulat dan quotient/remainder eksak, bukan mengandalkan presisi default pembagian NUMERIC. Untuk rasio positif n/d yang dibulatkan p desimal: skalakan input ke integer, hitung quotient/remainder dari n×10^p dibagi d, tambah1 jika 2×remainder>=d. Terapkan tanda setelah pembulatan jika diperlukan. Ini mencegah perbedaan di batas setengah antara client dan database.
- Batas validasi R1 (konstanta bersama, bukan nilai contoh): qty_input dan qty_base per baris <=999999999.999, factor<=1000000.000, harga satuan<=999999999999.999999, nominal pembayaran/total invoice<=9999999999999999. Semua perkalian/penjumlahan diperiksa sebelum cast ke tipe kolom. Saldo agregat memakai kapasitas kolom dan pemeriksaan overflow; tidak dibatasi diam-diam dengan memotong digit.
- Nilai harga mentah dapat enam desimal; tagihan/pembayaran yang diterima pelanggan selalu Rupiah bulat. Pemformatan tampilan tidak mengubah nilai tersimpan.
- Waktu kejadian bisnis memakai server `timestamptz`; tampilkan Asia/Jakarta. Filter tanggal menggunakan `[awal hari, awal hari setelah tanggal akhir)` dalam zona toko, lalu dikonversi ke UTC. Jangan mengasumsikan tanggal browser benar.
- `created_at`, waktu posting, waktu pembayaran, waktu kunjungan dan tanggal nota supplier adalah konsep berbeda. Tidak ada backdate posting uang/stok pada R1; tanggal nota sumber boleh dicatat sebagai informasi.

## BR-02 — Identitas produk dan satuan

- Satu SKU untuk satu variasi yang memiliki stok/harga tersendiri. Barcode text mempertahankan nol di depan. SKU unik case-insensitive; barcode nonkosong unik exact setelah trim.
- Satu produk punya satu satuan stok dasar. Opsi kemasan punya faktor ke satuan dasar, harga jual, dan langkah qty jual. Contoh roll 100 m dan roll 50 m adalah opsi berbeda, tidak faktor global.
- `qty_base = qty_sell × conversion_factor`. Hasil harus dapat direpresentasikan dengan <=3 desimal dan memenuhi langkah stok. Tolak jika membutuhkan pecahan lebih halus; jangan diam-diam membulatkan stok.
- `qty_sell / sale_step` harus bilangan bulat eksak. Barang pcs step=1. Meter boleh step=0.1/0.01/0.001 sesuai konfigurasi fisik toko.
- Tampilan selalu menyebut satuan harga dan kuantitas; contoh `2,5 m × Rp7.500/m`, bukan angka 2,5 tanpa satuan.
- Satuan dasar yang sudah digunakan tidak berubah. Perubahan faktor menghasilkan versi opsi baru; transaksi menyimpan faktor/nama opsi snapshot.
- Barang dengan barcode kemasan tertentu dapat memakai mapping barcode->opsi satuan; default SKU barcode->satuan jual default. Alias harus tidak ambigu.

## BR-03 — Roll dan kontinuitas potongan

- Produk dengan `track_segments=true` memiliki posisi fisik per roll/potongan kontinu, label internal, kapasitas awal, panjang tersisa, dan status segel.
- Roll baru 100 m menjadi satu posisi panjang 100, segel utuh. Potong 2,5 m dari posisi itu menyisakan 97,5 m dan membuka segel.
- Permintaan satu potongan 10 m memerlukan satu posisi dengan sisa >=10 m. Sisa 6 m dan 4 m tidak dianggap memenuhi satu potongan 10 m. Jika pelanggan menerima dua potongan, catat dua baris/segment allocation eksplisit.
- Penjualan satu roll utuh memerlukan posisi segel utuh dengan kapasitas yang sesuai. Meter total yang cukup tidak membuktikan ada roll utuh.
- "Roll utuh" adalah tanda eksplisit pada satuan jual (`whole_roll`), bukan tebakan dari isi satuan. Satuan berisi lebih dari satu tanpa tanda itu (mis. ikat 10 m) dijual sebagai potongan `qty × isi` dari satu posisi (DEC-U04).
- Potongan yang dikembalikan adalah posisi baru, tidak disambungkan secara sistem ke roll asal. Retur roll boleh kembali bersegel hanya setelah pemeriksaan owner.
- Untuk qty jual lebih dari satu roll, sediakan satu posisi per roll. Pembelian yang berisi banyak roll dapat menghasilkan posisi berlabel otomatis, diperiksa saat penerimaan.
- Posisi dapat berpindah SHOP/FIELD_FATHER. Posisi fisik yang sama tidak dapat berada di dua tempat; transfer sebagian menghasilkan posisi baru pada tujuan dan mengurangi posisi asal.

## BR-04 — Harga dan diskon

Untuk setiap baris i, hitung dalam desimal eksak:

1. `G_i = qty_sell_i × unit_price_i` (nilai kotor, belum dibulatkan).
2. Diskon item `D_i`: nominal berlaku untuk seluruh baris, atau `G_i × percent / 100`. Pilih satu mode per baris.
3. Validasi `0 <= D_i <= G_i`. Tidak menggunakan dua diskon item sekaligus.
4. `B_i = round_half_up(G_i - D_i, 0)` (baris bersih Rupiah).
5. `S = sum(B_i)`.
6. Diskon nota `D`: nominal bulat atau `round_half_up(S × percent / 100, 0)`; `0 <= D <= S`.
7. Total `T = S - D`. Semua nilai T/B_i/D yang disimpan, dicetak dan dilaporkan identik.

Owner boleh menetapkan diskon. Staff tidak mengubah harga/menyelundupkan diskon melalui API. Pembayaran gratis/baris neto nol hanya melalui diskon 100% oleh owner dengan alasan; harga katalog positif dan modal tetap dihitung. Untuk jasa gratis, owner secara eksplisit menetapkan nilai nol.

Perubahan harga server sejak keranjang dibuat menghasilkan PRICE_CHANGED dengan nilai baru, bukan penerimaan diam-diam. User meninjau ulang lalu mengirim operasi baru. Sebelum itu tidak ada uang/stok diposting.

### Alokasi diskon nota

Jika S>0: hitung bobot eksak `w_i = D × B_i / S`; alokasi awal `a_i = floor(w_i)`; sisa `r = D - sum(a_i)` Rupiah. Tambah Rp1 kepada r baris dengan sisa pecahan terbesar; seri dipecahkan dengan `line_no` naik. Baris B_i=0 tidak memperoleh alokasi positif. `N_i = B_i - a_i`.

Implementasi eksak: karena D/B_i/S adalah Rupiah bulat, gunakan pembagian integer `div(D*B_i,S)` untuk alokasi awal dan `mod(D*B_i,S)` untuk urutan sisa. Seluruh penyebut sama, sehingga tidak perlu membandingkan pecahan hasil pembagian yang sudah dibulatkan.

Jika S=0: D wajib 0, seluruh a_i dan N_i=0. Invariant: `sum(a_i)=D`, `sum(N_i)=T`, seluruh N_i>=0. Simpan alokasi, jangan hitung ulang memakai harga baru saat retur.

## BR-05 — Modal dan lot

- Satu lot mewakili satu baris penerimaan/stok awal dengan total qty dasar dan biaya perolehan total. Biaya perolehan diketahui, bukan modal nol sebagai placeholder.
- Pada penerimaan berbayar R1, total biaya per baris diinput dalam Rupiah bulat; jumlahnya sama dengan total pembayaran pembelian. Penyimpanan enam desimal menampung alokasi modal selanjutnya, bukan izin membuat pembayaran supplier pecahan Rupiah. Modal nol hanya sah jika benar-benar perolehan gratis dan owner mencatat alasannya.
- Penerimaan boleh mengalokasikan ongkos/diskon pembelian pada item; total biaya lot harus sama dengan biaya persediaan pada nota. R1 input sederhana: owner memasukkan total biaya per baris yang sudah disesuaikan; jelaskan agar ongkos tidak dihitung dua kali.
- Barang bulk keluar dari lot paling awal diterima yang tersedia pada lokasi/kondisi layak jual, urutan `(posted_at, lot_id, position_id)`. Produk roll menggunakan posisi fisik yang dipilih, sehingga modal mengikuti lot posisi tersebut. Jangan mengklaim FIFO ketat pada pemilihan roll fisik eksplisit.
- Setiap lot menyimpan qty dan nilai modal tersisa. Alokasi keluar q dari lot dengan sisa Q,V: jika q<Q maka `C = round_half_up(V × q / Q, 6)`; jika q=Q maka C=V. Kurangi q dan C bersama-sama. Alokasi banyak posisi pada lot yang sama diproses dalam urutan deterministik.
- Alokasi penjualan/part menyimpan qty_base dan C yang sebenarnya, bukan hanya harga beli produk terakhir. Nilai tersisa tidak negatif; qty nol harus nilai nol.
- Return/reversal memulihkan bagian modal asal C yang dialokasikan secara kumulatif menurut BR-08, beserta qty ke lot asal. Modal penjualan lama tetap tidak berubah oleh pembelian baru.
- Perpindahan lokasi atau kondisi DAMAGED tidak menghapus nilai modal: stok rusak tetap dicatat terpisah, tidak bisa dijual. Disposal mengurangi modal persediaan dan mencatat kerugian stok tersendiri.
- Semua modal menggunakan enam desimal sampai pelaporan. Laporan membulatkan jumlah agregat, bukan menjumlahkan nilai modal per baris yang sudah dibulatkan ke Rupiah.

## BR-06 — Stok dan koreksi

- Sumber kebenaran: ledger mutasi dan alokasi. Qty posisi serta saldo lot adalah ringkasan yang diperbarui atomik dan harus dapat direkonsiliasi.
- Stok toko tersedia = jumlah posisi SHOP, kondisi SALEABLE, qty>0. Stok FIELD_FATHER dan DAMAGED ditampilkan terpisah. Draf tidak mereservasi.
- Posisi/lot/product yang akan berubah dikunci sesuai urutan global kontrak server. Verifikasi stok dilakukan setelah lock. Tidak ada bypass stok negatif oleh owner.
- Penerimaan, penjualan, pemakaian part, retur, transfer, koreksi dan disposal merupakan jenis kejadian berbeda. Transfer memiliki sisi keluar/masuk qty sama dan biaya bersih nol.
- Penyesuaian negatif memakai alokasi modal posisi sumber. Penyesuaian positif membutuhkan modal yang dikonfirmasi dan menjadi lot koreksi baru; tidak menyamar sebagai pembelian.
- Stok opname terbatas produk/posisi terpilih. Baca version lalu hitung; posting dengan version yang sudah berubah ditolak. Tidak memblokir seluruh toko selama menghitung.
- Koreksi penerimaan posted menggunakan dokumen koreksi tertaut. Koreksi qty tidak otomatis memulihkan pembayaran supplier. Jika masalah menyangkut biaya lot yang sudah dialokasikan ke penjualan, owner/maintainer perlu prosedur koreksi biaya terdokumentasi; jangan mengedit COGS historis diam-diam. Retur supplier formal di luar R1.

## BR-07 — Penjualan dan pembayaran

- Penjualan biasa dibuat sebagai invoice SALE final serta satu receipt pembayaran. Pelanggan opsional. Satu metode: CASH, TRANSFER, QRIS.
- Untuk CASH: `tendered >= T`; `change = tendered - T`; receipt.amount=T, cash movement=T. Jangan menghitung tendered sebagai omzet atau uang bersih masuk. T=0 memakai invoice tanpa receipt dan alasan owner.
- TRANSFER/QRIS: amount=T, change=0, confirmation oleh petugas wajib. Referensi pembayaran opsional; jangan klaim validasi bank otomatis.
- Tidak ada pembayaran barang kurang dari total, pembayaran campuran, atau sisa utang. Metode non-tunai tidak mengubah saldo cashbox.
- Kuitansi servis merupakan payment event terpisah dari invoice. Tanpa uang muka: pembayaran servis diterima setelah invoice SERVICE dibuat, boleh beberapa kali (cicilan) dengan amount <= sisa tagihan (DEC-U04).
- Pembayaran servis tunai: tendered>=amount dan change=tendered-amount; cash inflow=amount. Transfer/QRIS tanpa kembalian dan wajib konfirmasi petugas.
- `net_received = sum(incoming) - sum(outgoing_refunds)` pada target tagihan/tiket. Jangan kurangi transfer antar cashbox karena bukan refund pelanggan.
- Setiap refund dialokasikan ke receipt asal; total refund terhadap receipt tidak melebihi amount. Refund tidak disimpan sebagai nominal negatif pada receipt asli.
- Salah metode bayar yang sudah posted dikoreksi dengan reversal pembayaran dan catatan pengganti terotorisasi dalam satu operasi; tidak mengubah invoice/stok. Cash session tertutup memakai koreksi saat ini, tidak mengubah riwayat tutup.
- Koreksi memakai purpose PAYMENT_REVERSAL dan PAYMENT_REPLACEMENT, keduanya bertaut original_payment_id. Pasangan ini ikut net_received tetapi bukan penerimaan/refund pelanggan baru. Laporan metode menampilkan penyesuaian negatif metode lama dan positif metode baru pada tanggal koreksi; penerimaan pelanggan asli tidak dihapus atau dihitung dua kali. Refund berikutnya mengacu receipt pengganti yang masih mempunyai saldo.

## BR-08 — Retur dan pembulatan parsial

- Retur mengacu invoice_item dan alokasi stok asal. Total qty retur kumulatif <= qty_base terjual. Owner memilih kondisi barang dan alasan. Barang yang tidak benar-benar kembali tidak menambah stok.
- Untuk baris dengan neto N dan qty Q, hak refund kumulatif setelah qty retur x: `H(x)=round_half_up(N × x / Q,0)`, dengan H(Q)=N. Refund kejadian saat ini = H(x_baru)-H(x_lama). Simpan x dan alokasinya agar urutan retur tidak menggandakan nilai.
- Modal yang dipulihkan dihitung pada alokasi asal yang dikembalikan: fungsi kumulatif serupa menggunakan enam desimal dan mengembalikan C tepat saat seluruh qty alokasi kembali. Jika beberapa lot, owner memilih alokasi fisik bila diketahui, selain itu gunakan urutan alokasi asal deterministik yang ditampilkan.
- Invoice tetap utuh. Credit note dan credit note items mencatat pengurangan pendapatan/COGS; refund adalah kejadian uang terpisah yang ditautkan. Untuk retur SALE R1, posting credit note, stok kembali dan refund dilakukan atomik.
- Nota T=0 dapat diretur tanpa uang kembali. Kembalian tunai awal bukan bagian yang bisa direfund lagi.
- Retur rusak memulihkan qty/modal ke DAMAGED, membalik COGS penjualan sesuai note; disposal berikutnya mencatat kerugian terpisah. Laporan laba kotor tidak mencakup kerugian disposal dan harus menyatakannya.
- Penukaran = retur + penjualan baru terkait. Jangan sekadar mengganti product_id pada invoice lama. Jika bagian kedua gagal, bagian pertama tetap terlihat sebagai retur sah, bukan transaksi tersembunyi.

## BR-09 — Servis, persetujuan dan biaya

- Estimasi tidak menghasilkan pendapatan, pembayaran, atau pengurangan stok. Estimasi range untuk informasi; persetujuan menyimpan batas maksimal bulat, lingkup kerja, revisi dan waktu/cara persetujuan.
- Pemeriksaan awal boleh mendahului estimasi perbaikan. Biaya pemeriksaan/kunjungan yang hendak ditagih harus disepakati; jangan menjadikan pemeriksaan awal izin biaya tak terbatas.
- Part baru mengurangi stok saat USE dikonfirmasi. Daftar rencana part tidak mengurangi stok. Part yang dibawa tetap stok FIELD_FATHER.
- Invoice SERVICE final dibuat satu kali per tiket terminal. Baris jasa/kunjungan/diagnosis dan part memiliki snapshot deskripsi/harga/kuantitas. Total final tidak melebihi batas yang disetujui; kelebihan meminta revisi persetujuan.
- Setiap USE bersih yang belum direverse penuh mempunyai satu baris PART tertaut pada invoice; part yang tidak dibebankan ditampilkan bernilai nol. Jangan menautkan satu pemakaian pada beberapa baris invoice atau menyembunyikan sumber cost sehingga tidak bisa dikoreksi.
- Biaya part yang benar-benar terpakai namun tidak ditagihkan tetap masuk cost allocations tiket. Finalisasi invoice mengakui biaya bersih pemakaian tersebut sekali, termasuk ketika pekerjaan dibatalkan/tidak berhasil atau tagihan nol.
- Cost allocations part dan invoice_item tidak boleh menjadi dua sumber COGS terpisah. Hubungkan pemakaian ke invoice sekali; invoice final tidak mengubah stok part.
- Ticket dengan status batal/tidak bisa diperbaiki tetap memerlukan invoice penyelesaian, termasuk invoice total 0 dengan keputusan owner.
- Pengecualian persetujuan biaya: jika tidak ada pekerjaan berbayar yang dikerjakan/disepakati dan owner membebaskan seluruh biaya pada penyelesaian batal/tidak berhasil, invoice0 boleh tanpa approved_estimate_revision dengan alasan pembebasan wajib. Ini bukan izin memulai WORKING tanpa persetujuan atau menagih biaya yang belum disetujui.
- Sesudah invoice final, perubahan biaya melalui credit note/koreksi tertaut. Menambah pekerjaan baru menjadi tiket terkait; tidak mengedit diam-diam invoice final.

## BR-10 — Pembayaran, cicilan, piutang dan refund servis

- Tidak ada uang muka (DEC-U04). Sebelum invoice final pembayaran ditolak; layar menampilkan `tagihan belum dibuat`. Uang muka yang tercatat sebelum keputusan ini tetap dihitung sebagai penerimaan tiket dan dapat dikembalikan bila batal.
- Sesudah final: `outstanding = max(invoice_net - net_received,0)` dan `refund_due = max(net_received - invoice_net,0)`. Invoice_net mencakup credit note yang sah.
- Status derived: UNPRICED sebelum final; UNPAID/PARTIAL/PAID/REFUND_DUE sesudah final. Invoice 0 dengan net_received 0 menjadi PAID setelah owner menetapkan nol secara eksplisit.
- Cicilan: setiap pembayaran 0 < amount <= outstanding; melebihi sisa ditolak. Status PARTIAL sampai lunas.
- Penyelesaian batal: owner menetapkan biaya yang disepakati (boleh 0 dengan alasan pembebasan) dan memfinalisasi tagihan. Kelebihan bayar (mis. setelah credit note) wajib dikembalikan; tidak ada uang yang otomatis hangus.
- Refund akibat pengurangan tagihan final memerlukan credit note terlebih dahulu; jangan menghitung dua kali penurunan pendapatan.
- Kuitansi pembayaran/cicilan/pelunasan memuat tiket, nilai diterima, total tagihan, sisa/refund_due, metode, petugas dan waktu.
- Layanan **selesai** (`completed_at`) saat alat diserahkan atau kunjungan ditutup; tiket **ditutup** (`closed_at`) hanya bila outstanding=0 dan refund_due=0. Menyelesaikan layanan dengan outstanding>0 hanya boleh oleh owner dengan catatan kapan dibayar; sisa itu menjadi **piutang servis** yang tampil di beranda/daftar sampai lunas. refund_due>0 selalu menahan penyelesaian.
- Setelah layanan selesai, pekerjaan/part/estimasi/custody tidak dapat diubah; pembayaran, credit note dan refund tetap dapat dicatat. Tiket tertutup otomatis saat pembayaran/credit note/refund membuat tagihan pas lunas.

## BR-11 — Penguasaan alat dan pengulangan servis

- `custody_location` CUSTOMER/SHOP/FATHER adalah keberadaan fisik, berbeda dari service_location STORE/ONSITE.
- Pembayaran tidak mengubah custody. Handover oleh petugas berizin mencatat penerima/waktu dan memindahkan ke CUSTOMER.
- Kunjungan tanpa membawa alat tidak membutuhkan handover. Close setelah syarat terminal/tagihan terpenuhi dan custody CUSTOMER; sisa tagihan mengikuti BR-10 (piutang atas keputusan owner).
- Label belum diambil berlaku pada terminal work_status dengan custody SHOP/FATHER, termasuk batal/tidak bisa diperbaiki; bukan sekadar tagihan belum lunas.
- Keluhan kembali membuat tiket baru dengan parent_ticket_id. Tidak mengubah hasil pekerjaan lama. Garansi gratis hanya keputusan owner per kasus.

## BR-12 — Kas operasional

- Cashbox SHOP_DRAWER dan FATHER_WALLET; satu sesi OPEN per cashbox. Staff hanya dapat menerima/mengeluarkan uang sesuai izin pada SHOP_DRAWER; owner dapat memakai keduanya.
- Posting pembayaran tunai wajib mengacu sesi cashbox terbuka milik lokasi penerima. Pembayaran non-tunai tidak membutuhkan sesi kas.
- Pengeluaran tunai (refund/pembelian/transfer/biaya) tidak boleh melebihi saldo sistem cashbox setelah lock; lakukan penambahan/transfer dana sah lebih dahulu atau pilih metode non-tunai yang benar-benar digunakan. Cek saldo aplikasi bukan bukti jumlah uang fisik; operator tetap memeriksa uang nyata.
- Saldo seharusnya = saldo buka + semua cash inflow - semua cash outflow. Pembelian tunai, refund, biaya, penarikan dan transfer keluar mengurangi; pembayaran pelanggan tunai (termasuk cicilan servis) menambah.
- Transfer wallet->drawer membutuhkan dua sesi terbuka dan menghasilkan dua cash movements satu grup, atomik, total bersih nol. Tidak menambah omzet atau penerimaan pelanggan.
- Sesi memiliki tanggal operasional saat dibuka. Penutupan setelah lewat tengah malam tetap menutup sesi yang sama; laporan periode pembayaran memakai occurred_at lokal, laporan sesi memakai session_id. Jangan mencampurkan keduanya.
- Staff dapat mencatat hitungan tutup drawer; owner meninjau selisih. `variance = counted - expected`. Penutupan tidak otomatis menambahkan adjustment atau membuat expected menjadi counted.
- Pembukaan sesi berikutnya menggunakan saldo fisik yang dikonfirmasi; selisih lama tetap dilaporkan. Rekonsiliasi owner diberi alasan, tidak memodifikasi sesi closed.

## BR-13 — Laporan

| Ukuran | Definisi |
|---|---|
| Penjualan barang neto | Invoice SALE posted pada periode dikurangi credit note SALE posted pada periode |
| Nilai jasa/servis neto | Invoice SERVICE posted pada periode dikurangi credit note SERVICE posted pada periode |
| Penerimaan pelanggan | Receipt SALE/SERVICE incoming berdasarkan waktu pembayaran; uang muka lama (sebelum tagihan) dipisah |
| Refund pelanggan | Payment outgoing kategori refund berdasarkan waktu refund |
| Penerimaan bersih | Penerimaan pelanggan - refund pelanggan; bukan omzet dan bukan kas laci |
| Koreksi metode pembayaran | Pasangan PAYMENT_REVERSAL/REPLACEMENT pada periode koreksi, net total nol; dipisahkan dari penerimaan/refund pelanggan nyata |
| COGS barang | Modal alokasi SALE pada posting invoice dikurangi cost reversal credit note pada periode |
| COGS servis | Modal pemakaian bersih yang diakui saat invoice SERVICE final, dikurangi reversal sah terkait |
| Laba kotor | Nilai invoice neto - COGS neto; sebelum biaya operasional/disposal/gaji/pajak |
| Kas per pemegang | Persamaan BR-12, termasuk arus nonpenjualan sesuai cashbox |
| Servis aktif | Belum closed_at; rincikan status kerja, pembayaran dan custody |
| Belum diambil | Kondisi BR-11, walau sudah lunas |

Retur transaksi bulan lalu yang diposting bulan ini memengaruhi periode bulan ini; riwayat bulan lalu tidak ditulis ulang. Ringkasan boleh negatif untuk periode yang dominan retur. Hitung dalam desimal lalu bulatkan total tampilan, tetap dapat ditelusuri ke detail.

## BR-14 — Audit dan bukti invariant

Perintah berhasil menghasilkan audit beraktor dari auth, waktu server, entity/ref, operation_id, tipe, alasan dan perubahan penting yang sudah disaring. Draf UI tidak ditulis ke audit setiap ketikan. Tidak menyimpan password/token atau seluruh payload sensitif.

Setiap release harus membuktikan: ledger stock=qty posisi, saldo lot=jumlah stock qty/value terkait, sum line net=invoice total, alokasi diskon=discount total, refund<=receipt/asli, kas sesuai movements, dan sumber COGS tunggal. [Kasus penerimaan](07-TEST-ACCEPTANCE.md) adalah bukti wajib, bukan lampiran opsional.
