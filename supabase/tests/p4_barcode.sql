-- AT-03 lanjutan: daftarkan barcode fisik ke produk yang sudah ada
\set ON_ERROR_STOP on

begin;

-- AT-03: owner dapat mendaftarkan barcode fisik nyata
do $$
declare v_pid uuid; v_uid uuid; v_res jsonb; v_found jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  select id into v_pid from private.products where sku = 'LMP-LED-10W';
  select id into v_uid from private.product_units where product_id = v_pid and is_default;

  -- Barcode fisik yang baru (belum terdaftar)
  v_res := public.add_product_barcode_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000101',
    'product_id', v_pid, 'product_unit_id', v_uid, 'code', '1234567890128'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-03: gagal daftar barcode'; end if;

  -- Scan barcode fisik harus menemukan produk
  v_found := public.search_products_v1(jsonb_build_object('query', '1234567890128'));
  if jsonb_array_length(v_found) <> 1 then
    raise exception 'AT-03: scan barcode fisik harus menemukan tepat 1 produk, dapat %',
      jsonb_array_length(v_found);
  end if;
  if (v_found->0->>'sku') <> 'LMP-LED-10W' then
    raise exception 'AT-03: produk tidak cocok';
  end if;
end $$;

-- AT-03: barcode duplikat pada produk berbeda ditolak
do $$
declare v_other uuid; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select id into v_other from private.products where sku = 'KBL-NYA-1.5';

  begin
    perform public.add_product_barcode_v1(jsonb_build_object(
      'operation_id', 'a3000000-0000-4000-8000-000000000102',
      'product_id', v_other, 'code', '1234567890128'));
    raise exception 'AT-03: barcode duplikat harus ditolak';
  exception when unique_violation then null;
  end;
end $$;

-- AT-03: staff tidak boleh mendaftarkan barcode
do $$
declare v_pid uuid;
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  select id into v_pid from private.products limit 1;
  begin
    perform public.add_product_barcode_v1(jsonb_build_object(
      'operation_id', 'a3000000-0000-4000-8000-000000000103',
      'product_id', v_pid, 'code', '9999999999999'));
    raise exception 'AT-03: staff harus ditolak';
  exception when insufficient_privilege then null;
  end;
end $$;

-- AT-03: unit milik produk lain ditolak
do $$
declare v_pid uuid; v_other_unit uuid;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select id into v_pid from private.products where sku = 'LMP-LED-10W';
  select u.id into v_other_unit from private.product_units u
    join private.products p on p.id = u.product_id
    where p.sku = 'KBL-NYA-1.5' limit 1;

  begin
    perform public.add_product_barcode_v1(jsonb_build_object(
      'operation_id', 'a3000000-0000-4000-8000-000000000104',
      'product_id', v_pid, 'product_unit_id', v_other_unit, 'code', '8888888888888'));
    raise exception 'AT-03: unit produk lain harus ditolak';
  exception when others then
    if position('bukan milik produk' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

-- AT-03: barcode presisi — temukan satuan tepat + kelola
do $$
declare v_pid uuid; v_uid uuid; v_res jsonb; v_found jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  select id into v_pid from private.products where sku = 'KBL-NYA-1.5';
  -- Unit roll 100m (bukan default)
  select id into v_uid from private.product_units where product_id = v_pid and label = 'roll 100m';

  -- Daftarkan barcode yang dipetakan ke satuan roll
  v_res := public.add_product_barcode_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000201',
    'product_id', v_pid, 'product_unit_id', v_uid, 'code', '5550001112223'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-03: gagal daftar barcode roll'; end if;

  -- find_by_barcode harus mengembalikan satuan roll, bukan default 'm'
  v_found := public.find_by_barcode_v1(jsonb_build_object('code', '5550001112223'));
  if (v_found->>'found')::boolean is not true then
    raise exception 'AT-03: find_by_barcode harus menemukan produk';
  end if;
  if (v_found->>'unit_label') <> 'roll 100m' then
    raise exception 'AT-03: satuan harus roll 100m, dapat %', v_found->>'unit_label';
  end if;
  if (v_found->'unit_version') is null then
    raise exception 'AT-03: unit_version wajib untuk cek harga berubah';
  end if;
end $$;

-- AT-03: daftar & hapus barcode
do $$
declare v_pid uuid; v_list jsonb; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select id into v_pid from private.products where sku = 'KBL-NYA-1.5';

  v_list := public.list_product_barcodes_v1(jsonb_build_object('product_id', v_pid));
  if jsonb_array_length(v_list) < 2 then
    raise exception 'AT-03: produk harus punya >=2 barcode, dapat %', jsonb_array_length(v_list);
  end if;

  v_res := public.remove_product_barcode_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000202',
    'code', '5550001112223'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-03: hapus barcode gagal'; end if;

  v_list := public.list_product_barcodes_v1(jsonb_build_object('product_id', v_pid));
  if jsonb_array_length(v_list) <> 1 then
    raise exception 'AT-03: setelah hapus harus 1 barcode, dapat %', jsonb_array_length(v_list);
  end if;
end $$;

-- AT-03: daftar barcode yang sama pada produk sama bersifat idempoten (tidak error)
do $$
declare v_pid uuid; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select id into v_pid from private.products where sku = 'LMP-LED-10W';
  v_res := public.add_product_barcode_v1(jsonb_build_object(
    'operation_id', 'a3000000-0000-4000-8000-000000000203',
    'product_id', v_pid, 'code', '8991234567890'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-03: barcode sama produk sama harus ok'; end if;
  if (v_res->>'already')::boolean is not true then
    raise exception 'AT-03: harus menandai already=true';
  end if;
end $$;

-- AT-03: barcode belum terdaftar -> found=false
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_res := public.find_by_barcode_v1(jsonb_build_object('code', '0000000000000'));
  if (v_res->>'found')::boolean is not false then
    raise exception 'AT-03: barcode asing harus found=false';
  end if;
end $$;

rollback;

