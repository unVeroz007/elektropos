import Decimal from 'decimal.js'
import { formatQuantity, parsePercent, parseQuantity, parseRupiah } from '../../lib/numbers'
import type {
  BarcodeLookup, DiscountMode, ProductDetail, ProductSearchItem, ProductUnit, SaleInput, SaleLineInput,
  SellablePosition,
} from './types'

/**
 * Logika keranjang kasir (murni, tanpa React).
 *
 * Setiap baris menyimpan SNAPSHOT produk, satuan, harga dan versi saat barang
 * ditambahkan (T03): keranjang tidak bergantung pada hasil pencarian yang sedang
 * tampil. Semua nilai uang final dihitung server (`preview_sale_v1`); fungsi di
 * sini hanya memvalidasi isian dan menyusun payload.
 */

export type RollPick = {
  id: string
  label: string | null
  qtyBase: string
  capacity: string | null
  sealed: boolean
  version: number
}

export type ProductSnapshot = {
  productId: string
  productName: string
  specification: string
  baseUnit: string
  quantityStep: string
  trackSegments: boolean
  unitId: string
  unitLabel: string
  unitVersion: number
  factorBase: string
  /** Satuan ini dijual sebagai roll utuh bersegel (tanda satuan dari katalog, bukan tebakan faktor). */
  wholeRoll: boolean
  saleStep: string
  sellPrice: string
}

export type CartLine = ProductSnapshot & {
  key: string
  qtyText: string
  position: RollPick | null
  discountMode: DiscountMode | null
  discountText: string
  /** Terisi setelah PRICE_CHANGED: harga lama untuk ditunjukkan ke kasir. */
  priceChange: { previousPrice: string; previousLabel: string } | null
  /** Barang diarsip/satuan tidak ada lagi: harus dihapus sebelum bayar. */
  unavailable: boolean
}

export type InvoiceDiscount = { mode: DiscountMode | null; text: string }

export const NO_DISCOUNT: InvoiceDiscount = { mode: null, text: '' }

/** Teks kuantitas untuk kolom isian: koma desimal, tanpa pemisah ribuan. */
export function toQtyText(value: Decimal.Value): string {
  return new Decimal(value).toFixed().replace('.', ',')
}

export function snapshotFromSearch(product: ProductSearchItem, unit: ProductUnit): ProductSnapshot {
  return {
    productId: product.id,
    productName: product.name,
    specification: product.specification ?? '',
    baseUnit: product.base_unit,
    quantityStep: product.quantity_step,
    trackSegments: product.track_segments,
    unitId: unit.id,
    unitLabel: unit.label,
    unitVersion: unit.version,
    factorBase: unit.factor_base,
    wholeRoll: product.track_segments && unit.whole_roll,
    saleStep: unit.sale_step,
    sellPrice: unit.sell_price,
  }
}

export function snapshotFromBarcode(found: Extract<BarcodeLookup, { found: true }>): ProductSnapshot {
  return {
    productId: found.product_id,
    productName: found.name,
    specification: found.specification ?? '',
    baseUnit: found.base_unit,
    quantityStep: found.quantity_step,
    trackSegments: found.track_segments,
    unitId: found.unit_id,
    unitLabel: found.unit_label,
    unitVersion: found.unit_version,
    factorBase: found.factor_base,
    wholeRoll: found.track_segments && found.whole_roll,
    saleStep: found.sale_step,
    sellPrice: found.sell_price,
  }
}

export function rollPickFromPosition(position: SellablePosition): RollPick {
  return {
    id: position.position_id,
    label: position.label,
    qtyBase: position.qty_base,
    capacity: position.segment_capacity,
    sealed: position.sealed,
    version: position.version,
  }
}

/**
 * Satuan roll utuh (mis. "roll 100 m") ditandai di katalog. Satuan berisi > 1 lainnya
 * (mis. "ikat 10 m") dijual sebagai potongan dari satu roll/potongan.
 */
export function isWholeRoll(line: Pick<CartLine, 'trackSegments' | 'wholeRoll'>): boolean {
  return line.trackSegments && line.wholeRoll
}

/** Jumlah awal saat barang ditambahkan: 1 bila sah menurut langkah jual, selain itu satu langkah. */
export function defaultQty(saleStep: string): string {
  const step = new Decimal(saleStep)
  if (step.isZero() || new Decimal(1).mod(step).isZero()) return '1'
  return toQtyText(step)
}

/** Tombol +/− hanya untuk barang hitungan (langkah jual bilangan bulat). */
export function usesStepper(line: CartLine): boolean {
  return !line.trackSegments && new Decimal(line.saleStep).isInteger()
}

function newLine(snapshot: ProductSnapshot, key: string): CartLine {
  const roll = snapshot.trackSegments
  return {
    ...snapshot,
    key,
    qtyText: roll ? (isWholeRoll(snapshot) ? '1' : '') : defaultQty(snapshot.saleStep),
    position: null,
    discountMode: null,
    discountText: '',
    priceChange: null,
    unavailable: false,
  }
}

/**
 * Tambah barang. Barang biasa dengan satuan sama digabung (jumlah naik satu langkah);
 * barang potongan/roll selalu baris baru karena satu baris = satu potongan fisik.
 */
export function addToCart(lines: CartLine[], snapshot: ProductSnapshot, key: string): CartLine[] {
  if (!snapshot.trackSegments) {
    const existing = lines.find(l => l.unitId === snapshot.unitId && !l.trackSegments)
    if (existing) {
      return lines.map(l => (l.key === existing.key ? { ...l, qtyText: stepQty(l, 1) } : l))
    }
  }
  return [...lines, newLine(snapshot, key)]
}

/** Jumlah setelah tombol + (1) atau − (-1). Tidak pernah di bawah satu langkah jual. */
export function stepQty(line: Pick<CartLine, 'qtyText' | 'saleStep'>, direction: 1 | -1): string {
  const step = new Decimal(line.saleStep)
  let current: Decimal
  try {
    current = parseQuantity(line.qtyText)
  } catch {
    return toQtyText(step)
  }
  const next = current.plus(step.times(direction))
  return toQtyText(next.lessThan(step) ? step : next)
}

export function updateLine(lines: CartLine[], key: string, patch: Partial<CartLine>): CartLine[] {
  return lines.map(l => (l.key === key ? { ...l, ...patch } : l))
}

export function removeLine(lines: CartLine[], key: string): CartLine[] {
  return lines.filter(l => l.key !== key)
}

/** Kuantitas sah dalam satuan jual, atau null. Tidak pernah melempar. */
export function lineQty(line: Pick<CartLine, 'qtyText'>): Decimal | null {
  try {
    const qty = parseQuantity(line.qtyText)
    return qty.isZero() ? null : qty
  } catch {
    return null
  }
}

/** Kuantitas dalam satuan dasar (mis. meter), atau null bila jumlah belum sah. */
export function lineBaseQty(line: CartLine): Decimal | null {
  const qty = lineQty(line)
  return qty ? qty.times(line.factorBase) : null
}

function qtyIssue(line: CartLine): string | null {
  if (line.qtyText.trim() === '') return 'Isi jumlah barang.'
  let qty: Decimal
  try {
    qty = parseQuantity(line.qtyText)
  } catch (err) {
    return (err as Error).message
  }
  if (qty.isZero()) return 'Jumlah harus lebih dari 0.'
  const step = new Decimal(line.saleStep)
  if (!step.isZero() && !qty.mod(step).isZero()) {
    return `Jumlah harus kelipatan ${formatQuantity(step, line.unitLabel)}.`
  }
  const base = qty.times(line.factorBase)
  const baseStep = new Decimal(line.quantityStep)
  if (base.decimalPlaces() > 3 || (!baseStep.isZero() && !base.mod(baseStep).isZero())) {
    return `Jumlah ini tidak sesuai ukuran terkecil ${formatQuantity(baseStep, line.baseUnit)}.`
  }
  return null
}

function rollIssue(line: CartLine, lines: CartLine[]): string | null {
  const position = line.position
  if (!position) return 'Pilih roll/potongan yang akan dipotong.'
  const label = position.label ?? 'tanpa label'
  if (isWholeRoll(line)) {
    const qty = lineQty(line)
    if (!qty || !qty.equals(1)) return 'Satu baris untuk satu roll utuh. Tambah baris untuk roll berikutnya.'
    const capacityOk = position.capacity !== null && new Decimal(position.capacity).equals(line.factorBase)
    if (!position.sealed || !capacityOk) {
      return `Roll utuh harus diambil dari roll yang masih bersegel ${formatQuantity(line.factorBase, line.baseUnit)}.`
    }
    if (lines.some(l => l.key !== line.key && l.position?.id === position.id)) {
      return `Roll ${label} sudah dipakai di baris lain.`
    }
    return null
  }
  const others = lines.filter(l => l.position?.id === position.id)
  if (others.some(l => l.key !== line.key && isWholeRoll(l))) {
    return `Roll ${label} sudah dijual utuh di baris lain.`
  }
  const used = others.reduce((sum, l) => sum.plus(lineBaseQty(l) ?? 0), new Decimal(0))
  if (used.greaterThan(position.qtyBase)) {
    return `Potongan ${label} hanya tersisa ${formatQuantity(position.qtyBase, line.baseUnit)}. `
      + 'Satu potongan tidak bisa disambung dengan potongan lain: pilih roll lain atau kurangi panjangnya.'
  }
  return null
}

function discountIssue(mode: DiscountMode | null, text: string): string | null {
  if (!mode) return null
  if (text.trim() === '') return 'Isi besar diskon atau pilih "Tanpa diskon".'
  try {
    if (mode === 'percent') parsePercent(text)
    else parseRupiah(text)
    return null
  } catch (err) {
    return (err as Error).message
  }
}

/** Masalah pada satu baris (kalimat awam), atau null bila siap dibayar. */
export function lineIssue(line: CartLine, lines: CartLine[]): string | null {
  if (line.unavailable) return 'Barang/satuan ini sudah tidak dijual. Hapus dari keranjang.'
  return qtyIssue(line) ?? (line.trackSegments ? rollIssue(line, lines) : null)
    ?? discountIssue(line.discountMode, line.discountText)
}

export function cartIssues(lines: CartLine[]): Map<string, string> {
  const issues = new Map<string, string>()
  for (const line of lines) {
    const issue = lineIssue(line, lines)
    if (issue) issues.set(line.key, issue)
  }
  return issues
}

export function invoiceDiscountIssue(discount: InvoiceDiscount): string | null {
  return discountIssue(discount.mode, discount.text)
}

function discountValue(mode: DiscountMode, text: string): string {
  return mode === 'percent' ? parsePercent(text).toFixed() : parseRupiah(text).toFixed(0)
}

function lineInput(line: CartLine, canDiscount: boolean): SaleLineInput {
  const qty = parseQuantity(line.qtyText).toFixed()
  const item: SaleLineInput = { product_unit_id: line.unitId, qty, expected_unit_version: line.unitVersion }
  if (line.trackSegments && line.position) {
    item.position_id = line.position.id
    item.expected_position_version = line.position.version
  }
  // STAFF tidak boleh mengirim field diskon sama sekali (termasuk "0").
  if (canDiscount && line.discountMode && line.discountText.trim() !== '') {
    item.discount_mode = line.discountMode
    item.discount_value = discountValue(line.discountMode, line.discountText)
  }
  return item
}

export type SaleDraftInput = Omit<SaleInput, 'payment' | 'reason'>

/**
 * Payload penjualan tanpa pembayaran, atau null bila keranjang belum sah.
 * Dipakai bersama oleh pratinjau dan finalisasi agar angkanya identik.
 */
export function buildSaleInput(params: {
  lines: CartLine[]
  canDiscount: boolean
  invoiceDiscount: InvoiceDiscount
  customerId: string | null
  clientReferenceId: string
}): SaleDraftInput | null {
  const { lines, canDiscount, invoiceDiscount, customerId, clientReferenceId } = params
  if (lines.length === 0 || lines.length > 100) return null
  if (cartIssues(lines).size > 0) return null
  if (canDiscount && invoiceDiscountIssue(invoiceDiscount)) return null
  const input: SaleDraftInput = {
    client_reference_id: clientReferenceId,
    items: lines.map(l => lineInput(l, canDiscount)),
  }
  if (customerId) input.customer_id = customerId
  if (canDiscount && invoiceDiscount.mode && invoiceDiscount.text.trim() !== '') {
    input.discount_mode = invoiceDiscount.mode
    input.discount_value = discountValue(invoiceDiscount.mode, invoiceDiscount.text)
  }
  return input
}

/**
 * Perbarui snapshot setelah server menolak dengan PRICE_CHANGED.
 * Baris yang harganya/satuannya berubah ditandai agar kasir memeriksa ulang.
 */
export function applyProductRefresh(lines: CartLine[], products: ProductDetail[]): CartLine[] {
  const byId = new Map(products.map(p => [p.id, p]))
  return lines.map(line => {
    const product = byId.get(line.productId)
    const activeUnits = product?.active ? product.units.filter(u => u.active) : []
    const same = activeUnits.find(u => u.id === line.unitId && u.version === line.unitVersion)
    if (same) return line
    const replacement = activeUnits.find(u => u.label === line.unitLabel)
      ?? activeUnits.find(u => u.is_default) ?? activeUnits[0]
    if (!product || !replacement) return { ...line, unavailable: true }
    const wholeRoll = product.track_segments && replacement.whole_roll
    const changedRoll = isWholeRoll(line) !== wholeRoll
    return {
      ...line,
      productName: product.name,
      specification: product.specification ?? '',
      baseUnit: product.base_unit,
      quantityStep: product.quantity_step,
      trackSegments: product.track_segments,
      unitId: replacement.id,
      unitLabel: replacement.label,
      unitVersion: replacement.version,
      factorBase: replacement.factor_base,
      wholeRoll,
      saleStep: replacement.sale_step,
      sellPrice: replacement.sell_price,
      position: changedRoll ? null : line.position,
      priceChange: line.priceChange ?? { previousPrice: line.sellPrice, previousLabel: line.unitLabel },
    }
  })
}

export function hasPendingPriceReview(lines: CartLine[]): boolean {
  return lines.some(l => l.priceChange !== null)
}

export function acknowledgePriceChanges(lines: CartLine[]): CartLine[] {
  return lines.map(l => (l.priceChange ? { ...l, priceChange: null } : l))
}

const QUICK_DENOMINATIONS = [5_000, 10_000, 20_000, 50_000, 100_000]

/**
 * Nominal uang cepat yang masuk akal untuk total ini (selalu > total, maks 4 pilihan),
 * mis. total Rp37.500 → 40.000, 50.000, 100.000. Hanya untuk mengisi kolom input.
 */
export function quickCashOptions(total: string): string[] {
  const value = new Decimal(total)
  if (value.lessThanOrEqualTo(0)) return []
  const options = new Set<string>()
  for (const denomination of QUICK_DENOMINATIONS) {
    const rounded = value.dividedBy(denomination).ceil().times(denomination)
    const candidate = rounded.equals(value) ? rounded.plus(denomination) : rounded
    options.add(candidate.toFixed(0))
  }
  return [...options]
    .filter(o => new Decimal(o).greaterThan(value))
    .sort((a, b) => new Decimal(a).comparedTo(b))
    .slice(0, 4)
}

/** Kekurangan uang tunai (untuk peringatan), atau null bila cukup/belum bisa dinilai. */
export function cashShortfall(tendered: string | null, total: string | null): string | null {
  if (tendered === null || total === null) return null
  const diff = new Decimal(total).minus(tendered)
  return diff.greaterThan(0) ? diff.toFixed(0) : null
}

/** Uraian satuan & harga, mis. "2,5 m × Rp7.500/m". */
export function lineFormula(line: CartLine, formatMoney: (v: string) => string): string {
  const qty = lineQty(line)
  const price = `${formatMoney(line.sellPrice)}/${line.unitLabel}`
  return qty ? `${formatQuantity(qty, line.unitLabel)} × ${price}` : price
}
