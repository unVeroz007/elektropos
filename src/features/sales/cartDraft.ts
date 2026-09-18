import { formatQuantity } from '../../lib/numbers'
import type { Draft } from '../../lib/drafts'
import { lineQty, type CartLine, type InvoiceDiscount } from './cart'
import type { CustomerSummary, PaymentMethod } from './types'

/**
 * Isi draf "Tahan Dulu" (FR-POS-01, FR-RES-01). Disimpan lewat src/lib/drafts.ts;
 * `clientReferenceId` ikut disimpan agar keranjang yang sama tidak menjadi dua nota.
 */
export type CartDraftContent = {
  kind: 'sale-cart'
  lines: CartLine[]
  invoiceDiscount: InvoiceDiscount
  customer: CustomerSummary | null
  paymentMethod: PaymentMethod
  clientReferenceId: string
}

export type CartDraft = Draft<CartDraftContent>

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function isCartLine(value: unknown): value is CartLine {
  return isRecord(value)
    && typeof value.key === 'string'
    && typeof value.unitId === 'string'
    && typeof value.productId === 'string'
    && typeof value.qtyText === 'string'
    && typeof value.unitVersion === 'number'
    && typeof value.sellPrice === 'string'
    && typeof value.factorBase === 'string'
    && typeof value.wholeRoll === 'boolean'
    && typeof value.saleStep === 'string'
    && typeof value.quantityStep === 'string'
}

/** Isi draf yang sah, atau null bila draf rusak/berasal dari versi lain. */
export function parseCartDraft(content: unknown): CartDraftContent | null {
  if (!isRecord(content) || content.kind !== 'sale-cart') return null
  if (!Array.isArray(content.lines) || !content.lines.every(isCartLine)) return null
  if (typeof content.clientReferenceId !== 'string') return null
  const method = content.paymentMethod
  const discount = isRecord(content.invoiceDiscount) ? content.invoiceDiscount : null
  return {
    kind: 'sale-cart',
    lines: content.lines.map(l => ({
      ...l,
      position: l.position ?? null,
      discountMode: l.discountMode ?? null,
      discountText: l.discountText ?? '',
      priceChange: l.priceChange ?? null,
      unavailable: Boolean(l.unavailable),
    })),
    invoiceDiscount: discount && (discount.mode === 'percent' || discount.mode === 'amount')
      ? { mode: discount.mode, text: typeof discount.text === 'string' ? discount.text : '' }
      : { mode: null, text: '' },
    customer: isRecord(content.customer) && typeof content.customer.id === 'string'
      ? content.customer as CustomerSummary : null,
    paymentMethod: method === 'TRANSFER' || method === 'QRIS' ? method : 'CASH',
    clientReferenceId: content.clientReferenceId,
  }
}

/** Nama draf yang mudah dikenali, mis. "Kabel NYA 2,5 m + 2 barang lain". */
export function draftLabel(lines: CartLine[], customer: CustomerSummary | null): string {
  const first = lines[0]
  if (!first) return 'Keranjang kosong'
  const qty = lineQty(first)
  const head = `${first.productName}${qty ? ` ${formatQuantity(qty, first.unitLabel)}` : ''}`
  const rest = lines.length > 1 ? ` + ${lines.length - 1} barang lain` : ''
  const who = customer ? ` (${customer.name})` : ''
  return `${head}${rest}${who}`
}

export const DRAFT_STATUS_LABEL: Record<Draft['status'], string> = {
  draft: 'Ditahan',
  sending: 'Sedang dikirim',
  unknown: 'Hasil bayar belum pasti',
  failed: 'Gagal dikirim',
}
