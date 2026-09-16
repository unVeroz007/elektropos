-- P4: katalog impor CSV + ekspor CSV aman formula

-- Netralkan formula spreadsheet (SEC-04)
create or replace function private.csv_safe(p_text text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if p_text is null then return null; end if;
  v := p_text;
  -- Buang whitespace/control di awal
  if v ~ '^[[:space:][:cntrl:]]*[=+\-@]' then
    v := '''' || v;
  end if;
  return v;
end $$;
revoke all on function private.csv_safe(text) from public,anon,authenticated;

-- preview_catalog_import_v1 — validasi batch tanpa posting stok
create or replace function public.preview_catalog_import_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row jsonb;
  v_line integer := 0;
  v_errors jsonb := '[]'::jsonb;
  v_seen_sku text[] := '{}';
  v_seen_barcode text[] := '{}';
  v_sku text;
  v_barcode text;
  v_dup integer;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengimpor katalog' using errcode = '42501';
  end if;
  if jsonb_typeof(p_input->'rows') <> 'array' then
    raise exception 'rows wajib array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_input->'rows') > 200 then
    raise exception 'Maksimal 200 baris per batch' using errcode = '22023';
  end if;

  for v_row in select value from jsonb_array_elements(p_input->'rows') loop
    v_line := v_line + 1;
    v_sku := trim(coalesce(v_row->>'sku', ''));
    v_barcode := nullif(trim(coalesce(v_row->>'barcode', '')), '');

    if length(v_sku) not between 1 and 60 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_SKU',
        'message', 'SKU wajib (1-60 karakter)');
    elsif v_sku = any(v_seen_sku) then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_SKU',
        'message', 'SKU duplikat dalam batch: ' || v_sku);
    else
      v_seen_sku := v_seen_sku || lower(v_sku);
      select count(*) into v_dup from private.products where lower(sku) = lower(v_sku);
      if v_dup > 0 then
        v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_SKU',
          'message', 'SKU sudah ada di database: ' || v_sku);
      end if;
    end if;

    if v_barcode is not null then
      if v_barcode = any(v_seen_barcode) then
        v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_BARCODE',
          'message', 'Barcode duplikat dalam batch');
      else
        v_seen_barcode := v_seen_barcode || v_barcode;
        select count(*) into v_dup from private.product_barcodes where code = v_barcode;
        if v_dup > 0 then
          v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'DUPLICATE_BARCODE',
            'message', 'Barcode sudah ada: ' || v_barcode);
        end if;
      end if;
    end if;

    if length(trim(coalesce(v_row->>'name', ''))) not between 1 and 150 then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_NAME',
        'message', 'Nama wajib (1-150 karakter)');
    end if;

    if coalesce(v_row->>'sell_price', '') !~ '^(0|[1-9][0-9]*)(\.[0-9]+)?$' then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_PRICE',
        'message', 'Harga tidak valid');
    end if;

    if coalesce(v_row->>'factor_base', '') !~ '^(0|[1-9][0-9]*)(\.[0-9]+)?$' then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'code', 'INVALID_FACTOR',
        'message', 'Faktor konversi tidak valid');
    end if;
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_errors) = 0,
    'total', v_line,
    'valid', v_line - jsonb_array_length(v_errors),
    'errors', v_errors);
end $$;
revoke all on function public.preview_catalog_import_v1(jsonb) from public,anon,authenticated;
grant execute on function public.preview_catalog_import_v1(jsonb) to authenticated;

-- commit_catalog_import_v1 — impor atomik per batch
create or replace function public.commit_catalog_import_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_row jsonb;
  v_ids jsonb := '[]'::jsonb;
  v_id uuid;
  v_sku text;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengimpor katalog' using errcode = '42501';
  end if;
  v_old := private.operation_result('commit_catalog_import_v1', p_input);
  if v_old is not null then return v_old; end if;

  if jsonb_typeof(p_input->'rows') <> 'array' or jsonb_array_length(p_input->'rows') not between 1 and 200 then
    raise exception 'Rows wajib (1-200 baris)' using errcode = '22023';
  end if;

  for v_row in select value from jsonb_array_elements(p_input->'rows') loop
    v_sku := trim(v_row->>'sku');

    insert into private.products(sku, name, specification, base_unit, quantity_step,
      track_segments, shelf)
    values (v_sku, trim(v_row->>'name'), coalesce(v_row->>'specification', ''),
      trim(v_row->>'base_unit'), (v_row->>'quantity_step')::numeric,
      coalesce((v_row->>'track_segments')::boolean, false),
      nullif(trim(coalesce(v_row->>'shelf', '')), ''))
    returning id into v_id;

    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_id, trim(v_row->>'unit_label'), (v_row->>'factor_base')::numeric,
      (v_row->>'sale_step')::numeric, (v_row->>'sell_price')::numeric, true);

    if coalesce(trim(v_row->>'barcode'), '') <> '' then
      insert into private.product_barcodes(product_id, product_unit_id, code)
      select v_id, u.id, trim(v_row->>'barcode')
      from private.product_units u where u.product_id = v_id and u.is_default;
    end if;

    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  insert into private.audit_events(actor_id, action, entity_type, reason)
  values (v_actor, 'IMPORT_CATALOG', 'PRODUCT', p_input->>'import_hash');

  return private.finish_operation('commit_catalog_import_v1', p_input, jsonb_build_object(
    'ok', true, 'count', jsonb_array_length(v_ids), 'ids', v_ids,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.commit_catalog_import_v1(jsonb) from public,anon,authenticated;
grant execute on function public.commit_catalog_import_v1(jsonb) to authenticated;

-- export_csv_v1 — diganti dengan versi aman formula
create or replace function public.export_csv_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_dataset text;
  v_start date;
  v_end date;
  v_rows jsonb;
  v_chunk integer := least(coalesce((p_input->>'limit')::integer, 1000), 1000);
  v_offset integer := coalesce((p_input->>'offset')::integer, 0);
begin
  v_role := private.current_role();
  if v_role not in ('OWNER', 'MAINTAINER') then
    raise exception 'Hanya owner/maintainer dapat mengekspor' using errcode = '42501';
  end if;

  v_dataset := p_input->>'dataset';
  v_start := (p_input->>'start_date')::date;
  v_end := (p_input->>'end_date')::date;
  if v_start is null or v_end is null then
    raise exception 'Rentang tanggal wajib' using errcode = '22023';
  end if;
  if (v_end - v_start) > 366 then
    raise exception 'Rentang ekspor maksimal 366 hari' using errcode = '22023';
  end if;

  if v_dataset = 'invoices' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'number', private.csv_safe(i.number),
      'kind', i.kind,
      'posted_at', to_char(i.posted_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI'),
      'subtotal', i.subtotal_net_lines::text,
      'discount', i.discount_total::text,
      'total', i.total::text,
      'petugas', private.csv_safe(coalesce(pr.display_name, ''))
    ) order by i.posted_at desc), '[]'::jsonb) into v_rows
    from private.invoices i
    left join private.app_profiles pr on pr.id = i.actor_id
    where i.posted_at >= v_start::timestamptz at time zone 'Asia/Jakarta'
      and i.posted_at < (v_end + 1)::timestamptz at time zone 'Asia/Jakarta'
    limit v_chunk offset v_offset;

  elsif v_dataset = 'products' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sku', private.csv_safe(p.sku),
      'name', private.csv_safe(p.name),
      'specification', private.csv_safe(p.specification),
      'base_unit', private.csv_safe(p.base_unit),
      'shelf', private.csv_safe(coalesce(p.shelf, '')),
      'aktif', p.active
    ) order by p.sku), '[]'::jsonb) into v_rows
    from private.products p
    limit v_chunk offset v_offset;

  else
    raise exception 'Dataset tidak dikenal: %', v_dataset using errcode = '22023';
  end if;

  return jsonb_build_object(
    'ok', true, 'rows', v_rows, 'count', jsonb_array_length(v_rows),
    'timezone', 'Asia/Jakarta', 'offset', v_offset,
    'has_more', jsonb_array_length(v_rows) = v_chunk);
end $$;
revoke all on function public.export_csv_v1(jsonb) from public,anon,authenticated;
grant execute on function public.export_csv_v1(jsonb) to authenticated;
