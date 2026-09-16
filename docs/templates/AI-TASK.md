# Template Tugas Implementasi AI

Gunakan bersama [AGENTS](../../AGENTS.md) dan [rencana implementasi](../09-IMPLEMENTATION-PLAN.md). Isi bagian yang relevan; jangan menyalin placeholder sebagai persyaratan nyata.

## Tujuan

Jelaskan satu hasil yang dapat dilakukan pengguna setelah tugas selesai, berikut pemicu dan hasil yang diharapkan.

## Acuan

- Fitur PRD: tulis ID fitur yang benar dari [PRD](../../PRD-ElektroPOS.md).
- Aturan/status/API yang terkait: tulis bagian pemilik aturan.
- Keputusan default/terbuka: sebut yang berpengaruh, tanpa mengarang jawaban OPEN.

## Dalam scope tugas

Daftar perilaku konkret, perubahan database/API/UI yang dibutuhkan, dan platform yang diuji. Perubahan minimal berarti alur tersebut utuh, bukan hanya tombol/halaman.

## Di luar scope tugas

Sebut batas yang mencegah pelebaran tugas. Jangan memasukkan fitur baru karena nama library memungkinkan.

## Kriteria penerimaan

Tuliskan Given/When/Then dan nilai hasil, termasuk penolakan, auth, retry dan konkurensi bila menyangkut uang/stok. Tautkan AT yang relevan dari dokumen pengujian.

## Lingkungan dan data

Gunakan fixture/proyek uji. Nyatakan project ref secara aman dan cara memastikan tidak menulis ke produksi. Jangan menempel secret di prompt/log.

## Verifikasi

Daftar command nyata setelah memeriksa package.json/runner, uji DB yang relevan, alur E2E dan bukti manual jika hardware diperlukan. Sebut NOT_RUN jika alat/data belum tersedia.

## Keluaran akhir

Ringkasan perubahan, file utama, hasil uji aktual, keputusan yang berubah, batas yang masih ada. Stop setelah kriteria tugas terpenuhi; deployment/commit/PR hanya bila termasuk otorisasi tugas.
