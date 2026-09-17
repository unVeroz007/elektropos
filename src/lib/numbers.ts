import Decimal from 'decimal.js'

/**
 * Angka uang & kuantitas (BR-01). Nilai dikirim ke server sebagai string desimal
 * kanonik; server tetap otoritatif untuk semua perhitungan final. Fungsi di sini
 * hanya untuk validasi input dan tampilan.
 */

Decimal.set({ precision: 50, rounding: Decimal.ROUND_HALF_UP })

const CANONICAL = /^(0|[1-9]\d*)(?:\.\d+)?$/
export const MAX_QUANTITY = '999999999.999'
export const MAX_RUPIAH = '9999999999999999'

export class NumberInputError extends Error {}

function canonical(input: string, decimals: number, max: string): Decimal {
  if (!CANONICAL.test(input)) throw new NumberInputError('Angka tidak sah. Gunakan angka tanpa pemisah ribuan.')
  const fractional = input.split('.')[1] ?? ''
  if (fractional.length > decimals) throw new NumberInputError(`Maksimal ${decimals} angka di belakang koma.`)
  const value = new Decimal(input)
  if (value.greaterThan(max)) throw new NumberInputError('Angka terlalu besar.')
  return value
}

/**
 * Kuantitas yang diketik pengguna: koma ATAU titik sebagai pemisah desimal
 * (mis. `2,5` atau `2.5`), maksimal 3 desimal. Format ribuan seperti `1.000,5` ditolak.
 */
export function parseQuantity(input: string): Decimal {
  const trimmed = input.trim()
  if (trimmed === '') throw new NumberInputError('Jumlah wajib diisi.')
  if (trimmed.includes('.') && trimmed.includes(',')) {
    throw new NumberInputError('Gunakan satu tanda desimal saja, tanpa pemisah ribuan.')
  }
  return canonical(trimmed.replace(',', '.'), 3, MAX_QUANTITY)
}

/** Kuantitas kanonik untuk dikirim ke server, atau null bila input belum sah. */
export function quantityOrNull(input: string): string | null {
  try {
    const value = parseQuantity(input)
    return value.isZero() ? null : value.toFixed()
  } catch {
    return null
  }
}

/**
 * Rupiah bulat yang diketik pengguna: `50000`, `50.000`, atau `50 000`.
 * Pecahan Rupiah ditolak.
 */
export function parseRupiah(input: string): Decimal {
  const trimmed = input.trim().replace(/^rp\s*/i, '')
  if (trimmed === '') throw new NumberInputError('Nominal wajib diisi.')
  const grouped = /^\d{1,3}([. ]\d{3})+$/.test(trimmed)
  const plain = /^\d+$/.test(trimmed)
  if (!grouped && !plain) throw new NumberInputError('Nominal Rupiah harus angka bulat, mis. 50000 atau 50.000.')
  const digits = trimmed.replace(/[. ]/g, '').replace(/^0+(?=\d)/, '')
  return canonical(digits, 0, MAX_RUPIAH)
}

export function rupiahOrNull(input: string): string | null {
  try {
    return parseRupiah(input).toFixed(0)
  } catch {
    return null
  }
}

/** Persen 0–100, maksimal 4 desimal, koma atau titik. */
export function parsePercent(input: string): Decimal {
  const trimmed = input.trim().replace(',', '.').replace(/%$/, '')
  if (trimmed === '') throw new NumberInputError('Persen wajib diisi.')
  return canonical(trimmed, 4, '100')
}

function groupThousands(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, '.')
}

/** `"18750.4"` → `"Rp18.750"` (dibulatkan half-up hanya untuk tampilan). Aman untuk angka besar. */
export function formatRupiah(value: string | number | Decimal | null | undefined): string {
  if (value === null || value === undefined || value === '') return 'Rp0'
  const rounded = new Decimal(value).toDecimalPlaces(0, Decimal.ROUND_HALF_UP)
  const sign = rounded.isNegative() ? '-' : ''
  return `${sign}Rp${groupThousands(rounded.abs().toFixed(0))}`
}

/** `"2.500"` + `"m"` → `"2,5 m"`. */
export function formatQuantity(value: string | number | Decimal, unit?: string): string {
  const decimal = new Decimal(value)
  const [whole, fraction] = decimal.abs().toFixed().split('.')
  const text = `${decimal.isNegative() ? '-' : ''}${groupThousands(whole)}${fraction ? `,${fraction}` : ''}`
  return unit ? `${text} ${unit}` : text
}

/** Tanggal & waktu lokal toko (Asia/Jakarta), apa pun zona waktu perangkat. */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return '-'
  return new Intl.DateTimeFormat('id-ID', {
    timeZone: 'Asia/Jakarta', dateStyle: 'medium', timeStyle: 'short',
  }).format(new Date(iso))
}

/** Tanggal hari ini di Asia/Jakarta sebagai `YYYY-MM-DD` (bukan tanggal UTC). */
export function todayInShop(offsetDays = 0): string {
  const date = new Date(Date.now() + offsetDays * 86_400_000)
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(date)
}
