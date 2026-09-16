-- AT-01 / AT-02: autentikasi, peran, dan penolakan akses langsung.
-- Dijalankan terhadap PostgreSQL uji (lihat scripts/test-db.mjs).
\set ON_ERROR_STOP on

begin;

-- AT-01: owner dapat membaca profil sendiri; peran berasal dari database.
do $$
declare v_profile jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_profile := public.get_current_profile_v1();
  if v_profile->>'role' <> 'OWNER' then
    raise exception 'AT-01 gagal: peran owner tidak dibaca dari database (%).', v_profile->>'role';
  end if;
  if (v_profile->>'active')::boolean is not true then
    raise exception 'AT-01 gagal: owner aktif tidak dilaporkan aktif.';
  end if;
end $$;

-- AT-01: akun nonaktif ditolak meskipun token lama masih ada.
do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  begin
    perform public.get_current_profile_v1();
    raise exception 'AT-01 gagal: akun nonaktif masih dapat membaca profil.';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- AT-02: anon tidak boleh mengeksekusi fungsi bisnis.
do $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.get_current_profile_v1();
    raise exception 'AT-02 gagal: anon dapat memanggil get_current_profile_v1.';
  exception when sqlstate '42501' then
    null;
  end;
  begin
    perform public.search_products_v1('{}'::jsonb);
    raise exception 'AT-02 gagal: anon dapat memanggil search_products_v1.';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- AT-02: staff tidak boleh mengubah produk/harga (require_owner).
do $$
declare v_payload jsonb := jsonb_build_object(
  'operation_id', '99999999-9999-9999-9999-999999999999',
  'sku', 'SHOULD-FAIL', 'name', 'Tidak boleh', 'base_unit', 'pcs',
  'quantity_step', '1', 'track_segments', false,
  'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1', 'sell_price', '1000');
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  begin
    perform public.upsert_product_v1(v_payload);
    raise exception 'AT-02 gagal: staff dapat membuat produk.';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- AT-02: staff tidak boleh menerima barang/stok awal.
do $$
declare v_payload jsonb := jsonb_build_object(
  'operation_id', '99999998-9999-9999-9999-999999999998',
  'reason', 'coba curang',
  'items', jsonb_build_array(jsonb_build_object(
    'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
    'qty', '1', 'acquisition_cost', '1000')));
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  begin
    perform public.post_opening_stock_v1(v_payload);
    raise exception 'AT-02 gagal: staff dapat memposting stok awal.';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- AT-02: maintainer tetap tidak boleh melakukan write bisnis.
do $$
declare v_payload jsonb := jsonb_build_object(
  'operation_id', '99999997-9999-9999-9999-999999999997',
  'sku', 'M-1', 'name', 'Tidak boleh', 'base_unit', 'pcs',
  'quantity_step', '1', 'track_segments', false,
  'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1', 'sell_price', '1000');
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
  begin
    perform public.upsert_product_v1(v_payload);
    raise exception 'AT-02 gagal: maintainer dapat menulis data bisnis.';
  exception when sqlstate '42501' then
    null;
  end;
end $$;

-- AT-02: staff tidak boleh melihat harga modal lewat get_product_v1.
do $$
declare v_result jsonb; v_forbidden boolean;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  v_result := public.get_product_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000001'));
  v_forbidden := v_result::text ilike '%remaining_cost%' or v_result::text ilike '%acquisition_cost%';
  if v_forbidden then
    raise exception 'AT-02 gagal: staff menerima data modal dari get_product_v1.';
  end if;
end $$;

-- AT-02: owner boleh melihat modal.
do $$
declare v_result jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_result := public.get_product_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000001'));
  if v_result is null or not (v_result ? 'lots') then
    raise exception 'AT-02 gagal: owner tidak menerima data lot/modal yang diizinkan.';
  end if;
end $$;

rollback;
