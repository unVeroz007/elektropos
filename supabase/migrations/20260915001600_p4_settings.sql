-- P4: shop_settings, categories, dan RPC pengaturan

create table if not exists private.shop_settings (
  id boolean primary key default true check (id),
  name text not null default '',
  address text not null default '',
  phone text not null default '',
  currency text not null default 'IDR' check (currency = 'IDR'),
  timezone text not null default 'Asia/Jakarta' check (timezone = 'Asia/Jakarta'),
  receipt_width integer not null default 58 check (receipt_width in (58, 80)),
  configured_at timestamptz,
  version integer not null default 1 check (version > 0)
);
alter table private.shop_settings enable row level security;
revoke all on private.shop_settings from public, anon, authenticated;

insert into private.shop_settings (id) values (true) on conflict (id) do nothing;

create table if not exists private.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) between 1 and 60),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table private.categories enable row level security;
revoke all on private.categories from public, anon, authenticated;

-- Tambah kolom category_id pada products (kompatibel dengan kolom category lama)
alter table private.products
  add column if not exists category_id uuid references private.categories(id);

create index if not exists products_category_id on private.products(category_id)
  where category_id is not null;

-- get_shop_settings_v1
create or replace function public.get_shop_settings_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_settings private.shop_settings%rowtype;
begin
  perform private.current_role();
  select * into v_settings from private.shop_settings where id;
  return jsonb_build_object(
    'name', v_settings.name,
    'address', v_settings.address,
    'phone', v_settings.phone,
    'currency', v_settings.currency,
    'timezone', v_settings.timezone,
    'receipt_width', v_settings.receipt_width,
    'configured', v_settings.configured_at is not null,
    'version', v_settings.version);
end $$;
revoke all on function public.get_shop_settings_v1() from public,anon,authenticated;
grant execute on function public.get_shop_settings_v1() to authenticated;

-- update_shop_settings_v1
create or replace function public.update_shop_settings_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_settings private.shop_settings%rowtype;
  v_width integer;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengubah pengaturan toko' using errcode = '42501';
  end if;
  v_old := private.operation_result('update_shop_settings_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_settings from private.shop_settings where id for update;
  if v_settings.version <> coalesce((p_input->>'expected_version')::integer, v_settings.version) then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  v_width := coalesce((p_input->>'receipt_width')::integer, v_settings.receipt_width);
  if v_width not in (58, 80) then
    raise exception 'Lebar struk harus 58 atau 80 mm' using errcode = '22023';
  end if;

  update private.shop_settings set
    name = coalesce(nullif(trim(p_input->>'name'), ''), name),
    address = coalesce(p_input->>'address', address),
    phone = coalesce(p_input->>'phone', phone),
    receipt_width = v_width,
    configured_at = case when coalesce(nullif(trim(p_input->>'name'), ''), '') <> '' then now() else configured_at end,
    version = version + 1
    where id returning * into v_settings;

  insert into private.audit_events(actor_id, action, entity_type, entity_id)
  values (v_actor, 'UPDATE_SHOP_SETTINGS', 'SHOP_SETTINGS', null);

  return private.finish_operation('update_shop_settings_v1', p_input, jsonb_build_object(
    'ok', true, 'version', v_settings.version,
    'configured', v_settings.configured_at is not null,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.update_shop_settings_v1(jsonb) from public,anon,authenticated;
grant execute on function public.update_shop_settings_v1(jsonb) to authenticated;

-- upsert_category_v1
create or replace function public.upsert_category_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_old jsonb; v_id uuid; v_name text;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengelola kategori' using errcode = '42501';
  end if;
  v_old := private.operation_result('upsert_category_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_name := trim(coalesce(p_input->>'name', ''));
  if length(v_name) not between 1 and 60 then
    raise exception 'Nama kategori wajib (1-60)' using errcode = '22023';
  end if;

  if p_input ? 'category_id' then
    update private.categories set name = v_name where id = (p_input->>'category_id')::uuid
      returning id into v_id;
    if v_id is null then raise exception 'Kategori tidak ditemukan' using errcode = '22023'; end if;
  else
    insert into private.categories(name) values (v_name)
      on conflict (name) do update set active = true
      returning id into v_id;
  end if;

  return private.finish_operation('upsert_category_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.upsert_category_v1(jsonb) from public,anon,authenticated;
grant execute on function public.upsert_category_v1(jsonb) to authenticated;

-- list_categories_v1
create or replace function public.list_categories_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform private.current_role();
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name), '[]'::jsonb)
    into v_result
  from private.categories c where c.active;
  return v_result;
end $$;
revoke all on function public.list_categories_v1() from public,anon,authenticated;
grant execute on function public.list_categories_v1() to authenticated;
