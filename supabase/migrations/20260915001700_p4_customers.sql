-- P4: pelanggan (upsert, list, cari kandidat)

-- Normalisasi nomor HP Indonesia: buang spasi/tanda, ubah +62/62/0 jadi 0
create or replace function private.normalize_phone(p_phone text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if p_phone is null then return null; end if;
  v := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if v = '' then return null; end if;
  if v like '62%' then v := '0' || substring(v from 3);
  elsif v like '8%' then v := '0' || v;
  end if;
  return v;
end $$;
revoke all on function private.normalize_phone(text) from public,anon,authenticated;

-- upsert_customer_v1
create or replace function public.upsert_customer_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_id uuid;
  v_name text;
  v_phone text;
  v_alt text;
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('upsert_customer_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_name := trim(coalesce(p_input->>'name', ''));
  if length(v_name) not between 1 and 120 then
    raise exception 'Nama pelanggan wajib (1-120)' using errcode = '22023';
  end if;

  v_phone := private.normalize_phone(p_input->>'phone');
  v_alt := nullif(trim(coalesce(p_input->>'alternate_contact', '')), '');
  if v_phone is null and v_alt is null then
    raise exception 'Servis memerlukan nomor HP atau kontak alternatif' using errcode = '22023';
  end if;

  if p_input ? 'customer_id' then
    update private.customers set
      name = v_name,
      phone_normalized = v_phone,
      alternate_contact = v_alt,
      address = nullif(trim(coalesce(p_input->>'address', '')), ''),
      version = version + 1
      where id = (p_input->>'customer_id')::uuid
      returning id into v_id;
    if v_id is null then raise exception 'Pelanggan tidak ditemukan' using errcode = '22023'; end if;
  else
    insert into private.customers(name, phone_normalized, alternate_contact, address)
    values (v_name, v_phone, v_alt, nullif(trim(coalesce(p_input->>'address', '')), ''))
    returning id into v_id;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id)
  values (v_actor, 'UPSERT_CUSTOMER', 'CUSTOMER', v_id);

  return private.finish_operation('upsert_customer_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.upsert_customer_v1(jsonb) from public,anon,authenticated;
grant execute on function public.upsert_customer_v1(jsonb) to authenticated;

-- search_customers_v1 — cari kandidat duplikat, tidak auto-merge
create or replace function public.search_customers_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_query text := lower(trim(coalesce(p_input->>'query', '')));
  v_phone text := private.normalize_phone(p_input->>'phone');
  v_limit integer := least(coalesce((p_input->>'limit')::integer, 25), 100);
  v_result jsonb;
begin
  perform private.current_role();
  if length(v_query) > 120 then raise exception 'Pencarian terlalu panjang' using errcode = '22023'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name,
    'phone', c.phone_normalized,
    'alternate_contact', c.alternate_contact,
    'address', c.address
  ) order by c.name), '[]'::jsonb) into v_result
  from (
    select * from private.customers c
    where c.active
      and (
        (v_query = '' and v_phone is null)
        or (v_query <> '' and lower(c.name) like v_query || '%')
        or (v_phone is not null and c.phone_normalized = v_phone)
      )
    order by c.name
    limit v_limit
  ) c;

  return v_result;
end $$;
revoke all on function public.search_customers_v1(jsonb) from public,anon,authenticated;
grant execute on function public.search_customers_v1(jsonb) to authenticated;
