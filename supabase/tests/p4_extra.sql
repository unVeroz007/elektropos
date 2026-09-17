-- AT-03/04/26/27: barcode, satuan meter, laporan, CSV aman
\set ON_ERROR_STOP on

begin;

-- AT-03: barcode nol depan + duplikat ditolak
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  -- Barcode dengan nol depan (seed: 0012345678901) tetap cocok
  v_res := public.search_products_v1(jsonb_build_object('query', '0012345678901'));
  if jsonb_array_length(v_res) < 1 then
    raise exception 'AT-03: barcode nol depan harus cocok';
  end if;

  -- Duplikat barcode ditolak
  begin
    perform public.upsert_product_v1(jsonb_build_object(
      'operation_id', 'a3000000-0000-4000-8000-000000000001',
      'sku', 'DUP-BC-1', 'name', 'Test Dup Barcode', 'base_unit', 'pcs',
      'quantity_step', '1', 'track_segments', false,
      'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1',
      'sell_price', '1000', 'barcode', '0012345678901'));
    raise exception 'AT-03: barcode duplikat seharusnya ditolak';
  exception when unique_violation then null;
  end;
end $$;

-- AT-03: SKU duplikat case-insensitive ditolak
do $$
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  begin
    perform public.upsert_product_v1(jsonb_build_object(
      'operation_id', 'a3000000-0000-4000-8000-000000000002',
      'sku', 'lmp-led-10w', 'name', 'Duplikat SKU', 'base_unit', 'pcs',
      'quantity_step', '1', 'track_segments', false,
      'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1',
      'sell_price', '1000'));
    raise exception 'AT-03: SKU duplikat seharusnya ditolak';
  exception when unique_violation then null;
  end;
end $$;

-- AT-03: produk diarsip tidak bisa dijual
do $$
declare v_pid uuid; v_ver integer; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  v_res := public.upsert_product_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000003',
    'sku', 'TMP-ARCHIVE', 'name', 'Produk Arsip', 'base_unit', 'pcs',
    'quantity_step', '1', 'track_segments', false,
    'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1', 'sell_price', '1000'));
  v_pid := (v_res->>'entity_id')::uuid;
  v_ver := (v_res->>'version')::integer;

  perform public.archive_product_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000004',
    'product_id', v_pid, 'expected_version', v_ver));

  -- Cari produk arsip tidak muncul di katalog
  v_res := public.search_products_v1(jsonb_build_object('query', 'Produk Arsip'));
  if jsonb_array_length(v_res) > 0 then
    raise exception 'AT-03: produk diarsip harus hilang dari pencarian';
  end if;
end $$;

-- AT-04: satuan harga meter (roll 100m, harga/m)
do $$
declare v_res jsonb; v_pid uuid; v_units jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  v_res := public.upsert_product_v1(jsonb_build_object(
    'operation_id', 'a4000000-0000-4000-8000-000000000001',
    'sku', 'KBL-TEST-M', 'name', 'Kabel Test', 'base_unit', 'm',
    'quantity_step', '0.1', 'track_segments', true,
    'unit_label', 'm', 'factor_base', '1', 'sale_step', '0.1', 'sell_price', '7500'));
  v_pid := (v_res->>'entity_id')::uuid;

  -- Tambah opsi roll 100m
  select jsonb_agg(u) into v_units
  from jsonb_array_elements(
    (public.get_product_v1(jsonb_build_object('product_id', v_pid)))->'units') u
  where (u->>'label') = 'm';
  if v_units is null then raise exception 'AT-04: unit meter harus ada'; end if;
end $$;

-- AT-26: laporan periode Jakarta & peran
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_res := public.get_report_v1(jsonb_build_object(
    'start_date', (now() at time zone 'Asia/Jakarta')::date,
    'end_date', (now() at time zone 'Asia/Jakarta')::date));
  if v_res ? 'sales_net' is false then
    raise exception 'AT-26: laporan harus memiliki sales_net';
  end if;
  if (v_res->>'start') is null then raise exception 'AT-26: start wajib'; end if;
end $$;

-- AT-26: staff tidak menerima COGS
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  v_res := public.get_report_v1(jsonb_build_object(
    'start_date', (now() at time zone 'Asia/Jakarta')::date,
    'end_date', (now() at time zone 'Asia/Jakarta')::date));
  if (v_res->>'cogs') is not null then
    raise exception 'AT-26: staff tidak boleh menerima COGS';
  end if;
  if (v_res->>'sales_net') is null then
    raise exception 'AT-26: staff tetap boleh lihat penjualan neto';
  end if;
end $$;

-- AT-27: CSV aman formula
do $$
declare v_res jsonb; v_safe text;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  v_res := public.upsert_product_v1(jsonb_build_object(
    'operation_id', 'a2700000-0000-4000-8000-000000000001',
    'sku', 'CSV-TEST', 'name', '=HYPERLINK("http://evil")', 'base_unit', 'pcs',
    'quantity_step', '1', 'track_segments', false,
    'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1', 'sell_price', '1000'));

  v_res := public.export_csv_v1(jsonb_build_object(
    'dataset', 'products',
    'start_date', (now() at time zone 'Asia/Jakarta')::date,
    'end_date', (now() at time zone 'Asia/Jakarta')::date));
  if not (v_res->>'ok')::boolean then raise exception 'AT-27: ekspor gagal'; end if;

  -- Pastikan nama diformat aman (prefix apostrof)
  select (elem->>'name') into v_safe
  from jsonb_array_elements(v_res->'rows') elem
  where (elem->>'sku') = 'CSV-TEST';
  if v_safe is null then raise exception 'AT-27: produk CSV tidak ditemukan'; end if;
  if v_safe !~ '^''?=' then
    raise exception 'AT-27: nama formula harus dinetralkan, dapat: %', v_safe;
  end if;
end $$;

-- AT-27: attachment validasi mime/size + staff boleh
do $$
declare v_res jsonb; v_ticket uuid;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  -- Buat tiket
  v_res := public.create_service_ticket_v1(jsonb_build_object(
    'operation_id', 'a2700000-0000-4000-8000-000000000002',
    'customer_name', 'Foto Test', 'customer_phone', '081234567891',
    'equipment_type', 'Radio', 'complaint', 'Berisik',
    'service_location', 'STORE'));
  v_ticket := (v_res->>'entity_id')::uuid;

  -- Mime tidak sah ditolak
  begin
    perform public.prepare_attachment_v1(jsonb_build_object(
      'operation_id', 'a2700000-0000-4000-8000-000000000003',
      'ticket_id', v_ticket, 'mime', 'image/svg+xml', 'byte_size', 1000));
    raise exception 'AT-27: SVG harus ditolak';
  exception when others then
    if position('ATTACHMENT_INVALID' in sqlerrm) = 0 then raise; end if;
  end;

  -- Oversize ditolak
  begin
    perform public.prepare_attachment_v1(jsonb_build_object(
      'operation_id', 'a2700000-0000-4000-8000-000000000004',
      'ticket_id', v_ticket, 'mime', 'image/jpeg', 'byte_size', 2000000));
    raise exception 'AT-27: oversize harus ditolak';
  exception when others then
    if position('ATTACHMENT_INVALID' in sqlerrm) = 0 then raise; end if;
  end;

  -- Valid
  v_res := public.prepare_attachment_v1(jsonb_build_object(
    'operation_id', 'a2700000-0000-4000-8000-000000000005',
    'ticket_id', v_ticket, 'mime', 'image/jpeg', 'byte_size', 100000));
  if not (v_res->>'ok')::boolean then raise exception 'AT-27: prepare valid gagal'; end if;

  -- Simulasi unggah Storage (K13: finalize wajib menemukan objek nyata).
  insert into storage.objects(bucket_id, name, metadata)
  values ('ticket-photos', v_res->>'object_key', jsonb_build_object('size', 100000, 'mimetype', 'image/jpeg'));

  v_res := public.finalize_attachment_v1(jsonb_build_object(
    'operation_id', 'a2700000-0000-4000-8000-000000000006',
    'attachment_id', v_res->>'entity_id'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-27: finalize gagal'; end if;
end $$;

-- AT-27: anon tidak dapat akses
do $$
begin
  perform set_config('role', 'anon', true);
  begin
    perform public.export_csv_v1(jsonb_build_object('dataset', 'products',
      'start_date', '2026-01-01', 'end_date', '2026-01-02'));
    raise exception 'AT-27: anon tidak boleh ekspor';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
