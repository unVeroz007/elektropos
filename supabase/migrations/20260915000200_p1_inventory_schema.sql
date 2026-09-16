create table private.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null check (length(trim(sku)) between 1 and 60),
  name text not null check (length(trim(name)) between 1 and 150),
  specification text not null default '',
  aliases text[] not null default '{}',
  category text,
  base_unit text not null check (length(trim(base_unit)) between 1 and 30),
  quantity_step numeric(18,3) not null check (quantity_step > 0),
  track_segments boolean not null default false,
  min_stock numeric(18,3) not null default 0 check (min_stock >= 0),
  shelf text,
  active boolean not null default true,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now()
);
create unique index products_sku_ci on private.products(lower(sku));
create index products_search on private.products(lower(name), id) where active;

create table private.product_units (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references private.products(id),
  label text not null check (length(trim(label)) between 1 and 40),
  factor_base numeric(18,3) not null check (factor_base > 0 and factor_base <= 1000000),
  sale_step numeric(18,3) not null check (sale_step > 0),
  sell_price numeric(24,6) not null check (sell_price > 0 and sell_price <= 999999999999.999999),
  is_default boolean not null default false,
  active boolean not null default true,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  unique (id, product_id)
);
create unique index product_units_default on private.product_units(product_id) where is_default and active;
create index product_units_product on private.product_units(product_id, active);

create table private.product_barcodes (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references private.products(id),
  product_unit_id uuid,
  code text not null unique check (code = trim(code) and length(code) between 1 and 100),
  foreign key (product_unit_id, product_id) references private.product_units(id, product_id)
);
create index product_barcodes_product on private.product_barcodes(product_id);

create table private.product_price_history (
  id bigint generated always as identity primary key,
  unit_id uuid not null references private.product_units(id),
  before_price numeric(24,6),
  after_price numeric(24,6) not null,
  reason text,
  actor_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table private.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  contact text
);

create table private.operations (
  actor_id uuid not null references auth.users(id),
  command text not null,
  operation_id uuid not null,
  payload jsonb not null,
  result jsonb not null,
  committed_at timestamptz not null default now(),
  primary key (actor_id, command, operation_id)
);

create table private.stock_documents (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  kind text not null check (kind in ('RECEIPT','OPENING','TRANSFER','ADJUSTMENT','COUNT','DISPOSAL','REVERSAL')),
  status text not null default 'POSTED' check (status in ('DRAFT','POSTED')),
  supplier_id uuid references private.suppliers(id),
  source_note text,
  source_date date,
  posted_at timestamptz not null default now(),
  actor_id uuid not null references auth.users(id),
  reason text,
  corrects_document_id uuid references private.stock_documents(id),
  operation_id uuid not null,
  version integer not null default 1
);
create index stock_documents_posted on private.stock_documents(posted_at desc, id);

create table private.stock_document_items (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references private.stock_documents(id),
  line_no integer not null check (line_no > 0),
  product_id uuid not null references private.products(id),
  unit_snapshot text not null,
  qty_input numeric(18,3) not null check (qty_input > 0),
  factor_snapshot numeric(18,3) not null check (factor_snapshot > 0),
  qty_base numeric(18,3) not null check (qty_base > 0),
  acquisition_cost numeric(24,6),
  source_location text,
  destination_location text,
  condition text,
  note text,
  unique (document_id, line_no)
);
create index stock_document_items_product on private.stock_document_items(product_id);

create table private.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references private.products(id),
  origin_item_id uuid not null unique references private.stock_document_items(id),
  posted_at timestamptz not null default now(),
  original_qty numeric(18,3) not null check (original_qty > 0),
  original_cost numeric(24,6) not null check (original_cost >= 0),
  remaining_qty numeric(18,3) not null check (remaining_qty >= 0),
  remaining_cost numeric(24,6) not null check (remaining_cost >= 0),
  version integer not null default 1,
  check ((remaining_qty = 0) = (remaining_cost = 0) or remaining_cost = 0)
);
create index inventory_lots_fifo on private.inventory_lots(product_id, posted_at, id);

create table private.stock_positions (
  id uuid primary key default gen_random_uuid(),
  lot_id uuid not null references private.inventory_lots(id),
  location text not null check (location in ('SHOP','FIELD_FATHER')),
  condition text not null check (condition in ('SALEABLE','DAMAGED')),
  qty_base numeric(18,3) not null check (qty_base >= 0),
  label text unique,
  segment_capacity numeric(18,3),
  sealed boolean not null default false,
  version integer not null default 1,
  check (not sealed or (segment_capacity is not null and qty_base = segment_capacity)),
  check (segment_capacity is null or segment_capacity > 0)
);
create index stock_positions_available on private.stock_positions(lot_id, location, condition, id) where qty_base > 0;

create table private.stock_movements (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  lot_id uuid not null references private.inventory_lots(id),
  position_id uuid not null references private.stock_positions(id),
  qty_delta numeric(18,3) not null check (qty_delta <> 0),
  cost_delta numeric(24,6) not null default 0,
  kind text not null check (kind in ('RECEIPT','OPENING','TRANSFER_OUT','TRANSFER_IN','ADJUST_OUT','ADJUST_IN','COUNT_OUT','COUNT_IN','DISPOSAL')),
  stock_document_item_id uuid not null references private.stock_document_items(id),
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now(),
  operation_id uuid not null
);
create index stock_movements_lot on private.stock_movements(lot_id, occurred_at, id);
create index stock_movements_position on private.stock_movements(position_id, occurred_at, id);
create index stock_movements_source on private.stock_movements(stock_document_item_id);

create table private.stock_counts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  status text not null default 'DRAFT' check (status in ('DRAFT','POSTED')),
  created_at timestamptz not null default now(),
  posted_document_id uuid references private.stock_documents(id)
);
create table private.stock_count_items (
  count_id uuid not null references private.stock_counts(id),
  position_id uuid not null references private.stock_positions(id),
  expected_version integer not null,
  system_qty numeric(18,3) not null,
  counted_qty numeric(18,3) not null check (counted_qty >= 0),
  reason text,
  primary key (count_id, position_id)
);

alter table private.products enable row level security;
alter table private.product_units enable row level security;
alter table private.product_barcodes enable row level security;
alter table private.product_price_history enable row level security;
alter table private.suppliers enable row level security;
alter table private.operations enable row level security;
alter table private.stock_documents enable row level security;
alter table private.stock_document_items enable row level security;
alter table private.inventory_lots enable row level security;
alter table private.stock_positions enable row level security;
alter table private.stock_movements enable row level security;
alter table private.stock_counts enable row level security;
alter table private.stock_count_items enable row level security;
revoke all on all tables in schema private from public, anon, authenticated;
