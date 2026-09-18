import Decimal from 'decimal.js'
import { formatRupiah, rupiahOrNull } from '../../lib/numbers'

/**
 * Aturan formulir kas (BR-12, keputusan D1). Server otoritatif untuk saldo;
 * fungsi ini hanya mencegah kiriman yang pasti ditolak dan menjelaskan sebabnya.
 */

/** Selisih antara nilai baru dan pembanding (baru − pembanding), atau null bila salah satu belum sah. */
export function difference(value: string | null, reference: string | null): Decimal | null {
  if (value === null || reference === null) return null
  return new Decimal(value).minus(reference)
}

export function varianceText(diff: Decimal): string {
  if (diff.isZero()) return 'Cocok'
  return diff.isNegative() ? `Kurang ${formatRupiah(diff.abs())}` : `Lebih ${formatRupiah(diff)}`
}

/** Buka kas: saldo buka wajib; beda dari hitungan tutup terakhir wajib diberi keterangan. */
export function openError(amountText: string, lastCounted: string | null, note: string): string | null {
  const amount = rupiahOrNull(amountText)
  if (amount === null) return 'Isi jumlah uang di laci saat dibuka (0 bila kosong).'
  const diff = difference(amount, lastCounted)
  if (diff && !diff.isZero() && note.trim().length < 3) {
    return `Uang awal berbeda dari hitungan tutup terakhir (${varianceText(diff)}). Tulis keterangannya.`
  }
  return null
}

/** Tutup kas: hitungan fisik wajib; selisih dengan saldo sistem wajib diberi keterangan. */
export function closeError(countedText: string, expected: string, note: string): string | null {
  const counted = rupiahOrNull(countedText)
  if (counted === null) return 'Hitung uang fisik di laci lalu isi jumlahnya.'
  const diff = difference(counted, expected) as Decimal
  if (!diff.isZero() && note.trim().length < 3) return `Ada selisih (${varianceText(diff)}). Tulis keterangannya.`
  return null
}

/** Uang keluar (ambil/biaya/transfer) tidak boleh melebihi saldo sistem. */
export function outflowError(amountText: string, expected: string | null, reason: string): string | null {
  const amount = rupiahOrNull(amountText)
  if (amount === null || new Decimal(amount).isZero()) return 'Isi jumlah uang lebih dari 0.'
  if (reason.trim().length < 3) return 'Tulis alasannya.'
  if (expected !== null && new Decimal(amount).greaterThan(expected)) {
    return `Saldo sistem hanya ${formatRupiah(expected)}. Uang keluar tidak boleh melebihi saldo.`
  }
  return null
}
