import Decimal from 'decimal.js'
import { formatQuantity, parseQuantity, rupiahOrNull } from '../../lib/numbers'
import { buildItem, lineErrors, newIntakeLine, withAutoRolls, type IntakeLine, type ProductLike } from '../stock/intakeModel'

/**
 * Retur ke distributor (keputusan D5). Barang keluar stok menjadi klaim senilai modal
 * (dihitung server); klaim diselesaikan sekali: uang kembali, kredit, barang pengganti, atau ditolak.
 * Keputusan pemilik 18-09-2026: retur distributor biasanya diganti barang, jadi "barang pengganti"
 * menjadi pilihan utama dan diisi otomatis dengan barang & jumlah yang dikembalikan.
 */

export type ReturnPick = {
  positionId: string
  version: number
  name: string
  label: string | null
  baseUnit: string
  quantityStep: string
  available: string
  qty: string
}

export function pickIssue(pick: ReturnPick): string | null {
  let qty: Decimal
  try {
    qty = parseQuantity(pick.qty)
  } catch (err) {
    return `${pick.name}: ${(err as Error).message}`
  }
  if (qty.isZero()) return `${pick.name}: jumlah harus lebih dari 0.`
  if (qty.greaterThan(pick.available)) return `${pick.name}: stok di tempat ini hanya ${formatQuantity(pick.available, pick.baseUnit)}.`
  const step = new Decimal(pick.quantityStep || '1')
  if (!step.isZero() && !qty.mod(step).isZero()) return `${pick.name}: jumlah harus kelipatan ${formatQuantity(step, pick.baseUnit)}.`
  return null
}

export function createReturnPayload(supplierId: string, reason: string, picks: ReturnPick[]):
  { payload: Record<string, unknown> } | { issue: string } {
  if (!supplierId) return { issue: 'Pilih distributor.' }
  if (picks.length === 0) return { issue: 'Pilih barang yang dikembalikan.' }
  const issue = picks.map(pickIssue).find(Boolean)
  if (issue) return { issue }
  if (reason.trim().length < 3) return { issue: 'Tulis alasan retur.' }
  return {
    payload: {
      supplier_id: supplierId,
      reason: reason.trim(),
      items: picks.map(p => ({ position_id: p.positionId, expected_version: p.version, qty_base: parseQuantity(p.qty).toFixed() })),
    },
  }
}

export type Outcome = 'REFUND' | 'CREDIT' | 'REPLACEMENT' | 'REJECTED'

export type SettleForm = {
  outcome: Outcome
  amount: string
  method: 'CASH' | 'TRANSFER' | 'QRIS'
  cashbox: 'SHOP_DRAWER' | 'FATHER_WALLET'
  confirmed: boolean
  reference: string
  note: string
  lines: IntakeLine[]
}

export const OUTCOMES: Outcome[] = ['REPLACEMENT', 'REFUND', 'CREDIT', 'REJECTED']

export const EMPTY_SETTLE: SettleForm = {
  outcome: 'REPLACEMENT', amount: '', method: 'CASH', cashbox: 'SHOP_DRAWER', confirmed: false, reference: '', note: '', lines: [],
}

/**
 * Usulan barang pengganti: barang yang sama sejumlah yang dikembalikan (dijumlah per barang), dalam satuan
 * stok bila ada satuan isi 1. Pengguna tetap dapat mengubah jumlah, satuan, dan pembagian roll.
 */
export function replacementLinesFor(
  items: { product_id: string; qty_base: string }[],
  products: ProductLike[],
): IntakeLine[] {
  const totals = new Map<string, Decimal>()
  for (const item of items) totals.set(item.product_id, (totals.get(item.product_id) ?? new Decimal(0)).plus(item.qty_base))
  const byId = new Map(products.map(p => [p.id, p]))
  const lines: IntakeLine[] = []
  for (const [productId, qtyBase] of totals) {
    const product = byId.get(productId)
    if (!product) continue
    const active = product.units.filter(u => u.active !== false)
    const baseUnit = active.find(u => new Decimal(u.factor_base).equals(1))
    const line = newIntakeLine(product, baseUnit?.id)
    const qty = qtyBase.dividedBy(line.factor)
    lines.push(withAutoRolls({ ...line, qty: qty.isInteger() || baseUnit ? qty.toFixed() : '' }))
  }
  return lines
}

/** Payload penyelesaian sesuai hasil; field hasil lain tidak dikirim (server menolaknya). */
export function settlePayload(returnId: string, version: number, form: SettleForm):
  { payload: Record<string, unknown> } | { issue: string } {
  const base: Record<string, unknown> = { supplier_return_id: returnId, expected_version: version, outcome: form.outcome }
  const note = form.note.trim()
  switch (form.outcome) {
    case 'REFUND': {
      const amount = rupiahOrNull(form.amount)
      if (!amount || new Decimal(amount).isZero()) return { issue: 'Isi jumlah uang yang dikembalikan distributor.' }
      if (form.method !== 'CASH' && !form.confirmed) return { issue: 'Centang bahwa uang sudah masuk ke rekening/QRIS toko.' }
      const payload = { ...base, amount, method: form.method } as Record<string, unknown>
      if (form.method === 'CASH') payload.cashbox = form.cashbox
      else {
        payload.confirmed = true
        if (form.reference.trim()) payload.reference = form.reference.trim()
      }
      if (note) payload.note = note
      return { payload }
    }
    case 'CREDIT': {
      const amount = rupiahOrNull(form.amount)
      if (!amount || new Decimal(amount).isZero()) return { issue: 'Isi nilai kredit dari distributor.' }
      const payload = { ...base, amount } as Record<string, unknown>
      if (form.reference.trim()) payload.reference = form.reference.trim()
      if (note) payload.note = note
      return { payload }
    }
    case 'REPLACEMENT': {
      if (form.lines.length === 0) return { issue: 'Tambahkan barang pengganti yang diterima.' }
      const errors = form.lines.flatMap(line => lineErrors(line, { withCost: false }))
      if (errors.length) return { issue: errors[0] }
      const payload = { ...base, items: form.lines.map(line => buildItem(line, { withCost: false })) } as Record<string, unknown>
      if (note) payload.note = note
      return { payload }
    }
    case 'REJECTED':
      if (note.length < 3) return { issue: 'Tulis alasan distributor menolak.' }
      return { payload: { ...base, note } }
  }
}

/** Selisih uang/kredit terhadap nilai klaim (negatif = rugi), untuk ditampilkan sebelum menyimpan. */
export function settlementPreview(claimValue: string, form: SettleForm): Decimal | null {
  if (form.outcome === 'REPLACEMENT') return new Decimal(0)
  if (form.outcome === 'REJECTED') return new Decimal(claimValue).negated()
  const amount = rupiahOrNull(form.amount)
  return amount ? new Decimal(amount).minus(claimValue) : null
}
