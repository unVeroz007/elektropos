-- Keputusan pemilik 18 September 2026: satuan dengan isi > 1 tidak otomatis berarti "roll utuh bersegel".
-- Kabel dapat dijual per meter, per roll, atau satuan lain (mis. "ikat 10 m") yang dipotong dari satu potongan.
-- Hanya satuan bertanda whole_roll yang mewajibkan roll bersegel berkapasitas persis sama dengan isi satuan.

alter table private.product_units add column if not exists whole_roll boolean not null default false;
alter table private.product_units drop constraint if exists product_units_whole_roll_factor;
alter table private.product_units add constraint product_units_whole_roll_factor
  check (not whole_roll or factor_base > 1);

-- Data lama: sebelumnya semua satuan isi > 1 pada barang roll diperlakukan roll utuh.
-- Pertahankan perilaku itu hanya untuk satuan yang memang bernama roll.
update private.product_units u set whole_roll = true
  from private.products p
  where p.id = u.product_id and p.track_segments and u.factor_base > 1 and u.label ilike '%roll%' and not u.whole_roll;

-- Validasi bersama: roll utuh hanya untuk barang roll dan satuan berisi lebih dari 1 satuan dasar.
create or replace function private.catalog_check_whole_roll(p_whole_roll boolean, p_track boolean, p_factor numeric)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_whole_roll and not p_track then
    raise exception 'INVALID_INPUT: Roll utuh hanya untuk barang yang dilacak per roll/potongan' using errcode = '22023';
  end if;
  if p_whole_roll and p_factor <= 1 then
    raise exception 'INVALID_INPUT: Roll utuh harus berisi lebih dari 1 satuan dasar (mis. roll 100 m)' using errcode = '22023';
  end if;
end $$;
revoke all on function private.catalog_check_whole_roll(boolean, boolean, numeric) from public, anon, authenticated;


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
  v_whole_roll boolean;
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
    'sell_price', 'barcode', 'shelf', 'reason', 'category_id', 'whole_roll'], 'produk');

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
  if p_input->'whole_roll' is not null and jsonb_typeof(p_input->'whole_roll') not in ('boolean', 'null') then
    raise exception 'INVALID_INPUT: whole_roll harus true/false' using errcode = '22023';
  end if;
  v_whole_roll := coalesce((p_input->>'whole_roll')::boolean, false);
  v_qty_step := private.decimal_input(p_input->'quantity_step', 3, 999999999.999);
  v_factor := private.decimal_input(p_input->'factor_base', 3, 1000000);
  v_step := private.decimal_input(p_input->'sale_step', 3, 999999999.999);
  v_price := private.decimal_input(p_input->'sell_price', 6, 999999999999.999999);
  if round(v_step * v_factor, 3) <> v_step * v_factor or mod(v_step * v_factor, v_qty_step) <> 0 then
    raise exception 'INVALID_QUANTITY: Langkah jual × faktor harus kelipatan langkah stok' using errcode = '22023';
  end if;
  perform private.catalog_check_whole_roll(v_whole_roll, v_track, v_factor);
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
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default, whole_roll)
    values (v_product.id, v_label, v_factor, v_step, v_price, true, v_whole_roll)
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
       or v_unit.sale_step <> v_step or v_unit.sell_price <> v_price or v_unit.whole_roll <> v_whole_roll then
      v_unit_changed := true;
      if v_unit.id is not null then
        update private.product_units set active = false, is_default = false where id = v_unit.id;
      end if;
      insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default, version,
        whole_roll)
      values (v_product.id, v_label, v_factor, v_step, v_price, true, coalesce(v_unit.version, 0) + 1, v_whole_roll)
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
            'is_default', u.is_default, 'whole_roll', u.whole_roll, 'version', u.version)
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
        'is_default', u.is_default, 'whole_roll', u.whole_roll, 'version', u.version, 'active', u.active)
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
    'whole_roll', v_unit.whole_roll,
    'stock_shop', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'SHOP' and s.condition = 'SALEABLE'),
    'stock_field', (select coalesce(sum(s.qty_base), 0)::text
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE'));
end $$;

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
    'unit_label', 'factor_base', 'sale_step', 'sell_price', 'barcode', 'shelf', 'whole_roll'];
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
    if coalesce(lower(trim(v_row->>'whole_roll')), '') not in ('', 'true', 'false') then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_WHOLE_ROLL', 'message', 'whole_roll harus true/false');
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
    if lower(trim(coalesce(v_row->>'whole_roll', ''))) = 'true'
       and (lower(trim(coalesce(v_row->>'track_segments', ''))) <> 'true' or coalesce(v_factor, 0) <= 1) then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_WHOLE_ROLL',
        'message', 'Roll utuh hanya untuk barang roll (track_segments=true) dengan faktor lebih dari 1');
    end if;
  end loop;
  return v_errors;
end $$;

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
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default, whole_roll)
    values (v_id, trim(v_row->>'unit_label'), (v_row->>'factor_base')::numeric,
      (v_row->>'sale_step')::numeric, (v_row->>'sell_price')::numeric, true,
      coalesce(nullif(lower(trim(v_row->>'whole_roll')), '')::boolean, false))
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

create or replace function private.sales_price_cart(p_input jsonb, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_max_money constant numeric := 9999999999999999;
  v_line jsonb;
  v_no integer := 0;
  v_count integer;
  v_unit private.product_units%rowtype;
  v_product private.products%rowtype;
  v_unit_id uuid;
  v_expected integer;
  v_pos_id uuid;
  v_pos_version integer;
  v_qty numeric;
  v_base numeric;
  v_gross numeric;
  v_disc numeric;
  v_mode text;
  v_value numeric;
  v_bnet numeric;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_total numeric;
  v_inv_mode text;
  v_inv_value numeric;
  v_lines jsonb := '[]'::jsonb;
  v_final jsonb;
  v_sum_alloc numeric;
  v_sum_net numeric;
begin
  if p_input->'items' is null or jsonb_typeof(p_input->'items') <> 'array' then
    raise exception 'INVALID_INPUT: Daftar barang wajib diisi' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_input->'items');
  if v_count < 1 or v_count > 100 then
    raise exception 'INVALID_INPUT: Daftar barang harus 1-100 baris' using errcode = '22023';
  end if;

  select d.mode, d.value into v_inv_mode, v_inv_value
    from private.sales_discount_input(p_input->'discount_mode', p_input->'discount_value', p_role, 'nota') d;

  for v_line in select e from jsonb_array_elements(p_input->'items') with ordinality t(e, n) order by n loop
    v_no := v_no + 1;
    perform private.sales_reject_unknown(v_line, array['product_unit_id', 'qty', 'expected_unit_version',
      'discount_mode', 'discount_value', 'position_id', 'expected_position_version'], 'baris ' || v_no);
    v_unit_id := private.sales_uuid_input(v_line->'product_unit_id', 'Satuan barang baris ' || v_no);
    v_expected := private.sales_int_input(v_line->'expected_unit_version', 'Versi satuan baris ' || v_no);
    v_pos_id := private.sales_uuid_input(v_line->'position_id', 'Potongan/roll baris ' || v_no, false);
    v_pos_version := private.sales_int_input(v_line->'expected_position_version', 'Versi potongan baris ' || v_no);
    v_qty := private.decimal_input(v_line->'qty', 3, 999999999.999);
    select d.mode, d.value into v_mode, v_value
      from private.sales_discount_input(v_line->'discount_mode', v_line->'discount_value', p_role, 'baris ' || v_no) d;

    select * into v_unit from private.product_units where id = v_unit_id;
    if not found then
      raise exception 'NOT_FOUND: Satuan barang pada baris % tidak ditemukan', v_no using errcode = '22023';
    end if;
    select * into v_product from private.products where id = v_unit.product_id;
    if not v_product.active then
      raise exception 'NOT_FOUND: Barang "%" sudah diarsip dan tidak dapat dijual', v_product.name
        using errcode = '22023';
    end if;
    if not v_unit.active or (v_expected is not null and v_expected <> v_unit.version) then
      raise exception 'PRICE_CHANGED: Harga/satuan "% (%)" berubah sejak keranjang dibuat. Muat ulang lalu periksa keranjang.',
        v_product.name, v_unit.label
        using errcode = '40001',
          detail = coalesce((
            select jsonb_build_object('product_id', v_product.id, 'current_unit_id', u.id,
              'label', u.label, 'sell_price', u.sell_price::text, 'version', u.version)::text
            from private.product_units u
            where u.product_id = v_product.id and u.active
            order by (u.id = v_unit.id) desc, u.is_default desc, u.label limit 1), '{}');
    end if;

    if mod(v_qty, v_unit.sale_step) <> 0 then
      raise exception 'INVALID_QUANTITY: Jumlah "%" harus kelipatan % %', v_product.name,
        trim_scale(v_unit.sale_step)::text, v_unit.label using errcode = '22023';
    end if;
    v_base := v_qty * v_unit.factor_base;
    if v_base <> round(v_base, 3) or v_base > 999999999.999 or mod(v_base, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_QUANTITY: Jumlah "%" tidak sesuai langkah stok %', v_product.name, v_product.base_unit
        using errcode = '22023';
    end if;

    -- BR-04 langkah 1-4: G eksak, D dari G eksak, B dibulatkan setelah diskon.
    v_gross := v_qty * v_unit.sell_price;
    if v_gross > c_max_money then
      raise exception 'INVALID_NUMBER: Nilai baris % melebihi batas', v_no using errcode = '22023';
    end if;
    v_disc := case v_mode
      when 'percent' then v_gross * v_value * 0.01
      when 'amount' then v_value
      else 0 end;
    if v_disc > v_gross then
      raise exception 'INVALID_INPUT: Diskon baris % melebihi nilai baris', v_no using errcode = '22023';
    end if;
    v_bnet := round(v_gross - v_disc, 0);
    v_subtotal := v_subtotal + v_bnet;

    v_lines := v_lines || jsonb_build_object(
      'line_no', v_no, 'product_id', v_product.id, 'product_unit_id', v_unit.id,
      'unit_version', v_unit.version, 'product_name', v_product.name, 'sku', v_product.sku,
      'unit_label', v_unit.label, 'base_unit', v_product.base_unit,
      'factor_base', v_unit.factor_base, 'track_segments', v_product.track_segments,
      'whole_roll', v_product.track_segments and v_unit.whole_roll,
      'qty_sell', v_qty, 'qty_base', v_base, 'unit_price', v_unit.sell_price,
      'discount_mode', v_mode, 'discount_value', v_value,
      'gross_exact', v_gross, 'line_discount_exact', v_disc, 'base_net', v_bnet,
      'position_id', v_pos_id, 'expected_position_version', v_pos_version);
  end loop;

  if v_subtotal > c_max_money then
    raise exception 'INVALID_NUMBER: Total nota melebihi batas' using errcode = '22023';
  end if;

  -- BR-04 langkah 6-7.
  v_discount := case v_inv_mode
    when 'percent' then round(v_subtotal * v_inv_value * 0.01, 0)
    when 'amount' then v_inv_value
    else 0 end;
  if v_discount > v_subtotal then
    raise exception 'INVALID_INPUT: Diskon nota melebihi subtotal' using errcode = '22023';
  end if;
  v_total := v_subtotal - v_discount;

  -- Alokasi diskon nota: floor(D×B_i/S) lalu sisa ke remainder terbesar, seri line_no naik.
  select coalesce(jsonb_agg(x.e || jsonb_build_object(
      'invoice_discount_alloc', x.a, 'net_total', (x.e->>'base_net')::numeric - x.a) order by x.n), '[]'::jsonb),
    coalesce(sum(x.a), 0), coalesce(sum((x.e->>'base_net')::numeric - x.a), 0)
  into v_final, v_sum_alloc, v_sum_net
  from (
    select f.e, f.n,
      f.a0 + case when row_number() over (order by f.rem desc, f.n) <= v_discount - sum(f.a0) over ()
                  then 1 else 0 end as a
    from (
      select e, (e->>'line_no')::integer as n,
        case when v_subtotal > 0 then div(v_discount * (e->>'base_net')::numeric, v_subtotal) else 0 end as a0,
        case when v_subtotal > 0 then mod(v_discount * (e->>'base_net')::numeric, v_subtotal) else 0 end as rem
      from jsonb_array_elements(v_lines) e
    ) f
  ) x;

  if v_sum_alloc <> v_discount or v_sum_net <> v_total then
    raise exception 'INTERNAL_ERROR: Invariant alokasi diskon gagal' using errcode = 'XX000';
  end if;

  return jsonb_build_object('lines', v_final, 'subtotal', v_subtotal,
    'discount_mode', v_inv_mode, 'discount_value', v_inv_value,
    'discount_total', v_discount, 'total', v_total);
end $$;

create or replace function public.finalize_sale_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_max_money constant numeric := 9999999999999999;
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_op uuid;
  v_reason text;
  v_client_ref uuid;
  v_intent uuid;
  v_customer uuid;
  v_payment jsonb;
  v_method text;
  v_reference text;
  v_tendered numeric;
  v_change numeric := 0;
  v_session private.cash_sessions%rowtype;
  v_cart jsonb;
  v_line jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_total numeric;
  v_roll_pos uuid[] := '{}';
  v_bulk_products uuid[] := '{}';
  v_need record;
  v_pos record;
  v_avail numeric;
  v_existing text;
  v_invoice_id uuid;
  v_number text;
  v_item_id uuid;
  v_left numeric;
  v_take numeric;
  v_cost numeric;
  v_payment_id uuid;
  v_items_out jsonb;
  v_result jsonb;
begin
  v_old := private.sales_begin_command('finalize_sale_v1', p_input, array['OWNER', 'STAFF']);
  if v_old is not null then return v_old; end if;
  select role into v_role from private.app_profiles where id = v_actor;
  v_op := (p_input->>'operation_id')::uuid;

  perform private.sales_reject_unknown(p_input, array['operation_id', 'client_reference_id', 'customer_id',
    'items', 'discount_mode', 'discount_value', 'payment', 'reason', 'payment_intent_id'], 'penjualan');
  v_reason := private.sales_text_input(p_input->'reason', 'Alasan', 500);
  v_client_ref := private.sales_uuid_input(p_input->'client_reference_id', 'client_reference_id', false);
  v_intent := private.sales_uuid_input(p_input->'payment_intent_id', 'payment_intent_id', false);
  v_customer := private.sales_uuid_input(p_input->'customer_id', 'Pelanggan', false);

  v_payment := p_input->'payment';
  if v_payment is not null and jsonb_typeof(v_payment) <> 'null' then
    perform private.sales_reject_unknown(v_payment, array['method', 'tendered', 'confirmed', 'reference'], 'pembayaran');
    v_method := v_payment->>'method';
    if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS') then
      raise exception 'INVALID_INPUT: Metode bayar harus CASH, TRANSFER, atau QRIS' using errcode = '22023';
    end if;
    v_reference := private.sales_text_input(v_payment->'reference', 'Referensi pembayaran', 100);
  end if;

  -- Urutan kunci API-02: sesi kas -> produk -> lot -> posisi -> nomor dokumen.
  if v_method = 'CASH' then
    v_session := private.lock_open_cash_session('SHOP_DRAWER');
  end if;

  perform 1 from private.products p
    where p.id in (select u.product_id from private.product_units u
      where u.id::text in (select x->>'product_unit_id'
        from jsonb_array_elements(case when jsonb_typeof(p_input->'items') = 'array'
          then p_input->'items' else '[]'::jsonb end) x))
    order by p.id for update;

  -- Harga dibaca ulang setelah produk terkunci.
  v_cart := private.sales_price_cart(p_input, v_role);
  v_subtotal := (v_cart->>'subtotal')::numeric;
  v_discount := (v_cart->>'discount_total')::numeric;
  v_total := (v_cart->>'total')::numeric;

  -- Pembayaran (BR-07).
  if v_total = 0 then
    if v_role <> 'OWNER' then
      raise exception 'APPROVAL_REQUIRED: Nota bernilai nol hanya dapat diproses owner' using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'APPROVAL_REQUIRED: Nota bernilai nol wajib diberi alasan' using errcode = '22023';
    end if;
    v_method := null;
  elsif v_method is null then
    raise exception 'INVALID_INPUT: Metode pembayaran wajib dipilih' using errcode = '22023';
  elsif v_method = 'CASH' then
    v_tendered := private.decimal_input(v_payment->'tendered', 0, c_max_money, false);
    if v_tendered < v_total then
      raise exception 'INSUFFICIENT_PAYMENT: Uang diterima kurang dari total belanja' using errcode = '22023';
    end if;
    v_change := v_tendered - v_total;
  else
    if (v_payment->'confirmed') is distinct from 'true'::jsonb then
      raise exception 'PAYMENT_NOT_CONFIRMED: Pembayaran % harus dikonfirmasi petugas sudah diterima', v_method
        using errcode = '22023';
    end if;
  end if;

  -- Rencana stok: roll wajib posisi pilihan; bulk tidak boleh memilih posisi.
  for v_line in select e from jsonb_array_elements(v_cart->'lines') e loop
    if (v_line->>'track_segments')::boolean then
      if v_line->>'position_id' is null then
        raise exception 'POSITION_REQUIRED: Pilih roll/potongan fisik untuk "%" (baris %)',
          v_line->>'product_name', v_line->>'line_no' using errcode = '22023';
      end if;
      v_roll_pos := v_roll_pos || (v_line->>'position_id')::uuid;
    else
      if v_line->>'position_id' is not null then
        raise exception 'INVALID_INPUT: Barang "%" tidak memakai pilihan potongan', v_line->>'product_name'
          using errcode = '22023';
      end if;
      v_bulk_products := v_bulk_products || (v_line->>'product_id')::uuid;
    end if;
  end loop;

  perform 1 from private.inventory_lots l
    where l.id in (
      select s.lot_id from private.stock_positions s where s.id = any (v_roll_pos)
      union
      select s.lot_id from private.stock_positions s
        join private.inventory_lots x on x.id = s.lot_id
        where x.product_id = any (v_bulk_products)
          and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0)
    order by l.id for update;
  perform 1 from private.stock_positions s
    where s.id = any (v_roll_pos)
       or (s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0
           and s.lot_id in (select x.id from private.inventory_lots x where x.product_id = any (v_bulk_products)))
    order by s.id for update;

  -- K05/BR-03: satu baris roll = satu posisi fisik; kebutuhan diagregasi per posisi.
  for v_need in
    select e->>'position_id' as position_id,
      sum((e->>'qty_base')::numeric) as need,
      count(*) as line_count,
      bool_or(coalesce((e->>'whole_roll')::boolean, false)) as whole_roll,
      max((e->>'factor_base')::numeric) as factor,
      max((e->>'qty_sell')::numeric) as qty_sell,
      min(e->>'product_id') as product_id,
      min(e->>'product_name') as product_name,
      min(e->>'base_unit') as base_unit,
      bool_or(e->>'expected_position_version' is not null) as has_version,
      min((e->>'expected_position_version')::integer) as min_version,
      max((e->>'expected_position_version')::integer) as max_version
    from jsonb_array_elements(v_cart->'lines') e
    where (e->>'track_segments')::boolean
    group by e->>'position_id'
  loop
    select s.id, s.label, s.location, s.condition, s.qty_base, s.segment_capacity, s.sealed, s.version,
      l.product_id
      into v_pos
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where s.id = v_need.position_id::uuid;
    if not found then
      raise exception 'NOT_FOUND: Potongan/roll untuk "%" tidak ditemukan', v_need.product_name using errcode = '22023';
    end if;
    if v_pos.product_id::text <> v_need.product_id then
      raise exception 'INVALID_INPUT: Potongan % bukan milik barang "%"', coalesce(v_pos.label, '-'), v_need.product_name
        using errcode = '22023';
    end if;
    if v_pos.location <> 'SHOP' or v_pos.condition <> 'SALEABLE' or v_pos.qty_base <= 0 then
      raise exception 'INSUFFICIENT_STOCK: Potongan % tidak tersedia untuk dijual (habis, rusak, atau tidak di toko)',
        coalesce(v_pos.label, '-') using errcode = '22023';
    end if;
    if v_need.has_version and (v_need.min_version <> v_pos.version or v_need.max_version <> v_pos.version) then
      raise exception 'VERSION_CONFLICT: Potongan % sudah berubah. Muat ulang daftar potongan.', coalesce(v_pos.label, '-')
        using errcode = '40001';
    end if;
    if v_need.whole_roll then
      if v_need.line_count > 1 then
        raise exception 'INVALID_INPUT: Roll % tidak boleh dipakai lebih dari satu baris', coalesce(v_pos.label, '-')
          using errcode = '22023';
      end if;
      if v_need.qty_sell <> 1 then
        raise exception 'INVALID_QUANTITY: Satu baris hanya untuk satu roll utuh; tambahkan baris per roll'
          using errcode = '22023';
      end if;
      if not v_pos.sealed or v_pos.segment_capacity <> v_need.factor or v_pos.qty_base <> v_need.factor then
        raise exception 'SEGMENT_NOT_SEALED: Roll utuh harus diambil dari roll bersegel berkapasitas % %; % tidak memenuhi',
          trim_scale(v_need.factor)::text, v_need.base_unit, coalesce(v_pos.label, '-')
          using errcode = '22023';
      end if;
    elsif v_need.need > v_pos.qty_base then
      raise exception 'SEGMENT_TOO_SHORT: Potongan % hanya tersisa % %; satu potongan tidak dapat digabung dengan potongan lain',
        coalesce(v_pos.label, '-'), trim_scale(v_pos.qty_base)::text, v_need.base_unit
        using errcode = '22023';
    end if;
  end loop;

  -- K04: kebutuhan bulk diagregasi per produk sebelum cek stok.
  for v_need in
    select e->>'product_id' as product_id, min(e->>'product_name') as product_name,
      min(e->>'base_unit') as base_unit, sum((e->>'qty_base')::numeric) as need
    from jsonb_array_elements(v_cart->'lines') e
    where not (e->>'track_segments')::boolean
    group by e->>'product_id'
  loop
    select coalesce(sum(s.qty_base), 0) into v_avail
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_need.product_id::uuid and s.location = 'SHOP' and s.condition = 'SALEABLE';
    if v_avail < v_need.need then
      raise exception 'INSUFFICIENT_STOCK: Stok "%" di toko tidak cukup (tersedia % %)', v_need.product_name,
        trim_scale(v_avail)::text, v_need.base_unit using errcode = '22023';
    end if;
  end loop;

  if v_client_ref is not null then
    select number into v_existing from private.invoices where client_reference_id = v_client_ref;
    if found then
      raise exception 'ALREADY_FINALIZED: Keranjang ini sudah menjadi nota %', v_existing using errcode = '22023';
    end if;
  end if;
  if v_intent is not null and exists (select 1 from private.payments where intent_id = v_intent) then
    raise exception 'ALREADY_FINALIZED: Pembayaran ini sudah tercatat' using errcode = '22023';
  end if;
  if v_customer is not null and not exists (select 1 from private.customers where id = v_customer) then
    raise exception 'NOT_FOUND: Pelanggan tidak ditemukan' using errcode = '22023';
  end if;

  -- Penulisan.
  v_number := private.next_invoice_number('SALE');
  insert into private.invoices(number, kind, actor_id, subtotal_net_lines, discount_total, total,
    customer_id, client_reference_id, operation_id, free_reason)
  values (v_number, 'SALE', v_actor, v_subtotal, v_discount, v_total,
    v_customer, v_client_ref, v_op, case when v_total = 0 then v_reason end)
  returning id into v_invoice_id;

  for v_line in select e from jsonb_array_elements(v_cart->'lines') with ordinality t(e, n) order by n loop
    insert into private.invoice_items(invoice_id, line_no, kind, product_id, product_unit_id,
      description_snapshot, unit_label_snapshot, qty_sell, factor_snapshot, qty_base, unit_price_snapshot,
      item_discount_mode, item_discount_value, item_discount_exact,
      gross_exact, base_net, invoice_discount_alloc, net_total)
    values (v_invoice_id, (v_line->>'line_no')::integer, 'PRODUCT', (v_line->>'product_id')::uuid,
      (v_line->>'product_unit_id')::uuid,
      (v_line->>'product_name') || ' (' || (v_line->>'unit_label') || ')', v_line->>'unit_label',
      (v_line->>'qty_sell')::numeric, (v_line->>'factor_base')::numeric, (v_line->>'qty_base')::numeric,
      (v_line->>'unit_price')::numeric,
      v_line->>'discount_mode', (v_line->>'discount_value')::numeric,
      case when v_line->>'discount_mode' is not null then (v_line->>'line_discount_exact')::numeric end,
      (v_line->>'gross_exact')::numeric, (v_line->>'base_net')::numeric,
      (v_line->>'invoice_discount_alloc')::numeric, (v_line->>'net_total')::numeric)
    returning id into v_item_id;

    -- Bulk: FIFO (lot.posted_at, lot.id, position.id). Roll: posisi pilihan saja.
    v_left := (v_line->>'qty_base')::numeric;
    for v_pos in
      select s.id, s.lot_id, s.qty_base
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where case when (v_line->>'track_segments')::boolean
        then s.id = (v_line->>'position_id')::uuid
        else l.product_id = (v_line->>'product_id')::uuid
          and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0 end
      order by l.posted_at, l.id, s.id
    loop
      exit when v_left = 0;
      v_take := least(v_pos.qty_base, v_left);
      continue when v_take <= 0;
      v_cost := private.cost_for_exit_lot(v_pos.lot_id, v_take);
      update private.stock_positions
        set qty_base = qty_base - v_take, sealed = false, version = version + 1
        where id = v_pos.id;
      update private.inventory_lots
        set remaining_qty = remaining_qty - v_take, remaining_cost = remaining_cost - v_cost, version = version + 1
        where id = v_pos.lot_id;
      insert into private.cost_allocations(lot_id, origin_position_id, invoice_item_id, qty_base, cost_amount)
      values (v_pos.lot_id, v_pos.id, v_item_id, v_take, v_cost);
      insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
        invoice_item_id, actor_id, operation_id)
      values (v_invoice_id, v_pos.lot_id, v_pos.id, -v_take, -v_cost, 'SALE_OUT', v_item_id, v_actor, v_op);
      v_left := v_left - v_take;
    end loop;
    -- K04: alokasi harus habis; tidak ada nota yang lebih besar dari stok keluar.
    if v_left <> 0 then
      raise exception 'INSUFFICIENT_STOCK: Stok "%" tidak cukup', v_line->>'product_name' using errcode = '22023';
    end if;
  end loop;

  if v_total > 0 then
    insert into private.payments(direction, purpose, invoice_id, method, amount, tendered, change,
      cash_session_id, reference, confirmed_by, actor_id, intent_id, operation_id)
    values ('IN', 'SALE_RECEIPT', v_invoice_id, v_method, v_total,
      case when v_method = 'CASH' then v_tendered end, v_change,
      case when v_method = 'CASH' then v_session.id end, v_reference,
      case when v_method <> 'CASH' then v_actor end, v_actor, v_intent, v_op)
    returning id into v_payment_id;
    if v_method = 'CASH' then
      insert into private.cash_movements(session_id, direction, kind, amount, payment_id, actor_id, operation_id)
      values (v_session.id, 'IN', 'CUSTOMER_PAYMENT', v_total, v_payment_id, v_actor, v_op);
    end if;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, case when v_total = 0 then 'SALE_FINALIZE_FREE' else 'SALE_FINALIZE' end,
    'INVOICE', v_invoice_id, v_reason);

  select coalesce(jsonb_agg(jsonb_build_object(
      'invoice_item_id', ii.id, 'line_no', ii.line_no, 'product_unit_id', ii.product_unit_id,
      'description', ii.description_snapshot, 'unit_label', ii.unit_label_snapshot,
      'qty_sell', ii.qty_sell::text, 'qty_base', ii.qty_base::text,
      'unit_price', ii.unit_price_snapshot::text, 'gross_exact', ii.gross_exact::text,
      'line_discount', coalesce(ii.item_discount_exact, 0)::text, 'base_net', ii.base_net::text,
      'invoice_discount_alloc', ii.invoice_discount_alloc::text, 'net_total', ii.net_total::text)
      order by ii.line_no), '[]'::jsonb)
    into v_items_out
    from private.invoice_items ii where ii.invoice_id = v_invoice_id;

  v_result := jsonb_build_object(
    'ok', true, 'entity_id', v_invoice_id, 'document_number', v_number,
    'operation_id', v_op, 'server_time', now(), 'schema_version', 2,
    'subtotal', v_subtotal::text, 'discount', v_discount::text, 'total', v_total::text,
    'payment_id', v_payment_id, 'payment_method', v_method,
    'tendered', case when v_method = 'CASH' then v_tendered::text end,
    'change', v_change::text, 'items', v_items_out);
  return private.finish_operation('finalize_sale_v1', p_input, v_result);
end $$;
