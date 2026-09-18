import { formatRupiah } from '../../lib/numbers'
import { cashShortfall, type SaleDraftInput } from './cart'
import type { PreviewState } from './hooks'
import type { PaymentMethod, SaleInput, SalePreview } from './types'

/**
 * Aturan tombol Bayar dan penyusunan pembayaran (BR-07).
 * Semua angka pembanding berasal dari pratinjau server; klien tidak menghitung total.
 */

export type PaymentForm = {
  method: PaymentMethod
  tenderedText: string
  /** Rupiah kanonik dari `rupiahOrNull(tenderedText)`, atau null bila belum sah. */
  tendered: string | null
  /** Total yang dikonfirmasi petugas "uang sudah masuk" (Transfer/QRIS); null bila belum. */
  confirmedTotal: string | null
  reference: string
  freeReason: string
}

export type PayContext = {
  canSell: boolean
  canDiscount: boolean
  online: boolean
  lineCount: number
  hasIssues: boolean
  priceReview: boolean
  drawerClosed: boolean
  preview: PreviewState
  form: PaymentForm
}

/** Alasan tombol Bayar belum aktif (kalimat awam), atau null bila siap. */
export function payBlocker(ctx: PayContext): string | null {
  if (!ctx.canSell) return 'Akun ini tidak dapat melakukan penjualan.'
  if (!ctx.online) return 'Internet terputus. Pembayaran dapat dilakukan setelah koneksi pulih.'
  if (ctx.lineCount === 0) return 'Keranjang masih kosong.'
  if (ctx.hasIssues) return 'Perbaiki dulu isian yang ditandai merah.'
  if (ctx.priceReview) return 'Ada harga yang berubah. Periksa lalu tekan "Harga sudah saya periksa".'
  if (ctx.preview.status === 'loading' || ctx.preview.status === 'empty') return 'Menunggu total dari sistem…'
  if (ctx.preview.status === 'error') return 'Total belum dapat dihitung. Baca pesan di atas.'
  const preview = ctx.preview.data
  const { form } = ctx
  if (preview.requires_owner_reason) {
    if (!ctx.canDiscount) return 'Nota Rp0 hanya dapat diproses pemilik toko.'
    return form.freeReason.trim() === '' ? 'Isi alasan nota Rp0 (gratis).' : null
  }
  if (form.method === 'CASH') {
    if (ctx.drawerClosed) return 'Laci kas belum dibuka. Buka kas dulu atau pilih Transfer/QRIS.'
    if (form.tenderedText.trim() === '') return 'Isi uang yang diterima dari pembeli.'
    if (form.tendered === null) return 'Nominal uang diterima belum benar.'
    const short = cashShortfall(form.tendered, preview.total)
    return short ? `Uang kurang ${formatRupiah(short)}.` : null
  }
  if (form.confirmedTotal !== preview.total) return 'Centang dulu bahwa uang sudah masuk ke rekening/QRIS toko.'
  return null
}

/** Payload finalisasi lengkap. Hanya dipanggil saat `payBlocker` null. */
export function buildFinalizeInput(base: SaleDraftInput, preview: SalePreview, form: PaymentForm): SaleInput {
  if (preview.requires_owner_reason) {
    return { ...base, reason: form.freeReason.trim(), payment: null }
  }
  if (form.method === 'CASH') {
    return { ...base, payment: { method: 'CASH', tendered: form.tendered ?? '' } }
  }
  const reference = form.reference.trim()
  return {
    ...base,
    payment: { method: form.method, confirmed: true, ...(reference ? { reference } : {}) },
  }
}

/** Payload pratinjau: sama dengan finalisasi, pembayaran hanya untuk menghitung kembalian tunai. */
export function buildPreviewInput(base: SaleDraftInput | null, form: PaymentForm): SaleInput | null {
  if (!base) return null
  if (form.method === 'CASH' && form.tendered !== null) {
    return { ...base, payment: { method: 'CASH', tendered: form.tendered } }
  }
  return base
}
