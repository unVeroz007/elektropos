-- Perbaikan audit 2026-09: katalog, barcode, kategori.
-- Menutup K01 (require_role pada semua RPC katalog), S06 (versi satuan baru
-- hanya bila harga/faktor/langkah/label berubah; barcode ikut pindah),
-- S04 (validasi sebelum insert, kode error, impor divalidasi ulang di commit,
-- SKU duplikat case-insensitive dalam batch).

-- === upsert_product_v1 ========================================================
create or replace function public.upsert_product_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_product private.products%rowtype;
  v_unit private.product_units%rowtype;
  v_new_unit private.product_units%rowtype;
  v_product_id uuid;
  v_expected integer;
  v_sku text;
  v_name text;
  v_spec text;
  v_base_unit text;
  v_label text;
  v_shelf text;
  v_barcode text;
  v_reason text;
  v_category uuid;
  v_track boolean;
  v_qty_step numeric;
  v_factor numeric;
  v_step numeric;
  v_price numeric;
  v_unit_changed boolean := false;
  v_barcode_owner uuid;
  v_result jsonb;
begin
  v_old := private.sales_begin_command('upsert_product_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'product_id', 'expected_version', 'sku', 'name',
    'specification', 'base_unit', 'quantity_step', 'track_segments', 'unit_label', 'factor_base', 'sale_step',
    'sell_price', 'barcode', 'shelf', 'reason', 'category_id'], 'produk');

  v_product_id := private.sales_uuid_input(p_input->'product_id', 'Produk', false);
  v_sku := private.sales_text_input(p_input->'sku', 'SKU', 60, true);
  v_name := private.sales_text_input(p_input->'name', 'Nama barang', 150, true);
  v_spec := coalesce(private.sales_text_input(p_input->'specification', 'Spesifikasi', 500), '');
  v_base_unit := private.sales_text_input(p_input->'base_unit', 'Satuan dasar', 30, true);
  v_label := private.sales_text_input(p_input->'unit_label', 'Label satuan jual', 40, true);
  v_shelf := private.sales_text_input(p_input->'shelf', 'Rak', 30);
  v_barcode := private.sales_text_input(p_input->'barcode', 'Barcode', 100);
  v_reason := private.sales_text_input(p_input->'reason', 'Alasan', 500);
  v_category := private.sales_uuid_input(p_input->'category_id', 'Kategori', false);
  if p_input->'track_segments' is not null and jsonb_typeof(p_input->'track_segments') not in ('boolean', 'null') then
    raise exception 'INVALID_INPUT: track_segments harus true/false' using errcode = '22023';
  end if;
  v_track := coalesce((p_input->>'track_segments')::boolean, false);
  v_qty_step := private.decimal_input(p_input->'quantity_step', 3, 999999999.999);
  v_factor := private.decimal_input(p_input->'factor_base', 3, 1000000);
  v_step := private.decimal_input(p_input->'sale_step', 3, 999999999.999);
  v_price := private.decimal_input(p_input->'sell_price', 6, 999999999999.999999);
  if round(v_step * v_factor, 3) <> v_step * v_factor or mod(v_step * v_factor, v_qty_step) <> 0 then
    raise exception 'INVALID_QUANTITY: Langkah jual × faktor harus kelipatan langkah stok' using errcode = '22023';
  end if;
  if v_category is not null and not exists (select 1 from private.categories where id = v_category and active) then
    raise exception 'NOT_FOUND: Kategori tidak ditemukan' using errcode = '22023';
  end if;

  if v_product_id is not null then
    v_expected := private.sales_int_input(p_input->'expected_version', 'Versi produk', true);
    select * into v_product from private.products where id = v_product_id for update;
    if not found then
      raise exception 'NOT_FOUND: Produk tidak ditemukan' using errcode = '22023';
    end if;
    if v_product.version <> v_expected then
      raise exception 'VERSION_CONFLICT: Produk sudah diubah orang lain. Muat ulang lalu ulangi.' using errcode = '40001';
    end if;
    if v_product.base_unit <> v_base_unit or v_product.quantity_step <> v_qty_step
       or v_product.track_segments <> v_track then
      raise exception 'INVALID_INPUT: Satuan dasar, langkah stok, dan pelacakan roll tidak boleh diubah'
        using errcode = '22023';
    end if;
  end if;

  if exists (select 1 from private.products where lower(sku) = lower(v_sku)
      and id is distinct from v_product_id) then
    raise exception 'DUPLICATE_SKU: SKU "%" sudah dipakai barang lain', v_sku using errcode = '23505';
  end if;
  if v_barcode is not null then
    select product_id into v_barcode_owner from private.product_barcodes where code = v_barcode;
    if found and v_barcode_owner is distinct from v_product_id then
      raise exception 'DUPLICATE_BARCODE: Barcode % sudah terdaftar pada barang lain', v_barcode using errcode = '23505';
    end if;
  end if;

  if v_product_id is null then
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf, category_id)
    values (v_sku, v_name, v_spec, v_base_unit, v_qty_step, v_track, v_shelf, v_category)
    returning * into v_product;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_product.id, v_label, v_factor, v_step, v_price, true)
    returning * into v_new_unit;
    insert into private.product_price_history(unit_id, before_price, after_price, reason, actor_id)
    values (v_new_unit.id, null, v_price, v_reason, v_actor);
    v_unit_changed := true;
  else
    update private.products
      set sku = v_sku, name = v_name, specification = v_spec, shelf = v_shelf,
          category_id = coalesce(v_category, category_id), version = version + 1
      where id = v_product.id returning * into v_product;

    select * into v_unit from private.product_units
      where product_id = v_product.id and is_default and active for update;
    if not found or v_unit.label <> v_label or v_unit.factor_base <> v_factor
       or v_unit.sale_step <> v_step or v_unit.sell_price <> v_price then
      v_unit_changed := true;
      if v_unit.id is not null then
        update private.product_units set active = false, is_default = false where id = v_unit.id;
      end if;
      insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default, version)
      values (v_product.id, v_label, v_factor, v_step, v_price, true, coalesce(v_unit.version, 0) + 1)
      returning * into v_new_unit;
      insert into private.product_price_history(unit_id, before_price, after_price, reason, actor_id)
      values (v_new_unit.id, v_unit.sell_price, v_price, v_reason, v_actor);
      if v_unit.id is not null then
        -- Barcode satuan lama ikut ke versi satuan baru agar scan tetap bekerja.
        update private.product_barcodes set product_unit_id = v_new_unit.id where product_unit_id = v_unit.id;
      end if;
    else
      v_new_unit := v_unit;
    end if;
  end if;

  if v_barcode is not null and not exists (select 1 from private.product_barcodes where code = v_barcode) then
    insert into private.product_barcodes(product_id, product_unit_id, code)
    values (v_product.id, v_new_unit.id, v_barcode);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'UPSERT_PRODUCT', 'PRODUCT', v_product.id, v_reason);

  v_result := jsonb_build_object('ok', true, 'entity_id', v_product.id, 'version', v_product.version,
    'unit_id', v_new_unit.id, 'unit_version', v_new_unit.version, 'unit_changed', v_unit_changed,
    'operation_id', p_input->>'operation_id', 'server_time', now(), 'schema_version', 2);
  return private.finish_operation('upsert_product_v1', p_input, v_result);
end $$;
revoke all on function public.upsert_product_v1(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_product_v1(jsonb) to authenticated;

-- === archive_product_v1 =======================================================
create or replace function public.archive_product_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_product private.products%rowtype;
  v_expected integer;
  v_result jsonb;
begin
  v_old := private.sales_begin_command('archive_product_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'product_id', 'expected_version', 'reason'], 'arsip produk');
  v_expected := private.sales_int_input(p_input->'expected_version', 'Versi produk', true);
  select * into v_product from private.products
    where id = private.sales_uuid_input(p_input->'product_id', 'Produk') for update;
  if not found then
    raise exception 'NOT_FOUND: Produk tidak ditemukan' using errcode = '22023';
  end if;
  if v_product.version <> v_expected then
    raise exception 'VERSION_CONFLICT: Produk sudah diubah orang lain. Muat ulang lalu ulangi.' using errcode = '40001';
  end if;
  if not v_product.active then
    raise exception 'INVALID_INPUT: Produk sudah diarsip' using errcode = '22023';
  end if;
  update private.products set active = false, version = version + 1 where id = v_product.id returning * into v_product;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'ARCHIVE_PRODUCT', 'PRODUCT', v_product.id,
    private.sales_text_input(p_input->'reason', 'Alasan', 500));
  v_result := jsonb_build_object('ok', true, 'entity_id', v_product.id, 'version', v_product.version,
    'operation_id', p_input->>'operation_id', 'server_time', now());
  return private.finish_operation('archive_product_v1', p_input, v_result);
end $$;
revoke all on function public.archive_product_v1(jsonb) from public, anon, authenticated;
grant execute on function public.archive_product_v1(jsonb) to authenticated;

-- === search_products_v1 =======================================================
create or replace function public.search_products_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_raw text;
  v_query text;
  v_limit integer;
  v_category uuid;
  v_result jsonb;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  if p_input is null then p_input := '{}'::jsonb; end if;
  perform private.sales_reject_unknown(p_input, array['query', 'limit', 'category_id'], 'pencarian barang');
  v_raw := coalesce(private.sales_text_input(p_input->'query', 'Pencarian', 120), '');
  v_query := lower(v_raw);
  v_limit := coalesce(private.sales_int_input(p_input->'limit', 'limit'), 25);
  if v_limit not between 1 and 100 then
    raise exception 'INVALID_INPUT: limit harus 1-100' using errcode = '22023';
  end if;
  v_category := private.sales_uuid_input(p_input->'category_id', 'Kategori', false);

  select coalesce(jsonb_agg(x.payload order by x.exact desc, x.name, x.id), '[]'::jsonb) into v_result from (
    select p.id, p.name,
      (lower(p.sku) = v_query or exists (select 1 from private.product_barcodes b
        where b.product_id = p.id and b.code = v_raw)) as exact,
      jsonb_build_object(
        'id', p.id, 'sku', p.sku, 'name', p.name, 'specification', p.specification,
        'base_unit', p.base_unit, 'shelf', p.shelf, 'track_segments', p.track_segments,
        'quantity_step', p.quantity_step::text, 'category_id', p.category_id, 'version', p.version,
        'units', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', u.id, 'label', u.label, 'factor_base', u.factor_base::text,
            'sale_step', u.sale_step::text, 'sell_price', u.sell_price::text,
            'is_default', u.is_default, 'version', u.version)
            order by u.is_default desc, u.label), '[]'::jsonb)
          from private.product_units u where u.product_id = p.id and u.active),
        'stock_shop', (select coalesce(sum(s.qty_base), 0)::text
          from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
          where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE'),
        'stock_field', (select coalesce(sum(s.qty_base), 0)::text
          from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
          where l.product_id = p.id and s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE')
      ) as payload
    from private.products p
    where p.active
      and (v_category is null or p.category_id = v_category)
      and (v_query = ''
        or position(v_query in lower(p.name)) > 0
        or position(v_query in lower(p.sku)) = 1
        or exists (select 1 from private.product_barcodes b where b.product_id = p.id and b.code = v_raw)
        or exists (select 1 from unnest(p.aliases) a where position(v_query in lower(a)) > 0))
    order by 3 desc, p.name, p.id
    limit v_limit
  ) x;
  return v_result;
end $$;
revoke all on function public.search_products_v1(jsonb) from public, anon, authenticated;
grant execute on function public.search_products_v1(jsonb) to authenticated;

-- === get_product_v1 ===========================================================
create or replace function public.get_product_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_role text;
  v_id uuid;
  v_result jsonb;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.sales_reject_unknown(p_input, array['product_id'], 'produk');
  v_id := private.sales_uuid_input(p_input->'product_id', 'Produk');
  select jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name, 'specification', p.specification,
    'base_unit', p.base_unit, 'quantity_step', p.quantity_step::text, 'track_segments', p.track_segments,
    'shelf', p.shelf, 'category_id', p.category_id, 'version', p.version, 'active', p.active,
    'units', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'label', u.label,
        'factor_base', u.factor_base::text, 'sale_step', u.sale_step::text, 'sell_price', u.sell_price::text,
        'is_default', u.is_default, 'version', u.version, 'active', u.active)
        order by u.active desc, u.is_default desc, u.label, u.version desc), '[]'::jsonb)
      from private.product_units u where u.product_id = p.id),
    'barcodes', (select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'unit_id', b.product_unit_id)
        order by b.code), '[]'::jsonb)
      from private.product_barcodes b where b.product_id = p.id),
    'positions', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', s.label,
        'location', s.location, 'condition', s.condition, 'qty_base', s.qty_base::text,
        'segment_capacity', s.segment_capacity::text, 'sealed', s.sealed, 'version', s.version)
        order by s.label, s.id), '[]'::jsonb)
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = p.id and s.qty_base > 0))
    || case when v_role in ('OWNER', 'MAINTAINER') then jsonb_build_object('lots',
      (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'posted_at', l.posted_at,
          'remaining_qty', l.remaining_qty::text, 'remaining_cost', l.remaining_cost::text)
          order by l.posted_at, l.id), '[]'::jsonb)
        from private.inventory_lots l where l.product_id = p.id)) else '{}'::jsonb end
  into v_result
  from private.products p where p.id = v_id;
  if v_result is null then
    raise exception 'NOT_FOUND: Produk tidak ditemukan' using errcode = '22023';
  end if;
  return v_result;
end $$;
revoke all on function public.get_product_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_product_v1(jsonb) to authenticated;

-- === find_by_barcode_v1 =======================================================
create or replace function public.find_by_barcode_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_code text;
  v_bc private.product_barcodes%rowtype;
  v_product private.products%rowtype;
  v_unit private.product_units%rowtype;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.sales_reject_unknown(p_input, array['code'], 'barcode');
  v_code := private.sales_text_input(p_input->'code', 'Kode barcode', 100, true);

  select * into v_bc from private.product_barcodes where code = v_code;
  if not found then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;
  select * into v_product from private.products where id = v_bc.product_id and active;
  if not found then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;
  if v_bc.product_unit_id is not null then
    select * into v_unit from private.product_units where id = v_bc.product_unit_id and active;
  end if;
  if v_unit.id is null then
    select * into v_unit from private.product_units
      where product_id = v_product.id and active order by is_default desc, label limit 1;
  end if;
  if v_unit.id is null then
    return jsonb_build_object('found', false, 'code', v_code);
  end if;

  return jsonb_build_object(
    'found', true, 'code', v_code, 'product_id', v_product.id, 'sku', v_product.sku,
    'name', v_product.name, 'specification', v_product.specification, 'base_unit', v_product.base_unit,
    'quantity_step', v_product.quantity_step::text, 'track_segments', v_product.track_segments,
    'shelf', v_product.shelf, 'unit_id', v_unit.id, 'unit_label', v_unit.label,
    'factor_base', v_unit.factor_base::text, 'sale_step', v_unit.sale_step::text,
    'sell_price', v_unit.sell_price::text, 'unit_version', v_unit.version, 'unit_active', v_unit.active,
    'stock_shop', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'SHOP' and s.condition = 'SALEABLE'),
    'stock_field', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE'));
end $$;
revoke all on function public.find_by_barcode_v1(jsonb) from public, anon, authenticated;
grant execute on function public.find_by_barcode_v1(jsonb) to authenticated;

-- === list_product_barcodes_v1 ================================================
create or replace function public.list_product_barcodes_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_result jsonb; v_id uuid;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.sales_reject_unknown(p_input, array['product_id'], 'barcode');
  v_id := private.sales_uuid_input(p_input->'product_id', 'Produk');
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'code', b.code, 'unit_id', b.product_unit_id,
      'unit_label', (select u.label from private.product_units u where u.id = b.product_unit_id))
      order by b.code), '[]'::jsonb)
    into v_result
    from private.product_barcodes b where b.product_id = v_id;
  return v_result;
end $$;
revoke all on function public.list_product_barcodes_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_product_barcodes_v1(jsonb) to authenticated;

-- === add_product_barcode_v1 ===================================================
create or replace function public.add_product_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_code text;
  v_product_id uuid;
  v_unit_id uuid;
  v_unit private.product_units%rowtype;
  v_existing uuid;
begin
  v_old := private.sales_begin_command('add_product_barcode_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'product_id', 'product_unit_id', 'code'], 'barcode');
  v_code := private.sales_text_input(p_input->'code', 'Kode barcode', 100, true);
  v_product_id := private.sales_uuid_input(p_input->'product_id', 'Produk');
  v_unit_id := private.sales_uuid_input(p_input->'product_unit_id', 'Satuan', false);

  perform 1 from private.products where id = v_product_id and active for update;
  if not found then
    raise exception 'NOT_FOUND: Produk tidak ditemukan atau diarsip' using errcode = '22023';
  end if;
  if v_unit_id is not null then
    select * into v_unit from private.product_units where id = v_unit_id;
    if not found then
      raise exception 'NOT_FOUND: Satuan tidak ditemukan' using errcode = '22023';
    end if;
    if v_unit.product_id <> v_product_id then
      raise exception 'INVALID_INPUT: Satuan bukan milik produk yang dipilih' using errcode = '22023';
    end if;
    if not v_unit.active then
      raise exception 'INVALID_INPUT: Satuan sudah tidak aktif' using errcode = '22023';
    end if;
  end if;

  select product_id into v_existing from private.product_barcodes where code = v_code;
  if found then
    if v_existing = v_product_id then
      return private.finish_operation('add_product_barcode_v1', p_input, jsonb_build_object(
        'ok', true, 'entity_id', v_product_id, 'code', v_code, 'already', true,
        'operation_id', p_input->>'operation_id'));
    end if;
    raise exception 'DUPLICATE_BARCODE: Barcode sudah terdaftar pada produk lain' using errcode = '23505';
  end if;

  insert into private.product_barcodes(product_id, product_unit_id, code) values (v_product_id, v_unit_id, v_code);
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'ADD_PRODUCT_BARCODE', 'PRODUCT', v_product_id, v_code);
  return private.finish_operation('add_product_barcode_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_product_id, 'code', v_code, 'already', false,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.add_product_barcode_v1(jsonb) from public, anon, authenticated;
grant execute on function public.add_product_barcode_v1(jsonb) to authenticated;

-- === remove_product_barcode_v1 ================================================
create or replace function public.remove_product_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_code text;
  v_product_id uuid;
begin
  v_old := private.sales_begin_command('remove_product_barcode_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'code'], 'barcode');
  v_code := private.sales_text_input(p_input->'code', 'Kode barcode', 100, true);
  delete from private.product_barcodes where code = v_code returning product_id into v_product_id;
  if not found then
    raise exception 'NOT_FOUND: Barcode tidak ditemukan' using errcode = '22023';
  end if;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REMOVE_PRODUCT_BARCODE', 'PRODUCT', v_product_id, v_code);
  return private.finish_operation('remove_product_barcode_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_product_id, 'code', v_code, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.remove_product_barcode_v1(jsonb) from public, anon, authenticated;
grant execute on function public.remove_product_barcode_v1(jsonb) to authenticated;

-- === Impor katalog ============================================================
create or replace function private.catalog_try_decimal(p_value jsonb, p_scale integer, p_max numeric)
returns numeric language plpgsql immutable set search_path = '' as $$
begin
  return private.decimal_input(p_value, p_scale, p_max, true);
exception when others then
  return null;
end $$;
revoke all on function private.catalog_try_decimal(jsonb, integer, numeric) from public, anon, authenticated;

-- Validasi seluruh batch; dipakai preview DAN commit (commit tidak percaya preview).
create or replace function private.catalog_validate_rows(p_rows jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_row jsonb;
  v_line integer := 0;
  v_errors jsonb := '[]'::jsonb;
  v_seen_sku text[] := '{}';
  v_seen_barcode text[] := '{}';
  v_sku text;
  v_barcode text;
  v_qty_step numeric;
  v_factor numeric;
  v_step numeric;
  v_price numeric;
  v_key text;
  v_allowed text[] := array['sku', 'name', 'specification', 'base_unit', 'quantity_step', 'track_segments',
    'unit_label', 'factor_base', 'sale_step', 'sell_price', 'barcode', 'shelf'];
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'INVALID_INPUT: rows wajib berupa daftar' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 200 then
    raise exception 'INVALID_INPUT: Impor katalog 1-200 baris per batch' using errcode = '22023';
  end if;

  for v_row in select e from jsonb_array_elements(p_rows) with ordinality t(e, n) order by n loop
    v_line := v_line + 1;
    if jsonb_typeof(v_row) <> 'object' then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_ROW', 'message', 'Baris tidak sah');
      continue;
    end if;
    select k into v_key from jsonb_object_keys(v_row) k where not (k = any (v_allowed)) limit 1;
    if v_key is not null then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'UNKNOWN_FIELD',
        'message', 'Kolom tidak dikenal: ' || v_key);
    end if;
    if exists (select 1 from jsonb_each(v_row) f where jsonb_typeof(f.value) not in ('string', 'boolean', 'null')) then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_ROW',
        'message', 'Nilai kolom harus teks');
      continue;
    end if;

    v_sku := trim(coalesce(v_row->>'sku', ''));
    v_barcode := nullif(trim(coalesce(v_row->>'barcode', '')), '');
    if length(v_sku) not between 1 and 60 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_SKU', 'message', 'SKU wajib (1-60 karakter)');
    elsif lower(v_sku) = any (v_seen_sku) then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_SKU',
        'message', 'SKU duplikat dalam batch: ' || v_sku);
    else
      v_seen_sku := v_seen_sku || lower(v_sku);
      if exists (select 1 from private.products where lower(sku) = lower(v_sku)) then
        v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_SKU',
          'message', 'SKU sudah ada: ' || v_sku);
      end if;
    end if;

    if v_barcode is not null then
      if length(v_barcode) > 100 then
        v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_BARCODE', 'message', 'Barcode maksimal 100 karakter');
      elsif v_barcode = any (v_seen_barcode) then
        v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_BARCODE', 'message', 'Barcode duplikat dalam batch');
      else
        v_seen_barcode := v_seen_barcode || v_barcode;
        if exists (select 1 from private.product_barcodes where code = v_barcode) then
          v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_BARCODE',
            'message', 'Barcode sudah ada: ' || v_barcode);
        end if;
      end if;
    end if;

    if length(trim(coalesce(v_row->>'name', ''))) not between 1 and 150 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_NAME', 'message', 'Nama wajib (1-150 karakter)');
    end if;
    if length(coalesce(v_row->>'specification', '')) > 500 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_SPECIFICATION', 'message', 'Spesifikasi maksimal 500 karakter');
    end if;
    if length(trim(coalesce(v_row->>'base_unit', ''))) not between 1 and 30 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_BASE_UNIT', 'message', 'Satuan dasar wajib (1-30 karakter)');
    end if;
    if length(trim(coalesce(v_row->>'unit_label', ''))) not between 1 and 40 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_UNIT_LABEL', 'message', 'Label satuan jual wajib (1-40 karakter)');
    end if;
    if length(trim(coalesce(v_row->>'shelf', ''))) > 30 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_SHELF', 'message', 'Rak maksimal 30 karakter');
    end if;
    if coalesce(lower(trim(v_row->>'track_segments')), '') not in ('', 'true', 'false') then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_TRACK_SEGMENTS', 'message', 'track_segments harus true/false');
    end if;

    v_qty_step := private.catalog_try_decimal(v_row->'quantity_step', 3, 999999999.999);
    v_factor := private.catalog_try_decimal(v_row->'factor_base', 3, 1000000);
    v_step := private.catalog_try_decimal(v_row->'sale_step', 3, 999999999.999);
    v_price := private.catalog_try_decimal(v_row->'sell_price', 6, 999999999999.999999);
    if v_qty_step is null then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_QUANTITY_STEP', 'message', 'Langkah stok tidak valid');
    end if;
    if v_factor is null then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_FACTOR', 'message', 'Faktor konversi tidak valid');
    end if;
    if v_step is null then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_SALE_STEP', 'message', 'Langkah jual tidak valid');
    end if;
    if v_price is null then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_PRICE', 'message', 'Harga tidak valid');
    end if;
    if v_qty_step is not null and v_factor is not null and v_step is not null
       and (round(v_step * v_factor, 3) <> v_step * v_factor or mod(v_step * v_factor, v_qty_step) <> 0) then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_CONVERSION',
        'message', 'Langkah jual × faktor harus kelipatan langkah stok');
    end if;
  end loop;
  return v_errors;
end $$;
revoke all on function private.catalog_validate_rows(jsonb) from public, anon, authenticated;

create or replace function public.preview_catalog_import_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_errors jsonb;
  v_total integer;
begin
  perform private.require_role(array['OWNER']);
  perform private.sales_reject_unknown(p_input, array['rows', 'import_hash'], 'impor katalog');
  v_errors := private.catalog_validate_rows(p_input->'rows');
  v_total := jsonb_array_length(p_input->'rows');
  return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'total', v_total,
    'valid', v_total - (select count(distinct (e->>'line')) from jsonb_array_elements(v_errors) e),
    'errors', v_errors);
end $$;
revoke all on function public.preview_catalog_import_v1(jsonb) from public, anon, authenticated;
grant execute on function public.preview_catalog_import_v1(jsonb) to authenticated;

create or replace function public.commit_catalog_import_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_errors jsonb;
  v_row jsonb;
  v_ids jsonb := '[]'::jsonb;
  v_id uuid;
  v_unit_id uuid;
begin
  v_old := private.sales_begin_command('commit_catalog_import_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'rows', 'import_hash'], 'impor katalog');
  perform private.sales_text_input(p_input->'import_hash', 'import_hash', 128);
  -- Serialisasi impor agar cek SKU/barcode tidak berlomba dengan impor lain.
  perform pg_advisory_xact_lock(hashtextextended('catalog_import', 0));
  v_errors := private.catalog_validate_rows(p_input->'rows');
  if jsonb_array_length(v_errors) > 0 then
    raise exception 'INVALID_INPUT: Impor ditolak, % masalah (baris %: %)', jsonb_array_length(v_errors),
      v_errors->0->>'line', v_errors->0->>'message'
      using errcode = '22023', detail = v_errors::text;
  end if;

  for v_row in select e from jsonb_array_elements(p_input->'rows') with ordinality t(e, n) order by n loop
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf)
    values (trim(v_row->>'sku'), trim(v_row->>'name'), coalesce(v_row->>'specification', ''),
      trim(v_row->>'base_unit'), (v_row->>'quantity_step')::numeric,
      coalesce(nullif(lower(trim(v_row->>'track_segments')), '')::boolean, false),
      nullif(trim(coalesce(v_row->>'shelf', '')), ''))
    returning id into v_id;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_id, trim(v_row->>'unit_label'), (v_row->>'factor_base')::numeric,
      (v_row->>'sale_step')::numeric, (v_row->>'sell_price')::numeric, true)
    returning id into v_unit_id;
    insert into private.product_price_history(unit_id, before_price, after_price, reason, actor_id)
    values (v_unit_id, null, (v_row->>'sell_price')::numeric, 'Impor katalog', v_actor);
    if nullif(trim(coalesce(v_row->>'barcode', '')), '') is not null then
      insert into private.product_barcodes(product_id, product_unit_id, code)
      values (v_id, v_unit_id, trim(v_row->>'barcode'));
    end if;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  insert into private.audit_events(actor_id, action, entity_type, reason)
  values (v_actor, 'IMPORT_CATALOG', 'PRODUCT', left(p_input->>'import_hash', 128));
  return private.finish_operation('commit_catalog_import_v1', p_input, jsonb_build_object(
    'ok', true, 'count', jsonb_array_length(v_ids), 'ids', v_ids, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.commit_catalog_import_v1(jsonb) from public, anon, authenticated;
grant execute on function public.commit_catalog_import_v1(jsonb) to authenticated;

-- === Kategori =================================================================
create or replace function public.upsert_category_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_id uuid;
  v_name text;
  v_active boolean;
begin
  v_old := private.sales_begin_command('upsert_category_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'category_id', 'name', 'active'], 'kategori');
  v_name := private.sales_text_input(p_input->'name', 'Nama kategori', 60, true);
  v_id := private.sales_uuid_input(p_input->'category_id', 'Kategori', false);
  if p_input->'active' is not null and jsonb_typeof(p_input->'active') not in ('boolean', 'null') then
    raise exception 'INVALID_INPUT: active harus true/false' using errcode = '22023';
  end if;
  v_active := coalesce((p_input->>'active')::boolean, true);

  perform pg_advisory_xact_lock(hashtextextended('categories', 0));
  if exists (select 1 from private.categories where lower(name) = lower(v_name) and id is distinct from v_id) then
    if v_id is null then
      -- Nama sama: aktifkan kembali kategori yang ada (perilaku lama).
      update private.categories set active = true where lower(name) = lower(v_name) returning id into v_id;
    else
      raise exception 'DUPLICATE_NAME: Nama kategori "%" sudah dipakai', v_name using errcode = '23505';
    end if;
  elsif v_id is not null then
    update private.categories set name = v_name, active = v_active where id = v_id returning id into v_id;
    if v_id is null then
      raise exception 'NOT_FOUND: Kategori tidak ditemukan' using errcode = '22023';
    end if;
  else
    insert into private.categories(name, active) values (v_name, v_active) returning id into v_id;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'UPSERT_CATEGORY', 'CATEGORY', v_id, v_name);
  return private.finish_operation('upsert_category_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.upsert_category_v1(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_category_v1(jsonb) to authenticated;

create or replace function public.list_categories_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name), '[]'::jsonb)
    into v_result
    from private.categories c where c.active;
  return v_result;
end $$;
revoke all on function public.list_categories_v1() from public, anon, authenticated;
grant execute on function public.list_categories_v1() to authenticated;
