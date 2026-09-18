/**
 * Bentuk data RPC servis & pelanggan (docs/audit/kontrak-servis.md).
 * Semua nilai uang/qty berupa string desimal dari server.
 */

export type WorkStatus =
  | 'NEW' | 'INSPECTING' | 'AWAITING_APPROVAL' | 'WAITING_PARTS' | 'WORKING'
  | 'READY' | 'UNREPAIRABLE' | 'CANCELLED'

export type ServiceLocation = 'STORE' | 'ONSITE'
export type Custody = 'CUSTOMER' | 'SHOP' | 'FATHER'
export type PaymentStatus = 'UNPRICED' | 'UNPAID' | 'PARTIAL' | 'PAID' | 'REFUND_DUE'
export type PayMethod = 'CASH' | 'TRANSFER' | 'QRIS'
export type Cashbox = 'SHOP_DRAWER' | 'FATHER_WALLET'
export type ApprovalMethod = 'IN_PERSON' | 'PHONE' | 'WHATSAPP' | 'OTHER'
export type ChargeKind = 'LABOR' | 'PART' | 'VISIT' | 'DIAGNOSIS'
export type StockLocation = 'SHOP' | 'FIELD_FATHER'
export type StockCondition = 'SALEABLE' | 'DAMAGED'

export type TicketListItem = {
  id: string
  number: string
  customer_id: string | null
  customer_name: string | null
  customer_phone: string | null
  customer_alt_contact: string | null
  equipment_type: string
  equipment_brand: string | null
  equipment_model: string | null
  complaint: string
  work_status: WorkStatus
  service_location: ServiceLocation
  custody_location: Custody
  scheduled_at: string | null
  parent_ticket_id: string | null
  created_at: string
  closed_at: string | null
  version: number
  not_picked_up: boolean
  payment_status: PaymentStatus
  invoice_total: string | null
  net_received: string | null
  outstanding: string | null
  refund_due: string | null
}

export type TicketPage = { items: TicketListItem[]; next_cursor: string | null }

export type PaymentState = {
  status: PaymentStatus
  invoice_id: string | null
  invoice_number: string | null
  invoice_total: string | null
  credit_total: string | null
  invoice_net: string | null
  received_total: string | null
  refunded_total: string | null
  correction_net: string | null
  net_received: string | null
  outstanding: string | null
  refund_due: string | null
}

export type CustomerRef = {
  id: string
  name: string
  phone: string | null
  alternate_contact: string | null
  address: string | null
  version: number
}

export type StatusEvent = {
  from_status: WorkStatus | null
  to_status: WorkStatus
  kind: string
  reason: string | null
  actor_name: string | null
  occurred_at: string
}

export type CustodyEvent = {
  from_location: Custody | null
  to_location: Custody
  condition_note: string | null
  accessories_note: string | null
  receiver_name: string | null
  is_handover: boolean
  actor_name: string | null
  occurred_at: string
}

export type Estimate = {
  id: string
  revision: number
  description: string
  min_amount: string | null
  max_amount: string
  status: 'PROPOSED' | 'APPROVED' | 'SUPERSEDED' | string
  approved_limit: string | null
  approved_method: ApprovalMethod | null
  approved_at: string | null
  approved_by_name: string | null
  consent_note: string | null
  version: number
}

export type PartEvent = {
  id: string
  kind: 'USE' | 'REVERSE'
  product_id: string
  product_name: string
  sku: string
  base_unit: string
  qty: string
  net_qty: string | null
  charge_unit_price: string | null
  reverses_event_id: string | null
  reason: string | null
  actor_name: string | null
  occurred_at: string
  invoiced: boolean
  source_location: StockLocation | null
  source_label: string | null
  cost: string | null
}

export type PaymentRecord = {
  id: string
  direction: 'IN' | 'OUT'
  purpose: string
  method: PayMethod
  amount: string
  tendered: string | null
  change: string | null
  cashbox: Cashbox | null
  reference: string | null
  original_payment_id: string | null
  actor_name: string | null
  occurred_at: string
}

export type InvoiceItem = {
  id: string
  line_no: number
  kind: ChargeKind
  description: string
  quantity: string
  unit_price: string
  net_total: string
  service_part_event_id: string | null
  credited: string
}

export type Invoice = {
  id: string
  number: string
  total: string
  posted_at: string
  items: InvoiceItem[]
  credit_notes: { id: string; number: string; total: string; reason: string; posted_at: string }[]
  cost_recognized: string | null
}

export type TicketDetail = {
  id: string
  number: string
  version: number
  work_status: WorkStatus
  service_location: ServiceLocation
  custody_location: Custody
  equipment_type: string
  equipment_brand: string | null
  equipment_model: string | null
  equipment_serial: string | null
  complaint: string
  initial_condition: string | null
  accessories: string | null
  address: string | null
  scheduled_at: string | null
  terminal_reason: string | null
  test_result: string | null
  created_at: string
  closed_at: string | null
  mechanic_name: string | null
  customer: CustomerRef | null
  parent_ticket: { id: string; number: string; work_status: WorkStatus; created_at: string; closed_at: string | null } | null
  child_tickets: { id: string; number: string; work_status: WorkStatus; created_at: string }[]
  not_picked_up: boolean
  allowed_transitions: WorkStatus[]
  approval: {
    latest_revision: number | null
    latest_status: string | null
    active: boolean | null
    approved_revision: number | null
    approved_limit: string | null
  }
  status_events: StatusEvent[]
  custody_events: CustodyEvent[]
  estimates: Estimate[]
  part_events: PartEvent[]
  payments: PaymentRecord[]
  invoice: Invoice | null
  payment: PaymentState
}

/** Keluaran umum perintah tulis tiket. */
export type CommandResult = { ok: boolean; entity_id?: string; version: number }

export type PaymentResult = CommandResult & {
  payment_id: string
  purpose: 'DEPOSIT' | 'SETTLEMENT'
  method: PayMethod
  cashbox: Cashbox | null
  amount: string
  tendered: string | null
  change: string | null
  occurred_at: string
  ticket_number: string
  actor_name: string | null
  payment: PaymentState
}

export type CustomerSearchRow = CustomerRef & { open_tickets: number; last_ticket_at: string | null }

export type SimilarCustomer = CustomerRef & { match: ('PHONE' | 'NAME')[] }

export type CustomerHistory = {
  customer: CustomerRef
  tickets: {
    id: string
    number: string
    equipment_type: string
    complaint: string
    work_status: WorkStatus
    service_location: ServiceLocation
    parent_ticket_id: string | null
    created_at: string
    closed_at: string | null
    payment_status: PaymentStatus
    invoice_total: string | null
  }[]
  sale_invoices: { id: string; number: string; posted_at: string; total: string }[]
}

export type StockPositionRow = {
  position_id: string
  version: number
  product_id: string
  sku: string
  name: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  location: StockLocation | string
  condition: StockCondition | string
  qty_base: string
  label: string | null
  segment_capacity: string | null
  sealed: boolean | null
}

export type ShopSettings = { name: string; address: string | null; phone: string | null }
