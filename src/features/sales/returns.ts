import Decimal from 'decimal.js'
import { formatQuantity, parseQuantity } from '../../lib/numbers'
import type { CostAllocation, Disposition, InvoiceItem, PaymentMethod, ReturnInput, ReturnLineInput } from './types'

/**
 * Logika formulir retur (FR-POS-04, BR-08, T05/T07). Jumlah diketik dalam satuan jual,
 * dikirim ke server dalam satuan dasar. Nilai uang kembali final dihitung server.
 */

export type ReturnProductInfo = { base_unit: string; quantity_step: string; track_segments: boolean }

export type ReturnLineForm = {
  selected: boolean
  qtyText: string
  disposition: Disposition
  manualAllocation: boolean
  allocationTexts: Record<string, string>
  label: string
}

export const EMPTY_RETURN_LINE: ReturnLineForm = {
  selected: false, qtyText: '', disposition: 'SALEABLE', manualAllocation: false, allocationTexts: {}, label: '',
}

function safeQuantity(text: string): Decimal | null {
  try {
    return parseQuantity(text)
  } catch {
    return null
  }
}

/** Sisa yang boleh diretur dalam satuan jual (dibulatkan 3 desimal untuk tampilan). */
export function returnableSell(item: InvoiceItem): Decimal {
  const factor = new Decimal(item.factor)
  return factor.isZero() ? new Decimal(0) : new Decimal(item.returnable_qty).dividedBy(factor).toDecimalPlaces(3)
}

/** Jumlah retur dalam satuan dasar, atau null bila isian belum sah. */
export function returnBaseQty(form: ReturnLineForm, item: InvoiceItem): Decimal | null {
  const qty = safeQuantity(form.qtyText)
  return qty && !qty.isZero() ? qty.times(item.factor) : null
}

export function allocationRemaining(allocation: CostAllocation): Decimal {
  return new Decimal(allocation.qty_base).minus(allocation.reversed_qty)
}

function isStepMultiple(value: Decimal, step: string): boolean {
  const stepValue = new Decimal(step)
  return value.decimalPlaces() <= 3 && (stepValue.isZero() || value.mod(stepValue).isZero())
}

/** Masalah isian satu baris retur (kalimat awam), atau null. */
export function returnLineIssue(form: ReturnLineForm, item: InvoiceItem, product: ReturnProductInfo): string | null {
  if (!form.selected) return null
  const unit = item.unit_label ?? product.base_unit
  if (form.qtyText.trim() === '') return 'Isi jumlah yang dikembalikan.'
  const qty = safeQuantity(form.qtyText)
  if (!qty) {
    try {
      parseQuantity(form.qtyText)
    } catch (err) {
      return (err as Error).message
    }
  }
  if (!qty || qty.isZero()) return 'Jumlah harus lebih dari 0.'
  const base = qty.times(item.factor)
  if (!isStepMultiple(base, product.quantity_step)) {
    return `Jumlah harus kelipatan ${formatQuantity(product.quantity_step, product.base_unit)}; barang ini tidak bisa dikembalikan pecahan.`
  }
  if (base.greaterThan(item.returnable_qty)) {
    return `Paling banyak ${formatQuantity(returnableSell(item), unit)} yang masih bisa dikembalikan.`
  }
  if (form.disposition !== 'NONE' && form.manualAllocation) {
    let sum = new Decimal(0)
    for (const allocation of item.cost_allocations ?? []) {
      const text = form.allocationTexts[allocation.id] ?? ''
      if (text.trim() === '') continue
      const value = safeQuantity(text)
      if (!value) return 'Periksa angka pada pilihan asal barang.'
      if (value.greaterThan(allocationRemaining(allocation))) return 'Jumlah dari satu asal barang melebihi sisanya.'
      if (!isStepMultiple(value, product.quantity_step)) {
        return `Jumlah per asal barang harus kelipatan ${formatQuantity(product.quantity_step, product.base_unit)}.`
      }
      sum = sum.plus(value)
    }
    if (!sum.equals(base)) {
      return `Jumlah dari semua asal barang harus ${formatQuantity(base, product.base_unit)} (sekarang ${formatQuantity(sum, product.base_unit)}).`
    }
  }
  return null
}

/**
 * Perkiraan uang kembali per BR-08: H(x) = round_half_up(N × x / Q, 0), kumulatif.
 * Refund kejadian ini = H(sudah diretur + x) − H(sudah diretur). Angka pasti dari server.
 */
export function estimateLineRefund(item: InvoiceItem, baseQty: Decimal): Decimal {
  const q = new Decimal(item.qty_base)
  if (q.isZero()) return new Decimal(0)
  const n = new Decimal(item.net_total)
  const h = (x: Decimal) => (x.greaterThanOrEqualTo(q) ? n : n.times(x).dividedBy(q).toDecimalPlaces(0, Decimal.ROUND_HALF_UP))
  const before = new Decimal(item.returned_qty)
  return h(before.plus(baseQty)).minus(h(before))
}

export function estimateRefund(items: InvoiceItem[], forms: Record<string, ReturnLineForm>): Decimal {
  return items.reduce((sum, item) => {
    const form = forms[item.id]
    const base = form?.selected ? returnBaseQty(form, item) : null
    return base ? sum.plus(estimateLineRefund(item, base)) : sum
  }, new Decimal(0))
}

function lineInput(item: InvoiceItem, form: ReturnLineForm, product: ReturnProductInfo): ReturnLineInput {
  const base = (returnBaseQty(form, item) as Decimal).toFixed()
  const line: ReturnLineInput = { invoice_item_id: item.id, qty_base: base, disposition: form.disposition }
  if (form.disposition !== 'NONE' && form.manualAllocation) {
    line.allocations = (item.cost_allocations ?? [])
      .map(a => ({ id: a.id, value: safeQuantity(form.allocationTexts[a.id] ?? '') }))
      .filter((a): a is { id: string; value: Decimal } => a.value !== null && !a.value.isZero())
      .map(a => ({ cost_allocation_id: a.id, qty_base: a.value.toFixed() }))
  }
  if (form.disposition !== 'NONE' && product.track_segments && form.label.trim() !== '') {
    line.label = form.label.trim()
  }
  return line
}

export type ReturnFormState = {
  forms: Record<string, ReturnLineForm>
  reason: string
  refundMethod: PaymentMethod | ''
  refundReference: string
}

/** Payload retur, atau pesan masalah pertama bila formulir belum lengkap. */
export function buildReturnInput(
  invoiceId: string,
  items: InvoiceItem[],
  products: Record<string, ReturnProductInfo>,
  state: ReturnFormState,
): { input: ReturnInput } | { issue: string } {
  const chosen = items.filter(i => state.forms[i.id]?.selected)
  if (chosen.length === 0) return { issue: 'Pilih barang yang dikembalikan.' }
  const lines: ReturnLineInput[] = []
  for (const item of chosen) {
    const product = item.product_id ? products[item.product_id] : undefined
    if (!product) return { issue: 'Data barang belum termuat. Muat ulang halaman.' }
    const issue = returnLineIssue(state.forms[item.id], item, product)
    if (issue) return { issue: `${item.description}: ${issue}` }
    lines.push(lineInput(item, state.forms[item.id], product))
  }
  if (state.reason.trim() === '') return { issue: 'Isi alasan retur.' }
  const refund = estimateRefund(items, state.forms)
  if (refund.greaterThan(0) && state.refundMethod === '') return { issue: 'Pilih cara uang dikembalikan.' }
  const input: ReturnInput = { invoice_id: invoiceId, reason: state.reason.trim(), items: lines }
  if (refund.greaterThan(0) && state.refundMethod !== '') {
    input.refund_method = state.refundMethod
    const reference = state.refundReference.trim()
    if (reference && state.refundMethod !== 'CASH') input.refund_reference = reference
  }
  return { input }
}
