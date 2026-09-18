import type {
  ApprovalMethod, Cashbox, ChargeKind, Custody, PayMethod, PaymentStatus, ServiceLocation,
  StockCondition, StockLocation, WorkStatus,
} from './types'

/** Label awam untuk kode server. Kode mentah tidak pernah tampil ke pengguna. */

const STATUS: Record<WorkStatus, string> = {
  NEW: 'Baru diterima',
  INSPECTING: 'Diperiksa',
  AWAITING_APPROVAL: 'Menunggu persetujuan biaya',
  WAITING_PARTS: 'Menunggu part',
  WORKING: 'Dikerjakan',
  READY: 'Siap diambil',
  UNREPAIRABLE: 'Tidak bisa diperbaiki',
  CANCELLED: 'Dibatalkan',
}

export function statusLabel(status: WorkStatus | null | undefined, location?: ServiceLocation): string {
  if (!status) return 'Belum ada'
  if (status === 'READY' && location === 'ONSITE') return 'Selesai dikerjakan'
  return STATUS[status] ?? 'Status lain'
}

export const TERMINAL: WorkStatus[] = ['READY', 'UNREPAIRABLE', 'CANCELLED']
export const isTerminal = (status: WorkStatus) => TERMINAL.includes(status)

export function statusTone(status: WorkStatus): 'neutral' | 'info' | 'success' | 'warning' | 'danger' {
  switch (status) {
    case 'READY': return 'success'
    case 'AWAITING_APPROVAL':
    case 'WAITING_PARTS': return 'warning'
    case 'UNREPAIRABLE':
    case 'CANCELLED': return 'danger'
    case 'NEW': return 'neutral'
    default: return 'info'
  }
}

/** Teks tombol untuk tiap tujuan status. */
export const TRANSITION_ACTION: Record<WorkStatus, string> = {
  NEW: 'Baru diterima',
  INSPECTING: 'Mulai periksa',
  AWAITING_APPROVAL: 'Minta persetujuan biaya',
  WAITING_PARTS: 'Tunggu part',
  WORKING: 'Mulai kerjakan',
  READY: 'Selesai dikerjakan',
  UNREPAIRABLE: 'Tidak bisa diperbaiki',
  CANCELLED: 'Batalkan servis',
}

export const CUSTODY: Record<Custody, string> = {
  CUSTOMER: 'Di pelanggan',
  SHOP: 'Di toko',
  FATHER: 'Dibawa ayah',
}

export const LOCATION: Record<ServiceLocation, string> = {
  STORE: 'Servis di toko',
  ONSITE: 'Kunjungan rumah',
}

export const PAYMENT_STATUS: Record<PaymentStatus, string> = {
  UNPRICED: 'Belum ditagih',
  UNPAID: 'Belum bayar',
  PARTIAL: 'Bayar sebagian',
  PAID: 'Lunas',
  REFUND_DUE: 'Perlu uang kembali',
}

export function paymentTone(status: PaymentStatus): 'neutral' | 'success' | 'warning' | 'danger' {
  if (status === 'PAID') return 'success'
  if (status === 'REFUND_DUE') return 'danger'
  if (status === 'UNPRICED') return 'neutral'
  return 'warning'
}

export const METHOD: Record<PayMethod, string> = { CASH: 'Tunai', TRANSFER: 'Transfer bank', QRIS: 'QRIS' }

export const CASHBOX: Record<Cashbox, string> = { SHOP_DRAWER: 'Laci toko', FATHER_WALLET: 'Dompet ayah' }

export const APPROVAL_METHOD: Record<ApprovalMethod, string> = {
  IN_PERSON: 'Langsung',
  PHONE: 'Telepon',
  WHATSAPP: 'WhatsApp',
  OTHER: 'Lainnya',
}

export const CHARGE_KIND: Record<ChargeKind, string> = {
  LABOR: 'Jasa perbaikan',
  PART: 'Part',
  VISIT: 'Biaya kunjungan',
  DIAGNOSIS: 'Biaya pemeriksaan',
}

export const STOCK_LOCATION: Record<StockLocation, string> = { SHOP: 'Stok toko', FIELD_FATHER: 'Dibawa ayah' }
export const STOCK_CONDITION: Record<StockCondition, string> = { SALEABLE: 'Masih bagus', DAMAGED: 'Rusak' }

export const ESTIMATE_STATUS: Record<string, string> = {
  PROPOSED: 'Menunggu jawaban pelanggan',
  APPROVED: 'Disetujui',
  SUPERSEDED: 'Diganti revisi baru',
}

export const PAYMENT_PURPOSE: Record<string, string> = {
  SERVICE_RECEIPT: 'Pembayaran diterima',
  CUSTOMER_REFUND: 'Uang dikembalikan',
  PAYMENT_REVERSAL: 'Koreksi (dibatalkan)',
  PAYMENT_REPLACEMENT: 'Koreksi (pengganti)',
}
