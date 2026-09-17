-- Perbaikan audit 2026-09 domain penjualan/katalog: skema & helper.
-- Temuan: K06/R03 (CHECK reversed <= alokasi), S01 (diskon baris eksak),
-- S08 (snapshot satuan untuk struk), K02 (alasan nota nol).

-- Snapshot tambahan invoice untuk struk dan audit diskon ---------------------
alter table private.invoices
  add column if not exists free_reason text;

alter table private.invoice_items
  add column if not exists product_unit_id uuid references private.product_units(id),
  add column if not exists unit_label_snapshot text,
  add column if not exists item_discount_exact numeric(38,15);

-- R03/K06: nilai yang dibalik tidak boleh melebihi alokasi asal.
-- NOT VALID agar migrasi tetap dapat diterapkan pada data lama yang sudah
-- rusak oleh bug; baris baru/diubah tetap diperiksa. Validasi penuh
-- dijalankan bila data lama bersih.
alter table private.cost_allocations
  drop constraint if exists cost_allocations_reversed_qty_check,
  drop constraint if exists cost_allocations_reversed_cost_check;
alter table private.cost_allocations
  add constraint cost_allocations_reversed_qty_check
    check (reversed_qty >= 0 and reversed_qty <= qty_base) not valid,
  add constraint cost_allocations_reversed_cost_check
    check (reversed_cost >= 0 and reversed_cost <= cost_amount) not valid;

do $$ begin
  if not exists (select 1 from private.cost_allocations
      where reversed_qty < 0 or reversed_qty > qty_base
         or reversed_cost < 0 or reversed_cost > cost_amount) then
    alter table private.cost_allocations validate constraint cost_allocations_reversed_qty_check;
    alter table private.cost_allocations validate constraint cost_allocations_reversed_cost_check;
  end if;
end $$;

create index if not exists invoices_number_lower on private.invoices(lower(number));
create index if not exists credit_note_items_invoice_item on private.credit_note_items(invoice_item_id);
create index if not exists refund_allocations_original on private.refund_allocations(original_payment_id);
create index if not exists return_cost_allocations_original
  on private.return_cost_allocations(original_cost_allocation_id);

-- Helper input (prefiks sales_ agar tidak bentrok dengan helper domain lain) --

-- UUID dari JSON. Wajib: hilang/null ditolak. Opsional: hilang/null/'' = NULL.
create or replace function private.sales_uuid_input(p_value jsonb, p_field text, p_required boolean default true)
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
  if jsonb_typeof(p_value) <> 'string' then
    raise exception 'INVALID_INPUT: % tidak sah', p_field using errcode = '22023';
  end if;
  v_text := trim(p_value #>> '{}');
  if v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'INVALID_INPUT: % tidak sah', p_field using errcode = '22023';
  end if;
  return v_text::uuid;
end $$;

-- Bilangan bulat versi (angka JSON atau teks digit), opsional.
create or replace function private.sales_int_input(p_value jsonb, p_field text, p_required boolean default false)
returns integer language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null'
     or (jsonb_typeof(p_value) = 'string' and trim(p_value #>> '{}') = '') then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_field using errcode = '22023';
    end if;
    return null;
  end if;
  if jsonb_typeof(p_value) not in ('number', 'string') then
    raise exception 'INVALID_INPUT: % tidak sah', p_field using errcode = '22023';
  end if;
  v_text := trim(p_value #>> '{}');
  if v_text !~ '^[0-9]{1,9}$' then
    raise exception 'INVALID_INPUT: % tidak sah', p_field using errcode = '22023';
  end if;
  return v_text::integer;
end $$;

-- Teks opsional dengan batas panjang; NULL bila kosong.
create or replace function private.sales_text_input(p_value jsonb, p_field text, p_max integer, p_required boolean default false)
returns text language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is not null and jsonb_typeof(p_value) not in ('string', 'null') then
    raise exception 'INVALID_INPUT: % harus berupa teks', p_field using errcode = '22023';
  end if;
  v_text := nullif(trim(coalesce(p_value #>> '{}', '')), '');
  if v_text is null and p_required then
    raise exception 'INVALID_INPUT: % wajib diisi', p_field using errcode = '22023';
  end if;
  if length(v_text) > p_max then
    raise exception 'INVALID_INPUT: % maksimal % karakter', p_field, p_max using errcode = '22023';
  end if;
  return v_text;
end $$;

-- Tolak field yang tidak dikenal (API-01 validasi ketat).
create or replace function private.sales_reject_unknown(p_obj jsonb, p_allowed text[], p_context text)
returns void language plpgsql immutable set search_path = '' as $$
declare v_key text;
begin
  if p_obj is null or jsonb_typeof(p_obj) <> 'object' then
    raise exception 'INVALID_INPUT: % harus berupa objek', p_context using errcode = '22023';
  end if;
  select k into v_key from jsonb_object_keys(p_obj) k where not (k = any (p_allowed)) limit 1;
  if v_key is not null then
    raise exception 'INVALID_INPUT: Field "%" tidak dikenal pada %', v_key, p_context using errcode = '22023';
  end if;
end $$;

-- round_half_up(n × m / d, p) eksak untuk n,m >= 0 dan d > 0 (BR-01):
-- quotient/remainder integer, bukan presisi default pembagian NUMERIC.
create or replace function private.sales_ratio_half_up(p_n numeric, p_m numeric, p_d numeric, p_scale integer)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_num numeric; v_q numeric; v_r numeric;
begin
  if p_d <= 0 or p_n < 0 or p_m < 0 then
    raise exception 'INVALID_NUMBER: Rasio tidak sah' using errcode = '22023';
  end if;
  -- Perkalian NUMERIC eksak; pembagian hanya lewat div() (truncation eksak).
  v_num := p_n * p_m * ('1e' || p_scale)::numeric;
  v_q := div(v_num, p_d);
  v_r := v_num - v_q * p_d;
  if 2 * v_r >= p_d then v_q := v_q + 1; end if;
  return round(v_q * ('1e-' || p_scale)::numeric, p_scale);
end $$;

revoke all on function private.sales_uuid_input(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function private.sales_int_input(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function private.sales_text_input(jsonb, text, integer, boolean) from public, anon, authenticated;
revoke all on function private.sales_reject_unknown(jsonb, text[], text) from public, anon, authenticated;
revoke all on function private.sales_ratio_half_up(numeric, numeric, numeric, integer) from public, anon, authenticated;

-- Idempotensi: pesan konflik memakai format 'KODE: pesan awam'. Perilaku lain tidak berubah.
create or replace function private.operation_result(p_command text, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old private.operations%rowtype; v_key uuid;
begin
  if jsonb_typeof(p_input) <> 'object' or (p_input->>'operation_id') is null then
    raise exception 'INVALID_INPUT: operation_id wajib' using errcode = '22023';
  end if;
  begin
    v_key := (p_input->>'operation_id')::uuid;
  exception when others then
    raise exception 'INVALID_INPUT: operation_id tidak sah' using errcode = '22023';
  end;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || p_command || ':' || v_key::text, 0));
  select * into v_old from private.operations
    where actor_id = auth.uid() and command = p_command and operation_id = v_key;
  if found then
    if v_old.payload <> p_input then
      raise exception 'IDEMPOTENCY_CONFLICT: Transaksi ini sudah pernah dikirim dengan isi berbeda' using errcode = '22023';
    end if;
    return v_old.result;
  end if;
  return null;
end $$;
revoke all on function private.operation_result(text, jsonb) from public, anon, authenticated;

-- Awal perintah tulis: peran, operation_id sah, lalu hasil idempoten lama.
-- p_command WAJIB sama dengan nama RPC publik (dipakai get_operation_v1).
create or replace function private.sales_begin_command(p_command text, p_input jsonb, p_roles text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_roles);
  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise exception 'INVALID_INPUT: Input harus berupa objek' using errcode = '22023';
  end if;
  perform private.sales_uuid_input(p_input->'operation_id', 'operation_id');
  return private.operation_result(p_command, p_input);
end $$;
revoke all on function private.sales_begin_command(text, jsonb, text[]) from public, anon, authenticated;
