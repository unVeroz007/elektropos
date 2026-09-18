import Decimal from 'decimal.js'
import { formatQuantity, formatRupiah, parseQuantity, parseRupiah, quantityOrNull, rupiahOrNull } from '../../lib/numbers'
import { isTerminal } from './labels'
import type { PartEvent, PayMethod, PaymentState, StockPositionRow, TicketDetail, WorkStatus } from './types'

/**
 * Aturan tampilan servis yang murni (mudah diuji). Server tetap otoritatif;
 * fungsi ini hanya mencegah pengguna menekan tombol yang pasti ditolak dan
 * menjelaskan alasannya dengan bahasa awam.
 */

/** Nilai baris tagihan = round_half_up(qty × harga, 0) — sama dengan server. */
export function lineTotal(quantity: string, unitPrice: string): Decimal {
  return new Decimal(quantity).times(unitPrice).toDecimalPlaces(0, Decimal.ROUND_HALF_UP)
}

export type DraftChargeLine = { quantity: string; unitPrice: string }

/** Total pratinjau tagihan; baris yang belum sah dihitung 0 dan dilaporkan lewat `invalid`. */
export function draftInvoiceTotal(lines: DraftChargeLine[]): { total: Decimal; invalid: number } {
  let total = new Decimal(0)
  let invalid = 0
  for (const line of lines) {
    try {
      const qty = parseQuantity(line.quantity)
      const price = parseRupiah(line.unitPrice)
      total = total.plus(lineTotal(qty.toFixed(), price.toFixed(0)))
    } catch {
      // Baris belum lengkap: tidak ikut dijumlahkan, tombol simpan dikunci lewat `invalid`.
      invalid += 1
    }
  }
  return { total, invalid }
}

export type InvoiceCheck = { ok: true; mode: 'APPROVED' | 'WAIVER' } | { ok: false; message: string }

/** Syarat BR-09 sebelum tagihan final dikirim. */
export function checkInvoice(params: {
  total: Decimal
  approvedRevision: number | null
  approvedLimit: string | null
  status: WorkStatus
  waiverReason: string
}): InvoiceCheck {
  const { total, approvedRevision, approvedLimit, status, waiverReason } = params
  if (approvedRevision !== null && approvedLimit !== null) {
    if (total.greaterThan(approvedLimit)) {
      return {
        ok: false,
        message: `Total ${formatRupiah(total)} melebihi batas yang disetujui pelanggan (${formatRupiah(approvedLimit)}). `
          + 'Kurangi biaya atau catat estimasi baru dan minta persetujuan lagi.',
      }
    }
    return { ok: true, mode: 'APPROVED' }
  }
  const failedEnd = status === 'CANCELLED' || status === 'UNREPAIRABLE'
  if (!total.isZero() || !failedEnd) {
    return { ok: false, message: 'Belum ada persetujuan biaya dari pelanggan. Catat estimasi dan persetujuannya lebih dulu.' }
  }
  if (waiverReason.trim().length < 3) {
    return { ok: false, message: 'Tagihan Rp0 tanpa persetujuan wajib diberi alasan pembebasan biaya.' }
  }
  return { ok: true, mode: 'WAIVER' }
}

/** Pemakaian part yang masih bersih (belum dikembalikan penuh). */
export function netUsedParts(parts: PartEvent[]): PartEvent[] {
  return parts.filter(p => p.kind === 'USE' && p.net_qty !== null && new Decimal(p.net_qty).greaterThan(0))
}

/** Perkiraan tagihan part menurut harga tagih saat dipakai (untuk peringatan batas). */
export function partChargeEstimate(parts: PartEvent[]): Decimal {
  return netUsedParts(parts).reduce(
    (sum, p) => sum.plus(lineTotal(p.net_qty ?? '0', p.charge_unit_price ?? '0')), new Decimal(0))
}

export type TransitionNeeds = { reason: boolean; testResult: boolean; approval: boolean }

export function transitionNeeds(target: WorkStatus): TransitionNeeds {
  return {
    reason: ['AWAITING_APPROVAL', 'WAITING_PARTS', 'UNREPAIRABLE', 'CANCELLED'].includes(target),
    testResult: target === 'READY',
    approval: target === 'WORKING' || target === 'WAITING_PARTS',
  }
}

/** Hasil uji harus kalimat nyata (server menolak "OK" dan < 3 huruf). */
export function testResultError(text: string): string | null {
  const trimmed = text.trim()
  const letters = trimmed.replace(/[^\p{L}]/gu, '')
  if (letters.length < 3) return 'Tulis hasil uji nyata, mis. "Dinyalakan 30 menit, gambar normal".'
  if (/^ok[.!]*$/i.test(trimmed)) return 'Jangan hanya "OK". Tulis apa yang diuji dan hasilnya.'
  return null
}

function isFinal(payment: PaymentState): boolean {
  return payment.invoice_id !== null
}

/** Nilai uang dari server > 0 (null dianggap 0). */
export function isPositive(value: string | null | undefined): value is string {
  return value !== null && value !== undefined && value !== '' && new Decimal(value).greaterThan(0)
}

/** Sisa yang harus dilunasi tepat, atau null bila belum ada tagihan final / sudah lunas. */
export function settlementAmount(payment: PaymentState): string | null {
  return isFinal(payment) && isPositive(payment.outstanding) ? payment.outstanding : null
}

/** Batas uang kembali: refund_due setelah final, atau semua uang masuk bila batal tanpa tagihan. */
export function refundLimit(ticket: Pick<TicketDetail, 'work_status' | 'payment'>): string | null {
  const { payment } = ticket
  if (isFinal(payment)) return isPositive(payment.refund_due) ? payment.refund_due : null
  if (ticket.work_status === 'CANCELLED' && isPositive(payment.net_received)) return payment.net_received
  return null
}

/** Syarat umum penutupan (serah terima / tutup kunjungan). Kosong berarti boleh. */
function closingBlockers(ticket: TicketDetail): string[] {
  const reasons: string[] = []
  if (ticket.closed_at) return ['Tiket sudah ditutup.']
  if (!isTerminal(ticket.work_status)) {
    reasons.push('Pekerjaan belum selesai. Tandai selesai, tidak bisa diperbaiki, atau dibatalkan lebih dulu.')
  }
  if (!isFinal(ticket.payment)) reasons.push('Tagihan belum final.')
  else {
    if (isPositive(ticket.payment.outstanding)) {
      reasons.push(`Masih ada sisa bayar ${formatRupiah(ticket.payment.outstanding)}.`)
    }
    if (isPositive(ticket.payment.refund_due)) {
      reasons.push(`Ada uang yang harus dikembalikan ke pelanggan ${formatRupiah(ticket.payment.refund_due)}.`)
    }
  }
  return reasons
}

export function handoverBlockers(ticket: TicketDetail): string[] {
  const reasons = closingBlockers(ticket)
  if (!ticket.closed_at && ticket.custody_location === 'CUSTOMER') {
    reasons.push('Alat tidak dititipkan di toko atau dibawa ayah.')
  }
  return reasons
}

export function closeOnsiteBlockers(ticket: TicketDetail): string[] {
  const reasons = closingBlockers(ticket)
  if (!ticket.closed_at && ticket.custody_location !== 'CUSTOMER') {
    reasons.push('Alat masih di toko/dibawa ayah. Gunakan serah terima alat.')
  }
  return reasons
}

/** `2026-09-20T10:00` (jam toko) → ISO 8601 zona Asia/Jakarta. */
export function shopLocalToIso(value: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) return null
  return `${value}:00+07:00`
}

/** ISO → nilai input `datetime-local` pada jam toko. */
export function isoToShopLocal(iso: string | null): string {
  if (!iso) return ''
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Jakarta', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(iso))
  const get = (type: string) => parts.find(p => p.type === type)?.value ?? ''
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}`
}

/** Nomor HP untuk tautan telepon (hanya angka dan +). */
export function telHref(phone: string): string {
  return `tel:${phone.replace(/[^\d+]/g, '')}`
}

/** Petunjuk satu kalimat tentang langkah berikutnya untuk tiket ini. */
export function nextStep(ticket: TicketDetail): string {
  if (ticket.closed_at) return 'Servis sudah selesai dan ditutup.'
  const { payment } = ticket
  switch (ticket.work_status) {
    case 'NEW': return 'Periksa alat (tekan "Mulai periksa"), lalu catat perkiraan biaya.'
    case 'INSPECTING': return 'Catat perkiraan biaya, lalu tanyakan persetujuan pelanggan.'
    case 'AWAITING_APPROVAL':
      return ticket.approval.latest_status === 'PROPOSED'
        ? 'Tanyakan pelanggan, lalu catat persetujuan biayanya.'
        : 'Persetujuan sudah dicatat. Tekan "Mulai kerjakan" atau "Tunggu part".'
    case 'WAITING_PARTS': return 'Setelah part tersedia, tekan "Mulai kerjakan".'
    case 'WORKING': return 'Catat part yang dipakai. Setelah alat diuji, tekan "Selesai dikerjakan".'
    default: break
  }
  if (!ticket.invoice) return 'Pekerjaan selesai. Buat tagihan final.'
  if (isPositive(payment.outstanding)) return `Terima pelunasan ${formatRupiah(payment.outstanding)}.`
  if (isPositive(payment.refund_due)) return `Kembalikan kelebihan bayar ${formatRupiah(payment.refund_due)} ke pelanggan.`
  return ticket.custody_location === 'CUSTOMER'
    ? 'Semua sudah beres. Tutup kunjungan.'
    : 'Semua sudah beres. Serahkan alat ke pelanggan.'
}

/** Kesalahan qty part (null bila sah). */
export function partQtyError(input: string, position: Pick<StockPositionRow, 'qty_base' | 'quantity_step' | 'base_unit'>): string | null {
  const qty = quantityOrNull(input)
  if (!qty) return 'Isi jumlah part yang dipakai.'
  if (new Decimal(qty).greaterThan(position.qty_base)) {
    return `Stok di tempat ini hanya ${formatQuantity(position.qty_base, position.base_unit)}.`
  }
  const step = new Decimal(position.quantity_step || '1')
  if (!step.isZero() && !new Decimal(qty).mod(step).isZero()) {
    return `Jumlah harus kelipatan ${formatQuantity(step, position.base_unit)}.`
  }
  return null
}

/** Kesalahan isian pembayaran (null bila siap). */
export function paymentFormError(params: {
  amount: string | null
  method: PayMethod
  tendered: string
  confirmed: boolean
}): string | null {
  const { amount, method, tendered, confirmed } = params
  if (!amount || !new Decimal(amount).greaterThan(0)) return 'Isi jumlah uang yang dibayar.'
  if (method === 'CASH') {
    const tenderedValue = rupiahOrNull(tendered)
    if (!tenderedValue) return 'Isi uang yang diterima dari pelanggan.'
    if (new Decimal(tenderedValue).lessThan(amount)) return 'Uang diterima kurang dari jumlah yang dibayar.'
    return null
  }
  return confirmed ? null : 'Centang konfirmasi setelah memastikan uang benar-benar masuk.'
}
