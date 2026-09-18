import Decimal from 'decimal.js'
import { parseQuantity, parseRupiah } from '../../lib/numbers'

/**
 * Model barang masuk & stok awal (FR-INV-01, T08, BR-03, BR-05). Fungsi murni: dipakai
 * layar dan uji. Server tetap memvalidasi ulang semuanya.
 */

export type IntakeMode = 'RECEIPT' | 'OPENING'

export type ManualPosition = { key: string; label: string; length: string; capacity: string; sealed: boolean }

export type IntakeLine = {
  key: string
  productId: string
  productName: string
  sku: string
  baseUnit: string
  trackSegments: boolean
  unitId: string
  unitLabel: string
  factor: string
  qty: string
  /** Total modal baris (Rupiah bulat), bukan harga satuan. */
  cost: string
  freeReason: string
  rollCount: string
  rollCapacity: string
  labelPrefix: string
  positions: ManualPosition[]
  /** Pembagian roll masih mengikuti jumlah (belum diubah manual). */
  rollsAuto: boolean
}

export type PaymentMethod = 'CASH' | 'TRANSFER' | 'QRIS' | 'SUPPLIER_CREDIT'

export type IntakePayment = {
  method: PaymentMethod
  cashbox: 'SHOP_DRAWER' | 'FATHER_WALLET'
  reference: string
  /** Centang manual pengguna bahwa transfer/QRIS sudah benar-benar dilakukan (T02). */
  confirmed: boolean
}

function tryQty(value: string): Decimal | null {
  try { return parseQuantity(value) } catch { return null }
}

function tryRupiah(value: string): Decimal | null {
  try { return parseRupiah(value) } catch { return null }
}

/** Jumlah dalam satuan stok = qty × isi satuan. */
export function lineBaseQty(line: IntakeLine): Decimal | null {
  const qty = tryQty(line.qty)
  return qty ? qty.mul(line.factor) : null
}

/** Usulan pembagian roll: satuan roll (isi > 1) → N roll @isi; satuan meter → 1 roll sepanjang qty. */
export function suggestedRolls(line: Pick<IntakeLine, 'qty' | 'factor'>): { count: string; capacity: string } {
  const qty = tryQty(line.qty)
  const factor = new Decimal(line.factor)
  if (qty && factor.greaterThan(1) && qty.isInteger()) return { count: qty.toFixed(), capacity: factor.toFixed() }
  if (qty) return { count: '1', capacity: qty.mul(factor).toFixed() }
  return { count: '', capacity: factor.greaterThan(1) ? factor.toFixed() : '' }
}

export function rollCount(line: IntakeLine): number {
  const n = Number(line.rollCount || '0')
  return Number.isInteger(n) && n > 0 ? n : 0
}

/** Panjang total posisi roll yang akan dibuat. */
export function rollTotal(line: IntakeLine): Decimal {
  const capacity = tryQty(line.rollCapacity) ?? new Decimal(0)
  const fromRolls = capacity.mul(rollCount(line))
  return line.positions.reduce((sum, p) => sum.add(tryQty(p.length) ?? 0), fromRolls)
}

/** Label posisi yang akan dicetak/ditulis (otomatis bila tanpa awalan). */
export function rollLabelsPreview(line: IntakeLine): string[] {
  const count = rollCount(line)
  const prefix = line.labelPrefix.trim()
  const auto = Array.from({ length: count }, (_, i) => prefix
    ? `${prefix}-${String(i + 1).padStart(2, '0')}`
    : `(otomatis ${i + 1})`)
  return [...auto, ...line.positions.map(p => p.label.trim() || '(label belum diisi)')]
}

/** `withCost: false` untuk barang pengganti distributor: modal otomatis dari nilai klaim. */
export function lineErrors(line: IntakeLine, options: { withCost?: boolean } = {}): string[] {
  const { withCost = true } = options
  const errors: string[] = []
  const name = line.productName
  const base = lineBaseQty(line)
  if (!base || base.isZero()) errors.push(`${name}: jumlah wajib diisi dan lebih dari nol.`)
  if (withCost) {
    const cost = tryRupiah(line.cost)
    if (!cost) errors.push(`${name}: total modal wajib diisi (Rupiah bulat).`)
    else if (cost.isZero() && !line.freeReason.trim()) errors.push(`${name}: modal nol wajib diberi alasan.`)
  }
  if (line.trackSegments) {
    const count = rollCount(line)
    if (line.rollCount.trim() !== '' && count === 0) errors.push(`${name}: jumlah roll harus bilangan bulat.`)
    if (count > 0 && !(tryQty(line.rollCapacity)?.greaterThan(0))) errors.push(`${name}: panjang per roll wajib diisi.`)
    if (count === 0 && line.positions.length === 0) errors.push(`${name}: tentukan pembagian roll.`)
    for (const p of line.positions) {
      const length = tryQty(p.length)
      const capacity = tryQty(p.capacity || p.length)
      if (!p.label.trim()) errors.push(`${name}: label potongan wajib diisi.`)
      if (!length || length.isZero()) errors.push(`${name}: panjang potongan ${p.label || ''} wajib diisi.`)
      else if (capacity && length.greaterThan(capacity)) errors.push(`${name}: panjang potongan ${p.label} melebihi panjang roll asalnya.`)
      if (p.sealed && length && capacity && !length.equals(capacity)) errors.push(`${name}: potongan ${p.label} hanya boleh bersegel bila utuh.`)
    }
    if (base && !rollTotal(line).equals(base)) {
      errors.push(`${name}: total panjang roll (${rollTotal(line).toFixed()}) harus sama dengan jumlah masuk (${base.toFixed()} ${line.baseUnit}).`)
    }
  }
  return errors
}

/** Total modal = total yang dibayar ke distributor. */
export function totalCost(lines: IntakeLine[]): Decimal {
  return lines.reduce((sum, line) => sum.add(tryRupiah(line.cost) ?? 0), new Decimal(0))
}

export function paymentErrors(payment: IntakePayment, total: Decimal, supplier: { id: string; credit_balance: string } | null): string[] {
  if (total.isZero()) return []
  const errors: string[] = []
  if ((payment.method === 'TRANSFER' || payment.method === 'QRIS') && !payment.confirmed) {
    errors.push('Centang konfirmasi bahwa pembayaran non-tunai ke distributor sudah dilakukan.')
  }
  if (payment.method === 'SUPPLIER_CREDIT') {
    if (!supplier) errors.push('Pilih distributor untuk memakai saldo kredit.')
    else if (new Decimal(supplier.credit_balance).lessThan(total)) errors.push('Saldo kredit distributor tidak cukup.')
  }
  return errors
}

export function buildItem(line: IntakeLine, options: { withCost?: boolean } = {}): Record<string, unknown> {
  const { withCost = true } = options
  const item: Record<string, unknown> = { product_unit_id: line.unitId, qty: parseQuantity(line.qty).toFixed() }
  if (withCost) {
    item.acquisition_cost = parseRupiah(line.cost).toFixed(0)
    if (parseRupiah(line.cost).isZero()) item.free_reason = line.freeReason.trim()
  }
  if (line.trackSegments) {
    const count = rollCount(line)
    if (count > 0) {
      item.rolls = {
        count: String(count),
        capacity: parseQuantity(line.rollCapacity).toFixed(),
        ...(line.labelPrefix.trim() ? { label_prefix: line.labelPrefix.trim() } : {}),
      }
    }
    if (line.positions.length > 0) {
      item.positions = line.positions.map(p => ({
        label: p.label.trim(),
        qty_base: parseQuantity(p.length).toFixed(),
        segment_capacity: parseQuantity(p.capacity || p.length).toFixed(),
        sealed: p.sealed,
      }))
    }
  }
  return item
}

export type IntakeHeader = { supplierId: string; sourceNote: string; sourceDate: string }

/** Payload `post_stock_receipt_v1` / `post_opening_stock_v1` (tanpa operation_id). */
export function buildIntakePayload(mode: IntakeMode, header: IntakeHeader, lines: IntakeLine[], payment: IntakePayment): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    reason: mode === 'OPENING' ? 'Stok awal' : 'Barang masuk',
    items: lines.map(line => buildItem(line)),
  }
  if (header.sourceNote.trim()) payload.source_note = header.sourceNote.trim()
  if (header.sourceDate) payload.source_date = header.sourceDate
  if (mode === 'OPENING') return payload
  if (header.supplierId) payload.supplier_id = header.supplierId
  const total = totalCost(lines)
  if (total.isZero()) return payload
  const pay: Record<string, unknown> = { method: payment.method, amount: total.toFixed(0) }
  if (payment.method === 'CASH') pay.cashbox = payment.cashbox
  if (payment.method === 'TRANSFER' || payment.method === 'QRIS') pay.confirmed = payment.confirmed
  if (payment.reference.trim() && payment.method !== 'SUPPLIER_CREDIT') pay.reference = payment.reference.trim()
  payload.payment = pay
  return payload
}

type ProductLike = {
  id: string; name: string; sku: string; base_unit: string; track_segments: boolean
  units: { id: string; label: string; factor_base: string; is_default: boolean; active?: boolean }[]
}

/** Baris baru untuk produk terpilih; satuan dari barcode bila ada, selain itu satuan utama. */
export function newIntakeLine(product: ProductLike, unitId?: string): IntakeLine {
  const units = product.units.filter(u => u.active !== false)
  const unit = units.find(u => u.id === unitId) ?? units.find(u => u.is_default) ?? units[0]
  return withAutoRolls({
    key: crypto.randomUUID(),
    productId: product.id,
    productName: product.name,
    sku: product.sku,
    baseUnit: product.base_unit,
    trackSegments: product.track_segments,
    unitId: unit?.id ?? '',
    unitLabel: unit?.label ?? product.base_unit,
    factor: unit?.factor_base ?? '1',
    qty: '1',
    cost: '',
    freeReason: '',
    rollCount: '',
    rollCapacity: '',
    labelPrefix: '',
    positions: [],
    rollsAuto: true,
  })
}

/** Selama pengguna belum mengubah pembagian roll, ikuti jumlah & satuan yang diketik. */
export function withAutoRolls(line: IntakeLine): IntakeLine {
  if (!line.trackSegments || !line.rollsAuto) return line
  const suggestion = suggestedRolls(line)
  return { ...line, rollCount: suggestion.count, rollCapacity: suggestion.capacity }
}
