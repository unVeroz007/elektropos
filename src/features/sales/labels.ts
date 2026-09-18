import type { Disposition, PaymentMethod, PaymentStatus } from './types'

/** Label awam untuk kode server. Kode mentah tidak pernah tampil ke pengguna. */

export const PAYMENT_LABEL: Record<PaymentMethod, string> = {
  CASH: 'Tunai',
  TRANSFER: 'Transfer bank',
  QRIS: 'QRIS',
}

export const PAYMENT_STATUS: Record<PaymentStatus, { label: string; tone: 'success' | 'warning' | 'danger' | 'info' }> = {
  PAID: { label: 'Lunas', tone: 'success' },
  PARTIAL: { label: 'Dibayar sebagian', tone: 'warning' },
  UNPAID: { label: 'Belum dibayar', tone: 'danger' },
  REFUND_DUE: { label: 'Perlu uang kembali', tone: 'warning' },
}

export const DISPOSITION_LABEL: Record<Disposition, { label: string; description: string }> = {
  SALEABLE: { label: 'Layak jual', description: 'Barang kembali ke rak dan bisa dijual lagi' },
  DAMAGED: { label: 'Rusak', description: 'Barang disimpan terpisah, tidak bisa dijual' },
  NONE: { label: 'Barang tidak kembali', description: 'Hanya uang yang dikembalikan, stok tidak berubah' },
}

export function paymentLabel(method: string | null | undefined): string {
  if (!method) return '-'
  return PAYMENT_LABEL[method as PaymentMethod] ?? 'Lainnya'
}

export function paymentStatus(status: string | null | undefined) {
  return PAYMENT_STATUS[status as PaymentStatus] ?? { label: 'Belum diketahui', tone: 'info' as const }
}
