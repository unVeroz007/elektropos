/**
 * Bentuk data server untuk modul penjualan (lihat docs/audit/kontrak-sales.md).
 * Semua angka uang/kuantitas berupa string desimal kanonik dari server.
 */

export type PaymentMethod = 'CASH' | 'TRANSFER' | 'QRIS'
export type DiscountMode = 'percent' | 'amount'
export type Disposition = 'SALEABLE' | 'DAMAGED' | 'NONE'
export type PaymentStatus = 'UNPAID' | 'PARTIAL' | 'PAID' | 'REFUND_DUE'

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

/** Item hasil `search_products_v1`. */
export type ProductSearchItem = {
  id: string
  sku: string
  name: string
  specification: string
  base_unit: string
  shelf: string | null
  track_segments: boolean
  quantity_step: string
  version: number
  units: ProductUnit[]
  stock_shop: string
  stock_field: string
}

/** Hasil `get_product_v1` (bagian yang dipakai modul penjualan). */
export type ProductDetail = {
  id: string
  name: string
  specification: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  active: boolean
  units: (ProductUnit & { active: boolean })[]
}

/** Hasil `find_by_barcode_v1`. */
export type BarcodeLookup =
  | { found: false; code: string }
  | {
    found: true
    code: string
    product_id: string
    sku: string
    name: string
    specification: string
    base_unit: string
    quantity_step: string
    track_segments: boolean
    shelf: string | null
    unit_id: string
    unit_label: string
    factor_base: string
    sale_step: string
    sell_price: string
    unit_version: number
    stock_shop: string
  }

export type SellablePosition = {
  position_id: string
  label: string | null
  qty_base: string
  segment_capacity: string | null
  sealed: boolean
  version: number
  received_at: string
}

export type SellablePositions = {
  product_id: string
  base_unit: string
  track_segments: boolean
  positions: SellablePosition[]
}

export type SaleLineInput = {
  product_unit_id: string
  qty: string
  expected_unit_version: number
  position_id?: string
  expected_position_version?: number
  discount_mode?: DiscountMode
  discount_value?: string
}

export type SalePaymentInput =
  | { method: 'CASH'; tendered: string }
  | { method: 'TRANSFER' | 'QRIS'; confirmed: true; reference?: string }

export type SaleInput = {
  client_reference_id: string
  customer_id?: string
  items: SaleLineInput[]
  discount_mode?: DiscountMode
  discount_value?: string
  reason?: string
  payment?: SalePaymentInput | null
}

export type PreviewLine = {
  line_no: number
  product_id: string
  product_unit_id: string
  unit_version: number
  description: string
  unit_label: string
  track_segments: boolean
  position_id: string | null
  qty_sell: string
  qty_base: string
  unit_price: string
  gross_exact: string
  line_discount: string
  base_net: string
  invoice_discount_alloc: string
  net_total: string
  available_base: string
}

export type SalePreview = {
  ok: true
  subtotal: string
  discount: string
  total: string
  requires_owner_reason: boolean
  tendered: string | null
  change: string | null
  items: PreviewLine[]
}

export type FinalizeResult = {
  ok: true
  entity_id: string
  document_number: string
  total: string
  change: string
  payment_method: PaymentMethod | null
}

export type InvoiceItem = {
  id: string
  line_no: number
  kind: string
  product_id: string | null
  product_unit_id: string | null
  description: string
  unit_label: string | null
  qty_sell: string
  factor: string
  qty_base: string
  unit_price: string
  discount_mode: DiscountMode | null
  discount_value: string | null
  line_discount: string
  base_net: string
  invoice_discount_alloc: string
  net_total: string
  returned_qty: string
  returnable_qty: string
  cost_allocations?: CostAllocation[]
}

export type CostAllocation = {
  id: string
  lot_id: string
  lot_posted_at: string
  origin_position_id: string
  origin_label: string | null
  qty_base: string
  reversed_qty: string
}

export type InvoicePayment = {
  id: string
  direction: 'IN' | 'OUT'
  purpose: string
  method: PaymentMethod
  amount: string
  tendered: string | null
  change: string | null
  reference: string | null
  actor_name: string | null
  occurred_at: string
}

export type InvoiceCredit = {
  id: string
  number: string
  kind: string
  reason: string | null
  total: string
  posted_at: string
  actor_name: string | null
  refunds: { payment_id: string; method: PaymentMethod; amount: string; occurred_at: string }[]
}

export type InvoiceMoney = {
  credit_total: string
  invoice_net: string
  received: string
  refunded: string
  net_received: string
  outstanding: string
  refund_due: string
  payment_status: PaymentStatus
}

export type Invoice = {
  id: string
  number: string
  kind: 'SALE' | 'SERVICE'
  posted_at: string
  cashier_name: string | null
  customer: { id: string; name: string } | null
  subtotal_net_lines: string
  discount_total: string
  total: string
  free_reason: string | null
  money: InvoiceMoney
  items: InvoiceItem[]
  payments: InvoicePayment[]
  credits: InvoiceCredit[]
}

export type InvoiceListItem = {
  id: string
  number: string
  kind: 'SALE' | 'SERVICE'
  posted_at: string
  total: string
  cashier_name: string | null
  customer_name: string | null
  payment_methods: PaymentMethod[] | null
  has_return: boolean
  payment_status: PaymentStatus
}

export type ShopSettings = {
  name: string
  address: string
  phone: string
  receipt_width: number
}

export type CustomerSummary = {
  id: string
  name: string
  phone: string | null
}

export type CashDrawerStatus = { open: boolean }

export type ReturnLineInput = {
  invoice_item_id: string
  qty_base: string
  disposition: Disposition
  allocations?: { cost_allocation_id: string; qty_base: string }[]
  label?: string
}

export type ReturnInput = {
  invoice_id: string
  reason: string
  refund_method?: PaymentMethod
  refund_reference?: string
  items: ReturnLineInput[]
}

export type ReturnResult = {
  ok: true
  entity_id: string
  document_number: string
  refund_total: string
  refund_method: PaymentMethod | null
}
