-- Barcode presisi: temukan produk + satuan yang dipetakan barcode,
-- serta kelola daftar barcode produk.

-- find_by_barcode_v1 — temukan produk & satuan tepat dari kode barcode.
create or replace function public.find_by_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := trim(coalesce(p_input->>'code', ''));
  v_role text;
  v_bc private.product_barcodes%rowtype;
  v_product private.products%rowtype;
  v_unit private.product_units%rowtype;
  v_result jsonb;
begin
  v_role := private.current_role();
  if length(v_code) < 1 or length(v_code) > 100 then
    raise exception 'Kode barcode tidak sah' using errcode = '22023';
  end if;

  select * into v_bc from private.product_barcodes where code = v_code;
  if not found then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select * into v_product from private.products where id = v_bc.product_id and active;
  if not found then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  -- Satuan: pakai peta barcode bila ada, selain itu default aktif
  if v_bc.product_unit_id is not null then
    select * into v_unit from private.product_units
      where id = v_bc.product_unit_id and active;
  end if;
  if v_unit.id is null then
    select * into v_unit from private.product_units
      where product_id = v_product.id and active
      order by is_default desc, label limit 1;
  end if;
  if v_unit.id is null then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  select jsonb_build_object(
    'found', true, 'code', v_code,
    'product_id', v_product.id,
    'sku', v_product.sku,
    'name', v_product.name,
    'specification', v_product.specification,
    'base_unit', v_product.base_unit,
    'quantity_step', v_product.quantity_step::text,
    'track_segments', v_product.track_segments,
    'shelf', v_product.shelf,
    'unit_id', v_unit.id,
    'unit_label', v_unit.label,
    'factor_base', v_unit.factor_base::text,
    'sale_step', v_unit.sale_step::text,
    'sell_price', v_unit.sell_price::text,
    'unit_version', v_unit.version,
    'unit_active', v_unit.active,
    'stock_shop', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'SHOP' and s.condition = 'SALEABLE'),
    'stock_field', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE')
  ) into v_result;

  return v_result;
end $$;
revoke all on function public.find_by_barcode_v1(jsonb) from public,anon,authenticated;
grant execute on function public.find_by_barcode_v1(jsonb) to authenticated;

-- list_product_barcodes_v1 — daftar barcode sebuah produk
create or replace function public.list_product_barcodes_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform private.current_role();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'code', b.code,
    'unit_id', b.product_unit_id,
    'unit_label', (select u.label from private.product_units u where u.id = b.product_unit_id)
  ) order by b.code), '[]'::jsonb) into v_result
  from private.product_barcodes b
  where b.product_id = nullif(p_input->>'product_id', '')::uuid;
  return v_result;
end $$;
revoke all on function public.list_product_barcodes_v1(jsonb) from public,anon,authenticated;
grant execute on function public.list_product_barcodes_v1(jsonb) to authenticated;

-- remove_product_barcode_v1 — hapus barcode (owner)
create or replace function public.remove_product_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_code text;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat menghapus barcode' using errcode = '42501';
  end if;
  v_old := private.operation_result('remove_product_barcode_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_code := trim(coalesce(p_input->>'code', ''));
  delete from private.product_barcodes where code = v_code;
  if not found then
    raise exception 'Barcode tidak ditemukan' using errcode = '22023';
  end if;

  insert into private.audit_events(actor_id, action, entity_type, reason)
  values (v_actor, 'REMOVE_PRODUCT_BARCODE', 'PRODUCT', v_code);

  return private.finish_operation('remove_product_barcode_v1', p_input, jsonb_build_object(
    'ok', true, 'code', v_code, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.remove_product_barcode_v1(jsonb) from public,anon,authenticated;
grant execute on function public.remove_product_barcode_v1(jsonb) to authenticated;

-- add_product_barcode_v1: bila barcode sudah ada pada produk yang sama, tidak error
create or replace function public.add_product_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_code text;
  v_product_id uuid;
  v_unit_id uuid;
  v_unit_product uuid;
  v_existing_product uuid;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mendaftarkan barcode' using errcode = '42501';
  end if;
  v_old := private.operation_result('add_product_barcode_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_code := trim(coalesce(p_input->>'code', ''));
  if length(v_code) not between 1 and 100 then
    raise exception 'Kode barcode harus 1-100 karakter' using errcode = '22023';
  end if;

  v_product_id := nullif(p_input->>'product_id', '')::uuid;
  if v_product_id is null then
    raise exception 'Produk wajib dipilih' using errcode = '22023';
  end if;
  if not exists (select 1 from private.products where id = v_product_id and active) then
    raise exception 'Produk tidak ditemukan atau diarsip' using errcode = '22023';
  end if;

  -- Barcode sudah terdaftar
  select product_id into v_existing_product from private.product_barcodes where code = v_code;
  if v_existing_product is not null then
    if v_existing_product = v_product_id then
      -- Idempoten: barcode sudah milik produk ini
      return private.finish_operation('add_product_barcode_v1', p_input, jsonb_build_object(
        'ok', true, 'entity_id', v_product_id, 'code', v_code, 'already', true,
        'operation_id', p_input->>'operation_id'));
    end if;
    raise exception 'Barcode sudah terdaftar pada produk lain' using errcode = '23505';
  end if;

  v_unit_id := nullif(p_input->>'product_unit_id', '')::uuid;
  if v_unit_id is not null then
    select product_id into v_unit_product from private.product_units where id = v_unit_id;
    if v_unit_product is null then
      raise exception 'Satuan tidak ditemukan' using errcode = '22023';
    end if;
    if v_unit_product <> v_product_id then
      raise exception 'Satuan bukan milik produk yang dipilih' using errcode = '22023';
    end if;
  end if;

  insert into private.product_barcodes(product_id, product_unit_id, code)
  values (v_product_id, v_unit_id, v_code);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'ADD_PRODUCT_BARCODE', 'PRODUCT', v_product_id, v_code);

  return private.finish_operation('add_product_barcode_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_product_id, 'code', v_code,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.add_product_barcode_v1(jsonb) from public,anon,authenticated;
grant execute on function public.add_product_barcode_v1(jsonb) to authenticated;
