/** Bentuk data produk dari `search_products_v1` / `get_product_v1` (kontrak-sales). */

export type ProductUnit = {
  id: string
  label: string
  factor_base: string
  sale_step: string
  sell_price: string
  is_default: boolean
  version: number
  active?: boolean
}

export type ProductSummary = {
  id: string
  sku: string
  name: string
  specification: string
  base_unit: string
  shelf: string | null
  track_segments: boolean
  quantity_step: string
  category_id: string | null
  version: number
  units: ProductUnit[]
  stock_shop: string
  stock_field: string
}

export type ProductPosition = {
  id: string
  label: string | null
  location: string
  condition: string
  qty_base: string
  segment_capacity: string | null
  sealed: boolean
  version: number
}

export type ProductLot = {
  id: string
  posted_at: string
  remaining_qty: string
  remaining_cost: string
}

export type ProductDetail = Omit<ProductSummary, 'stock_shop' | 'stock_field'> & {
  active: boolean
  barcodes: { code: string; unit_id: string | null }[]
  positions: ProductPosition[]
  /** Hanya untuk akun yang boleh melihat modal. */
  lots?: ProductLot[]
}

export type Category = { id: string; name: string }

/** Satuan jual aktif default (atau satuan pertama). */
export function defaultUnit(product: { units: ProductUnit[] }): ProductUnit | undefined {
  const active = product.units.filter(u => u.active !== false)
  return active.find(u => u.is_default) ?? active[0]
}

/** Nama tampilan: nama + spesifikasi pembeda (UX-01). */
export function productTitle(product: { name: string; specification?: string | null }): string {
  return product.specification ? `${product.name} — ${product.specification}` : product.name
}
