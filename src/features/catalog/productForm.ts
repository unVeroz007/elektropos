import Decimal from 'decimal.js'
import { parseQuantity, parseRupiah } from '../../lib/numbers'
import { defaultUnit, type ProductDetail } from '../../components/productTypes'

export type ProductFormState = {
  sku: string
  name: string
  specification: string
  category_id: string
  shelf: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  unit_label: string
  factor_base: string
  sale_step: string
  sell_price: string
  barcode: string
  reason: string
}

export type ProductKind = 'PCS' | 'METER' | 'OTHER'

/** Isian awal sesuai jenis barang, agar ayah tidak perlu memahami faktor/langkah. */
export const KIND_PRESETS: Record<Exclude<ProductKind, 'OTHER'>, Partial<ProductFormState>> = {
  PCS: { base_unit: 'pcs', quantity_step: '1', track_segments: false, unit_label: 'pcs', factor_base: '1', sale_step: '1' },
  METER: { base_unit: 'm', quantity_step: '0.1', track_segments: true, unit_label: 'm', factor_base: '1', sale_step: '0.1' },
}

export const EMPTY_FORM: ProductFormState = {
  sku: '', name: '', specification: '', category_id: '', shelf: '',
  base_unit: 'pcs', quantity_step: '1', track_segments: false,
  unit_label: 'pcs', factor_base: '1', sale_step: '1', sell_price: '', barcode: '', reason: '',
}

const plain = (value: string) => new Decimal(value).toFixed()

export function formFromProduct(product: ProductDetail): ProductFormState {
  const unit = defaultUnit(product)
  return {
    ...EMPTY_FORM,
    sku: product.sku,
    name: product.name,
    specification: product.specification ?? '',
    category_id: product.category_id ?? '',
    shelf: product.shelf ?? '',
    base_unit: product.base_unit,
    quantity_step: plain(product.quantity_step),
    track_segments: product.track_segments,
    unit_label: unit?.label ?? '',
    factor_base: unit ? plain(unit.factor_base) : '1',
    sale_step: unit ? plain(unit.sale_step) : '1',
    sell_price: unit ? new Decimal(unit.sell_price).toFixed() : '',
  }
}

function sameNumber(a: string, b: string, parse: (v: string) => Decimal): boolean {
  try {
    return parse(a).equals(parse(b))
  } catch {
    // Isian belum sah: dianggap berubah; kesalahan ditampilkan oleh formErrors.
    return false
  }
}

/** Satuan/harga berubah → server membuat versi satuan baru (kontrak upsert_product_v1). */
export function unitChanged(original: ProductFormState, current: ProductFormState): boolean {
  return original.unit_label.trim() !== current.unit_label.trim()
    || !sameNumber(original.factor_base, current.factor_base, parseQuantity)
    || !sameNumber(original.sale_step, current.sale_step, parseQuantity)
    || !sameNumber(original.sell_price, current.sell_price, parseRupiah)
}

export function formErrors(state: ProductFormState): string[] {
  const errors: string[] = []
  if (!state.sku.trim()) errors.push('Kode barang wajib diisi.')
  if (!state.name.trim()) errors.push('Nama barang wajib diisi.')
  if (!state.base_unit.trim()) errors.push('Satuan stok wajib diisi.')
  if (!state.unit_label.trim()) errors.push('Satuan jual wajib diisi.')
  const numbers: [string, string, (v: string) => Decimal][] = [
    ['Kelipatan stok', state.quantity_step, parseQuantity],
    ['Isi per satuan jual', state.factor_base, parseQuantity],
    ['Kelipatan jual', state.sale_step, parseQuantity],
    ['Harga jual', state.sell_price, parseRupiah],
  ]
  for (const [label, value, parse] of numbers) {
    try {
      const n = parse(value)
      if (label !== 'Harga jual' && n.isZero()) errors.push(`${label} harus lebih dari nol.`)
    } catch (err) {
      errors.push(`${label}: ${(err as Error).message}`)
    }
  }
  if (errors.length === 0) {
    const perSale = parseQuantity(state.sale_step).mul(parseQuantity(state.factor_base))
    if (!perSale.mod(parseQuantity(state.quantity_step)).isZero()) {
      errors.push('Kelipatan jual × isi per satuan harus kelipatan dari kelipatan stok.')
    }
  }
  return errors
}

/** Payload `upsert_product_v1` (tanpa operation_id). Panggil hanya bila formErrors kosong. */
export function buildProductPayload(state: ProductFormState, product?: ProductDetail): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    sku: state.sku.trim(),
    name: state.name.trim(),
    specification: state.specification.trim(),
    base_unit: state.base_unit.trim(),
    quantity_step: parseQuantity(state.quantity_step).toFixed(),
    track_segments: state.track_segments,
    unit_label: state.unit_label.trim(),
    factor_base: parseQuantity(state.factor_base).toFixed(),
    sale_step: parseQuantity(state.sale_step).toFixed(),
    sell_price: parseRupiah(state.sell_price).toFixed(0),
    shelf: state.shelf.trim() || null,
    category_id: state.category_id || null,
  }
  if (state.reason.trim()) payload.reason = state.reason.trim()
  if (product) {
    payload.product_id = product.id
    payload.expected_version = product.version
  } else if (state.barcode.trim()) {
    payload.barcode = state.barcode.trim()
  }
  return payload
}
