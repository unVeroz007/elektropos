-- P2/P3 schema: customers, service_tickets (FK target), payments, invoices,
-- cashbox, sessions, cash_movements, credit_notes, refund_allocations

-- === Tabel independen dulu ===

create table if not exists private.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  phone_normalized text,
  alternate_contact text,
  address text,
  active boolean not null default true,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now()
);
create index customers_phone on private.customers(phone_normalized) where phone_normalized is not null;

create table if not exists private.service_tickets (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  customer_id uuid references private.customers(id),
  mechanic_id uuid not null references auth.users(id),
  parent_ticket_id uuid references private.service_tickets(id),
  service_location text not null check (service_location in ('STORE','ONSITE')),
  custody_location text not null check (custody_location in ('CUSTOMER','SHOP','FATHER')),
  equipment_type text not null,
  equipment_brand text,
  equipment_model text,
  equipment_serial text,
  complaint text not null,
  initial_condition text,
  accessories text,
  address text,
  scheduled_at timestamptz,
  work_status text not null default 'NEW' check (work_status in (
    'NEW','INSPECTING','AWAITING_APPROVAL','WORKING',
    'READY','DIAMBIL','ONSITE_DONE','UNREPAIRABLE','CANCELLED')),
  terminal_reason text,
  test_result text,
  closed_at timestamptz,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now()
);

create table if not exists private.service_status_events (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references private.service_tickets(id),
  from_status text,
  to_status text not null,
  kind text not null check (kind in ('TRANSITION','CORRECTION')),
  reason text,
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now()
);

create table if not exists private.service_custody_events (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references private.service_tickets(id),
  from_location text,
  to_location text not null,
  condition_note text,
  accessories_note text,
  receiver_name text,
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now()
);

create table if not exists private.service_estimates (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references private.service_tickets(id),
  revision integer not null check (revision > 0),
  description text,
  min_amount numeric(20,0),
  max_amount numeric(20,0) not null check (max_amount >= 0),
  status text not null default 'DRAFT' check (status in (
    'DRAFT','PROPOSED','APPROVED','SUPERSEDED','REJECTED')),
  approved_limit numeric(20,0),
  approved_method text,
  approved_at timestamptz,
  approved_by uuid references auth.users(id),
  customer_consent_note text,
  version integer not null default 1 check (version > 0),
  unique (ticket_id, revision)
);

create table if not exists private.service_part_events (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references private.service_tickets(id),
  product_id uuid not null references private.products(id),
  kind text not null check (kind in ('USE','REVERSE')),
  qty_base numeric(18,3) not null check (qty_base > 0),
  charge_unit_price numeric(24,6),
  reverses_event_id uuid references private.service_part_events(id),
  reason text,
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now(),
  recognized_invoice_id uuid
);

create table if not exists private.service_charge_drafts (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references private.service_tickets(id),
  line_no integer not null check (line_no > 0),
  kind text not null check (kind in ('LABOR','VISIT','DIAGNOSIS','PART')),
  description text not null,
  quantity numeric(18,3) not null check (quantity > 0),
  unit_price numeric(24,6) not null check (unit_price >= 0),
  part_event_id uuid references private.service_part_events(id),
  version integer not null default 1 check (version > 0),
  unique (ticket_id, line_no)
);

create table if not exists private.cashboxes (
  code text primary key check (code in ('SHOP_DRAWER','FATHER_WALLET')),
  label text not null,
  custodian text not null,
  active boolean not null default true
);

create table if not exists private.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  cashbox_id text not null references private.cashboxes(code),
  opened_by uuid not null references auth.users(id),
  opened_at timestamptz not null default now(),
  business_date date not null,
  opening_amount numeric(20,0) not null check (opening_amount >= 0),
  status text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  counted_amount numeric(20,0),
  expected_snapshot numeric(20,0),
  variance numeric(20,0),
  note text,
  version integer not null default 1 check (version > 0)
);
create unique index cash_sessions_one_open on private.cash_sessions(cashbox_id) where status='OPEN';

create table if not exists private.invoices (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  kind text not null check (kind in ('SALE','SERVICE')),
  service_ticket_id uuid unique references private.service_tickets(id),
  customer_id uuid references private.customers(id),
  actor_id uuid not null references auth.users(id),
  posted_at timestamptz not null default now(),
  subtotal_net_lines numeric(20,0) not null check (subtotal_net_lines >= 0),
  discount_total numeric(20,0) not null check (discount_total >= 0),
  total numeric(20,0) not null check (total >= 0),
  client_reference_id uuid unique,
  operation_id uuid not null,
  corrects_invoice_id uuid references private.invoices(id)
);
create index invoices_posted on private.invoices(posted_at desc, id);
create index invoices_customer on private.invoices(customer_id, posted_at) where customer_id is not null;

create table if not exists private.payments (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('IN','OUT')),
  purpose text not null check (purpose in (
    'SALE_RECEIPT','SERVICE_RECEIPT','CUSTOMER_REFUND',
    'PURCHASE_PAYMENT','PAYMENT_REVERSAL','PAYMENT_REPLACEMENT')),
  invoice_id uuid references private.invoices(id),
  service_ticket_id uuid references private.service_tickets(id),
  stock_document_id uuid references private.stock_documents(id),
  original_payment_id uuid references private.payments(id),
  method text not null check (method in ('CASH','TRANSFER','QRIS')),
  amount numeric(20,0) not null check (amount >= 0),
  tendered numeric(20,0),
  change numeric(20,0),
  cash_session_id uuid references private.cash_sessions(id),
  reference text,
  confirmed_by uuid references auth.users(id),
  actor_id uuid references auth.users(id),
  occurred_at timestamptz not null default now(),
  intent_id uuid unique,
  operation_id uuid not null
);
create index payments_invoice on private.payments(invoice_id) where invoice_id is not null;
create index payments_ticket on private.payments(service_ticket_id, occurred_at) where service_ticket_id is not null;

create table if not exists private.cash_movements (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references private.cash_sessions(id),
  direction text not null check (direction in ('IN','OUT')),
  kind text not null check (kind in (
    'CUSTOMER_PAYMENT','REFUND','PURCHASE','EXPENSE',
    'OWNER_ADD','OWNER_WITHDRAW','TRANSFER','CORRECTION')),
  amount numeric(20,0) not null check (amount > 0),
  payment_id uuid unique references private.payments(id),
  transfer_group_id uuid,
  reason text,
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now(),
  operation_id uuid not null
);
create index cash_movements_session on private.cash_movements(session_id, occurred_at);

create table if not exists private.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references private.invoices(id),
  line_no integer not null check (line_no > 0),
  kind text not null check (kind in ('PRODUCT','PART','LABOR','VISIT','DIAGNOSIS')),
  product_id uuid references private.products(id),
  service_part_event_id uuid references private.service_part_events(id),
  description_snapshot text not null,
  qty_sell numeric(18,3) not null check (qty_sell > 0),
  factor_snapshot numeric(18,3) not null check (factor_snapshot > 0),
  qty_base numeric(18,3),
  unit_price_snapshot numeric(24,6) not null check (unit_price_snapshot >= 0),
  item_discount_mode text,
  item_discount_value numeric(24,6),
  gross_exact numeric(38,9) not null,
  base_net numeric(20,0) not null check (base_net >= 0),
  invoice_discount_alloc numeric(20,0) not null check (invoice_discount_alloc >= 0),
  net_total numeric(20,0) not null check (net_total >= 0),
  unique (invoice_id, line_no)
);
create index invoice_items_invoice on private.invoice_items(invoice_id);

create table if not exists private.cost_allocations (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references private.inventory_lots(id),
  origin_position_id uuid not null references private.stock_positions(id),
  invoice_item_id uuid not null references private.invoice_items(id),
  qty_base numeric(18,3) not null check (qty_base > 0),
  cost_amount numeric(24,6) not null check (cost_amount >= 0),
  reversed_qty numeric(18,3) not null default 0,
  reversed_cost numeric(24,6) not null default 0,
  occurred_at timestamptz not null default now()
);
create index cost_allocations_lot on private.cost_allocations(lot_id);
create index cost_allocations_item on private.cost_allocations(invoice_item_id);

create table if not exists private.credit_notes (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  invoice_id uuid not null references private.invoices(id),
  kind text not null check (kind in ('RETURN','PRICE_CORRECTION')),
  reason text,
  total numeric(20,0) not null check (total >= 0),
  actor_id uuid not null references auth.users(id),
  posted_at timestamptz not null default now(),
  operation_id uuid not null
);
create index credit_notes_invoice on private.credit_notes(invoice_id, posted_at);

create table if not exists private.credit_note_items (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references private.credit_notes(id),
  invoice_item_id uuid not null references private.invoice_items(id),
  qty_return_base numeric(18,3),
  amount numeric(20,0) not null check (amount >= 0),
  cost_reversal_amount numeric(24,6) not null default 0,
  disposition text not null check (disposition in ('SALEABLE','DAMAGED','NONE')),
  line_no integer not null check (line_no > 0),
  unique (credit_note_id, invoice_item_id)
);

create table if not exists private.return_cost_allocations (
  id uuid primary key default gen_random_uuid(),
  credit_item_id uuid not null references private.credit_note_items(id),
  original_cost_allocation_id uuid not null references private.cost_allocations(id),
  qty_base numeric(18,3) not null check (qty_base > 0),
  cost_amount numeric(24,6) not null check (cost_amount >= 0),
  target_position_id uuid not null references private.stock_positions(id)
);

create table if not exists private.refund_allocations (
  id uuid primary key default gen_random_uuid(),
  refund_payment_id uuid not null references private.payments(id),
  original_payment_id uuid not null references private.payments(id),
  amount numeric(20,0) not null check (amount > 0),
  credit_note_id uuid references private.credit_notes(id),
  unique (refund_payment_id, original_payment_id)
);

create table if not exists private.service_cost_recognitions (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references private.invoices(id),
  part_event_id uuid not null unique references private.service_part_events(id),
  cost_amount numeric(24,6) not null check (cost_amount >= 0)
);

-- === RLS untuk semua tabel ===
do $$ declare t text; begin
  for t in select unnest(array[
    'customers','service_tickets','service_status_events','service_custody_events',
    'service_estimates','service_part_events','service_charge_drafts',
    'cashboxes','cash_sessions','invoices','payments','cash_movements',
    'invoice_items','cost_allocations','credit_notes','credit_note_items',
    'return_cost_allocations','refund_allocations','service_cost_recognitions'])
  loop execute format('alter table private.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema private from public, anon, authenticated;

-- === FK tertunda: service_part_events ke invoices (dibuat setelah invoices ada) ===
alter table private.service_part_events
  add constraint service_part_events_invoice_fk
  foreign key (recognized_invoice_id) references private.invoices(id);
