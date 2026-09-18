/** Bentuk keluaran `get_report_v1` dan `get_dashboard_v1` (kontrak-stok-laporan-foto.md). Uang = string. */

export type ByMethod = { CASH: string; TRANSFER: string; QRIS: string }

export type RevenueSummary = {
  sales: { invoice_total: string; invoice_count: number; credit_total: string; credit_count: number; net: string }
  service: { invoice_total: string; invoice_count: number; credit_total: string; credit_count: number; net: string }
  customer_receipts: {
    total: string; by_method: ByMethod; sale: string; service: string; deposit_total: string; deposit_by_method: ByMethod
  }
  customer_refunds: { total: string; by_method: ByMethod; sale: string; service: string }
  net_customer_receipts: string
  payment_corrections: { reversal_total: string; replacement_total: string; net: string; net_by_method: ByMethod }
  net_by_method: ByMethod
}

/** Bagian modal & laba: tidak dikirim server untuk karyawan (D2). */
export type CostSummary = {
  cost: {
    sale_cogs_allocated: string; sale_cogs_reversed: string; sale_cogs_net: string
    service_cogs_recognized: string; service_cogs_reversed: string; service_cogs_net: string
    cogs_net: string; rounding: string
  }
  gross_profit: { sale: string; service: string; total: string; note: string }
  stock_losses: { disposal_cost: string; adjustment_out_cost: string; adjustment_in_cost: string; note: string }
  supplier_returns?: { count: number; claim_value: string; settlement_difference: string; pending_claim_value: string; note: string }
}

export type Report = RevenueSummary & Partial<CostSummary> & {
  period: { start_date: string; end_date: string }
}

export type DashboardCashSession = {
  cashbox: string
  label: string
  open: boolean
  session_id: string | null
  opened_at: string | null
  business_date: string | null
  opened_by: string | null
  expected_amount?: string
}

export type DashboardTicket = {
  ticket_id: string
  number: string
  customer_name: string | null
  equipment_type?: string
  work_status: string
  custody_location?: string
  address?: string | null
  scheduled_at?: string
}

export type Dashboard = {
  refreshed_at: string
  server_date: string
  today: RevenueSummary
  cash_sessions: DashboardCashSession[]
  service: {
    active_by_status: Record<string, number>
    active_total: number
    not_picked_up_count: number
    not_picked_up: DashboardTicket[]
    scheduled_today: DashboardTicket[]
  }
  low_stock: number
  low_stock_items: { product_id: string; sku: string; name: string; base_unit: string; stock_shop: string; min_stock: string }[]
  backup: {
    last_status: string | null
    last_started_at: string | null
    last_completed_at: string | null
    last_success_at: string | null
    age_hours: string | number | null
    stale: boolean
  }
}
