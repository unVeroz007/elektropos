-- Perbaikan audit 2026-09: kas, pembelian, distributor (skema + jaring pengaman DB).
-- Temuan: K10, K11, S09, T08, D1, D3, D5, R01.

-- Helper input umum --------------------------------------------------------

-- Tolak field yang tidak dikenal agar klien tidak dapat menyelundupkan
-- parameter (mis. cash_session_id) yang diabaikan diam-diam.
create or replace function private.input_keys_only(p_obj jsonb, p_allowed text[], p_what text)
returns void language plpgsql immutable set search_path = '' as $$
declare v_unknown text;
begin
  if p_obj is null or jsonb_typeof(p_obj) <> 'object' then
    raise exception 'INVALID_INPUT: Data % harus berupa objek', p_what using errcode = '22023';
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_obj) k where not (k = any (p_allowed));
  if v_unknown is not null then
    raise exception 'INVALID_INPUT: Field tidak dikenal pada %: %', p_what, v_unknown using errcode = '22023';
  end if;
end $$;

create or replace function private.input_uuid(p_value jsonb, p_field text, p_required boolean default true)
returns uuid language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null'
     or (jsonb_typeof(p_value) = 'string' and trim(p_value #>> '{}') = '') then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_field using errcode = '22023';
    end if;
    return null;
  end if;
  v_text := p_value #>> '{}';
  if jsonb_typeof(p_value) <> 'string'
     or v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'INVALID_INPUT: % tidak sah', p_field using errcode = '22023';
  end if;
  return v_text::uuid;
end $$;

create or replace function private.input_version(p_value jsonb)
returns integer language plpgsql immutable set search_path = '' as $$
declare v_text text := p_value #>> '{}';
begin
  if p_value is null or jsonb_typeof(p_value) not in ('number', 'string')
     or v_text !~ '^[1-9][0-9]{0,8}$' then
    raise exception 'INVALID_INPUT: expected_version wajib berupa bilangan bulat positif' using errcode = '22023';
  end if;
  return v_text::integer;
end $$;

-- Teks opsional/wajib; spasi di tepi dibuang, string kosong = NULL.
create or replace function private.input_text(p_value jsonb, p_field text, p_max integer, p_required boolean default false)
returns text language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is not null and jsonb_typeof(p_value) not in ('string', 'null') then
    raise exception 'INVALID_INPUT: % harus berupa teks', p_field using errcode = '22023';
  end if;
  v_text := nullif(trim(p_value #>> '{}'), '');
  if v_text is null and p_required then
    raise exception 'INVALID_INPUT: % wajib diisi', p_field using errcode = '22023';
  end if;
  if length(v_text) > p_max then
    raise exception 'INVALID_INPUT: % maksimal % karakter', p_field, p_max using errcode = '22023';
  end if;
  return v_text;
end $$;

-- decimal_input dengan nama field pada pesan agar pengguna tahu isian mana yang salah.
create or replace function private.input_decimal(
  p_value jsonb, p_scale integer, p_max numeric, p_positive boolean, p_field text)
returns numeric language plpgsql immutable set search_path = '' as $$
begin
  return private.decimal_input(p_value, p_scale, p_max, p_positive);
exception when sqlstate '22023' then
  raise exception 'INVALID_NUMBER: %: %', p_field, regexp_replace(sqlerrm, '^INVALID_NUMBER: ', '')
    using errcode = '22023';
end $$;

create or replace function private.input_bool(p_value jsonb, p_field text, p_default boolean)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then return p_default; end if;
  if jsonb_typeof(p_value) <> 'boolean' then
    raise exception 'INVALID_INPUT: % harus true/false', p_field using errcode = '22023';
  end if;
  return (p_value #>> '{}')::boolean;
end $$;

create or replace function private.cash_cashbox_input(p_value jsonb, p_field text default 'cashbox_code')
returns text language plpgsql immutable set search_path = '' as $$
declare v_code text := p_value #>> '{}';
begin
  if p_value is null or jsonb_typeof(p_value) <> 'string' or v_code not in ('SHOP_DRAWER', 'FATHER_WALLET') then
    raise exception 'INVALID_INPUT: % wajib SHOP_DRAWER (laci toko) atau FATHER_WALLET (dompet ayah)', p_field
      using errcode = '22023';
  end if;
  return v_code;
end $$;

-- Format Rupiah untuk pesan error: 1500000 -> "Rp1.500.000".
create or replace function private.cash_rupiah(p_amount numeric)
returns text language sql immutable set search_path = '' as $$
  select case when p_amount < 0 then '-' else '' end || 'Rp' ||
    replace(to_char(abs(round(p_amount, 0)), 'FM999,999,999,999,999,990'), ',', '.')
$$;

create or replace function private.cash_kind_label(p_kind text, p_direction text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind
    when 'CUSTOMER_PAYMENT' then 'Pembayaran pelanggan'
    when 'REFUND' then 'Uang dikembalikan ke pelanggan'
    when 'PURCHASE' then 'Pembelian barang'
    when 'EXPENSE' then 'Biaya operasional'
    when 'OWNER_ADD' then 'Tambah uang kas oleh pemilik'
    when 'OWNER_WITHDRAW' then 'Ambil uang kas oleh pemilik'
    when 'TRANSFER' then case p_direction when 'IN' then 'Pindahan kas masuk' else 'Pindahan kas keluar' end
    when 'CORRECTION' then case p_direction when 'IN' then 'Koreksi bayar: uang masuk' else 'Koreksi bayar: uang keluar' end
    when 'SUPPLIER_REFUND' then 'Uang kembali dari distributor'
    else p_kind end
$$;

do $$ declare f text; begin
  foreach f in array array[
    'private.input_keys_only(jsonb,text[],text)', 'private.input_uuid(jsonb,text,boolean)',
    'private.input_version(jsonb)', 'private.input_text(jsonb,text,integer,boolean)',
    'private.input_decimal(jsonb,integer,numeric,boolean,text)', 'private.input_bool(jsonb,text,boolean)',
    'private.cash_cashbox_input(jsonb,text)', 'private.cash_rupiah(numeric)', 'private.cash_kind_label(text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
end $$;

-- Perluas CHECK daftar nilai tanpa menghapus nilai yang sudah ada -----------
-- Nilai lama dibaca dari definisi constraint sehingga tambahan dari migrasi
-- lain (yang diterapkan lebih dulu) tetap dipertahankan.
do $$
declare
  v_spec record; v_def text; v_values text[];
begin
  for v_spec in select * from (values
    ('private.cash_movements'::regclass, 'cash_movements_kind_check', 'kind', array['SUPPLIER_REFUND']),
    ('private.purchase_payments'::regclass, 'purchase_payments_method_check', 'method', array['CASH', 'SUPPLIER_CREDIT']),
    ('private.stock_documents'::regclass, 'stock_documents_kind_check', 'kind', array['SUPPLIER_RETURN', 'SUPPLIER_REPLACEMENT']),
    ('private.stock_movements'::regclass, 'stock_movements_kind_check', 'kind', array['SUPPLIER_RETURN_OUT', 'SUPPLIER_REPLACEMENT_IN'])
  ) as t(tbl, con, col, extra)
  loop
    select pg_get_constraintdef(oid) into v_def from pg_constraint
      where conrelid = v_spec.tbl and conname = v_spec.con;
    if v_def is null then
      raise exception 'Constraint % pada % tidak ditemukan', v_spec.con, v_spec.tbl;
    end if;
    select array_agg(distinct v order by v) into v_values from (
      -- Mendukung bentuk ARRAY['A'::text, ...] maupun literal '{A,B}'.
      select unnest(string_to_array(btrim(m[1], '{}'), ',')) as v
        from regexp_matches(v_def, '''([^'']+)''', 'g') m
      union select unnest(v_spec.extra)) s;
    execute format('alter table %s drop constraint %I', v_spec.tbl, v_spec.con);
    execute format('alter table %s add constraint %I check (%I = any (%L::text[]))',
      v_spec.tbl, v_spec.con, v_spec.col, v_values);
  end loop;
end $$;

-- Sesi kas: selisih buka dan tinjauan owner (D1/S09) -----------------------
alter table private.cash_sessions
  add column if not exists previous_session_id uuid references private.cash_sessions(id),
  add column if not exists opening_variance numeric(20,0),
  add column if not exists opening_note text,
  add column if not exists needs_review boolean not null default false,
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text;

create index if not exists cash_sessions_history on private.cash_sessions(cashbox_id, business_date desc, opened_at desc);
create index if not exists cash_sessions_review on private.cash_sessions(opened_at) where needs_review and reviewed_at is null;

-- Tautan sumber mutasi kas non-pembayaran pelanggan.
alter table private.cash_movements
  add column if not exists stock_document_id uuid references private.stock_documents(id);
create index if not exists cash_movements_stock_document on private.cash_movements(stock_document_id)
  where stock_document_id is not null;

-- Jaring pengaman K10: mutasi kas hanya boleh masuk ke sesi OPEN. Baris sesi
-- dikunci (NO KEY UPDATE) sehingga bentrok dengan penutupan (FOR UPDATE):
-- penutupan menunggu mutasi selesai, atau mutasi melihat status CLOSED.
create or replace function private.cash_movement_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_status text;
begin
  if tg_op = 'UPDATE' then
    raise exception 'CASH_HISTORY_IMMUTABLE: Riwayat kas tidak boleh diubah; gunakan koreksi' using errcode = '42501';
  end if;
  select status into v_status from private.cash_sessions where id = new.session_id for no key update;
  if v_status is distinct from 'OPEN' then
    raise exception 'CASH_SESSION_CLOSED: Sesi kas sudah ditutup. Buka kas terlebih dahulu.' using errcode = '40001';
  end if;
  return new;
end $$;
revoke all on function private.cash_movement_guard() from public, anon, authenticated;

drop trigger if exists cash_movements_guard on private.cash_movements;
create trigger cash_movements_guard before insert or update on private.cash_movements
  for each row execute function private.cash_movement_guard();

-- Sesi CLOSED tidak diubah lagi, kecuali tanda tinjauan owner.
create or replace function private.cash_session_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'CLOSED' and
     (to_jsonb(new) - array['reviewed_by', 'reviewed_at', 'review_note', 'version'])
       <> (to_jsonb(old) - array['reviewed_by', 'reviewed_at', 'review_note', 'version']) then
    raise exception 'CASH_SESSION_CLOSED: Sesi kas yang sudah ditutup tidak dapat diubah' using errcode = '40001';
  end if;
  return new;
end $$;
revoke all on function private.cash_session_guard() from public, anon, authenticated;

drop trigger if exists cash_sessions_guard on private.cash_sessions;
create trigger cash_sessions_guard before update on private.cash_sessions
  for each row execute function private.cash_session_guard();

-- Distributor (suppliers) ---------------------------------------------------
alter table private.suppliers
  add column if not exists address text,
  add column if not exists active boolean not null default true,
  add column if not exists version integer not null default 1,
  add column if not exists created_at timestamptz not null default now();
create unique index if not exists suppliers_name_ci on private.suppliers(lower(trim(name)));

-- Retur ke distributor (D5): klaim senilai modal barang yang keluar.
create table if not exists private.supplier_returns (
  id uuid primary key default gen_random_uuid(),
  stock_document_id uuid not null unique references private.stock_documents(id),
  supplier_id uuid not null references private.suppliers(id),
  status text not null default 'PENDING' check (status in ('PENDING', 'SETTLED')),
  claim_value numeric(24,6) not null check (claim_value >= 0),
  reason text not null,
  actor_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  operation_id uuid not null,
  outcome text check (outcome in ('REFUND', 'CREDIT', 'REPLACEMENT', 'REJECTED')),
  settled_amount numeric(20,0) check (settled_amount >= 0),
  settlement_method text check (settlement_method in ('CASH', 'TRANSFER', 'QRIS')),
  settlement_cashbox text references private.cashboxes(code),
  settlement_reference text,
  cash_movement_id uuid references private.cash_movements(id),
  replacement_document_id uuid references private.stock_documents(id),
  settlement_difference numeric(24,6),
  settlement_note text,
  settled_by uuid references auth.users(id),
  settled_at timestamptz,
  version integer not null default 1 check (version > 0),
  check ((status = 'PENDING') = (outcome is null)),
  check (status = 'PENDING' or (settled_by is not null and settled_at is not null and settlement_difference is not null)),
  check (outcome is distinct from 'REFUND' or (settled_amount > 0 and settlement_method is not null)),
  check (outcome is distinct from 'REPLACEMENT' or replacement_document_id is not null),
  check ((settlement_method = 'CASH') = (cash_movement_id is not null))
);
create index if not exists supplier_returns_supplier on private.supplier_returns(supplier_id, created_at desc);
create index if not exists supplier_returns_status on private.supplier_returns(status, created_at desc);

-- Buku saldo kredit distributor: IN dari penyelesaian CREDIT, OUT saat dipakai bayar pembelian.
create table if not exists private.supplier_credit_entries (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references private.suppliers(id),
  direction text not null check (direction in ('IN', 'OUT')),
  amount numeric(20,0) not null check (amount > 0),
  supplier_return_id uuid unique references private.supplier_returns(id),
  stock_document_id uuid unique references private.stock_documents(id),
  actor_id uuid not null references auth.users(id),
  occurred_at timestamptz not null default now(),
  operation_id uuid not null,
  check ((direction = 'IN' and supplier_return_id is not null and stock_document_id is null)
      or (direction = 'OUT' and stock_document_id is not null and supplier_return_id is null))
);
create index if not exists supplier_credit_entries_supplier on private.supplier_credit_entries(supplier_id, occurred_at);

alter table private.cash_movements
  add column if not exists supplier_return_id uuid references private.supplier_returns(id);

-- Pembayaran pembelian: tunai (D3) dan saldo kredit distributor.
alter table private.purchase_payments
  add column if not exists cashbox_id text references private.cashboxes(code),
  add column if not exists cash_movement_id uuid unique references private.cash_movements(id),
  add column if not exists credit_entry_id uuid unique references private.supplier_credit_entries(id),
  add column if not exists reference text,
  add column if not exists actor_id uuid references auth.users(id);
alter table private.purchase_payments drop constraint if exists purchase_payments_source_check;
alter table private.purchase_payments add constraint purchase_payments_source_check check (
  ((method = 'CASH') = (cash_movement_id is not null and cashbox_id is not null))
  and ((method = 'SUPPLIER_CREDIT') = (credit_entry_id is not null)));

alter table private.stock_document_items
  add column if not exists free_reason text;

alter table private.supplier_returns enable row level security;
alter table private.supplier_credit_entries enable row level security;
revoke all on private.supplier_returns, private.supplier_credit_entries from public, anon, authenticated;

create or replace function private.supplier_credit_balance(p_supplier uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case direction when 'IN' then amount else -amount end), 0)
  from private.supplier_credit_entries where supplier_id = p_supplier
$$;
revoke all on function private.supplier_credit_balance(uuid) from public, anon, authenticated;
