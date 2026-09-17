/**
 * Pemetaan error server ke kalimat yang dapat dipahami pengguna.
 *
 * Server menulis error sebagai `KODE: kalimat awam`. Frontend menampilkan kalimat
 * itu, ditambah petunjuk langkah berikutnya untuk kode yang dikenal. Error teknis
 * (constraint, SQL, jaringan) tidak pernah ditampilkan mentah.
 */

export type AppErrorKind = 'business' | 'network' | 'auth' | 'unknown'

export class AppError extends Error {
  readonly code: string
  readonly kind: AppErrorKind
  readonly hint: string

  constructor(code: string, message: string, kind: AppErrorKind, hint = '') {
    super(message)
    this.name = 'AppError'
    this.code = code
    this.kind = kind
    this.hint = hint
  }

  /** Kalimat lengkap untuk ditampilkan: pesan + petunjuk. */
  get display(): string {
    return this.hint ? `${this.message} ${this.hint}` : this.message
  }
}

const HINTS: Record<string, string> = {
  ACCOUNT_INACTIVE: 'Hubungi pemilik toko untuk mengaktifkan akun.',
  FORBIDDEN: 'Minta pemilik toko melakukan tindakan ini.',
  CASH_SESSION_CLOSED: 'Buka kas di menu Kas Laci, lalu ulangi.',
  CASH_SESSION_ALREADY_OPEN: 'Muat ulang halaman untuk melihat kas yang sedang terbuka.',
  INSUFFICIENT_STOCK: 'Periksa stok di katalog atau kurangi jumlah.',
  INSUFFICIENT_CASH: 'Saldo kas tidak cukup. Gunakan metode lain atau tambah kas lebih dulu.',
  PRICE_CHANGED: 'Harga sudah diperbarui. Periksa kembali keranjang lalu bayar lagi.',
  VERSION_CONFLICT: 'Data baru saja diubah orang lain. Muat ulang lalu ulangi.',
  IDEMPOTENCY_CONFLICT: 'Transaksi ini sudah pernah dikirim dengan isi berbeda. Mulai transaksi baru.',
  REFUND_LIMIT_EXCEEDED: 'Jumlah melebihi batas yang boleh dikembalikan.',
  APPROVAL_REQUIRED: 'Catat persetujuan biaya dari pelanggan lebih dulu.',
  PAYMENT_OUTSTANDING: 'Selesaikan pembayaran sebelum alat diserahkan.',
  INVALID_NUMBER: 'Periksa kembali angka yang diketik.',
  INVALID_DATE: 'Periksa kembali tanggal yang dipilih.',
}

const NETWORK_PATTERN = /Failed to fetch|NetworkError|Network request failed|ERR_NETWORK|Load failed|ECONNREFUSED|ERR_CONNECTION|fetch failed/i
const CODE_PATTERN = /^([A-Z][A-Z0-9_]{2,}):\s*(.*)$/s

type RawError = { message?: string; code?: string; status?: number } | Error | string | null | undefined

/** Ubah error apa pun (Supabase, fetch, Error biasa) menjadi AppError. */
export function toAppError(raw: RawError): AppError {
  if (raw instanceof AppError) return raw
  const message = typeof raw === 'string' ? raw : raw?.message ?? ''

  if (NETWORK_PATTERN.test(message)) {
    return new AppError('NETWORK', 'Koneksi ke server terputus.', 'network',
      'Periksa internet/jaringan toko. Jika sedang membayar, cek riwayat nota sebelum mengulang.')
  }

  const match = CODE_PATTERN.exec(message.trim())
  if (match) {
    const [, code, text] = match
    const kind: AppErrorKind = code === 'ACCOUNT_INACTIVE' || code === 'FORBIDDEN' ? 'auth' : 'business'
    return new AppError(code, text || 'Permintaan ditolak.', kind, HINTS[code] ?? '')
  }

  const pgCode = typeof raw === 'object' && raw && 'code' in raw ? raw.code : undefined
  if (pgCode === '42501' || /JWT|not authorized|permission denied/i.test(message)) {
    return new AppError('FORBIDDEN', 'Akses ditolak.', 'auth', 'Masuk ulang atau hubungi pemilik toko.')
  }
  return new AppError('UNKNOWN', 'Terjadi kesalahan yang tidak terduga.', 'unknown',
    'Coba lagi. Jika terus terjadi, catat waktunya dan hubungi pengelola aplikasi.')
}

/** Kalimat siap tampil untuk error apa pun. */
export function errorText(raw: RawError): string {
  return toAppError(raw).display
}
