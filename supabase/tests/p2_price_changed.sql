-- AT-08: harga berubah sejak keranjang dibuat -> PRICE_CHANGED
\set ON_ERROR_STOP on

begin;

-- Siapkan stok untuk uji
do $$
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'a0800000-0000-4000-8000-000000000000',
    'reason', 'Stok uji harga berubah',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
      'qty', '10', 'acquisition_cost', '100000'))));
end $$;

-- AT-08: kirim expected_unit_version lama -> ditolak
do $$
declare v_unit uuid; v_ver integer; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  select u.id, u.version into v_unit, v_ver
  from private.product_units u join private.products p on p.id = u.product_id
  where p.sku = 'LMP-LED-10W' and u.is_default limit 1;

  -- Ubah harga (bump version) sebagai owner
  perform public.upsert_product_v1(jsonb_build_object(
    'operation_id', 'a0800000-0000-4000-8000-000000000001',
    'product_id', (select product_id from private.product_units where id = v_unit),
    'expected_version', (select version from private.products where id = (select product_id from private.product_units where id = v_unit)),
    'sku', 'LMP-LED-10W', 'name', 'Lampu LED 10 Watt',
    'base_unit', 'pcs', 'quantity_step', '1', 'track_segments', false,
    'unit_label', 'pcs', 'factor_base', '1', 'sale_step', '1', 'sell_price', '16000'));

  -- Keranjang lama: kirim versi sebelum perubahan
  begin
    perform public.finalize_sale_v1(jsonb_build_object(
      'operation_id', 'a0800000-0000-4000-8000-000000000002',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', v_unit, 'qty', '1', 'expected_unit_version', v_ver)),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
    raise exception 'AT-08: PRICE_CHANGED seharusnya ditolak';
  exception when others then
    if position('PRICE_CHANGED' in sqlerrm) = 0 then raise; end if;
  end;

  -- Keranjang lama memakai unit lama (sudah nonaktif) → PRICE_CHANGED
  begin
    perform public.finalize_sale_v1(jsonb_build_object(
      'operation_id', 'a0800000-0000-4000-8000-000000000002',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', v_unit, 'qty', '1', 'expected_unit_version', v_ver)),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
    raise exception 'AT-08: PRICE_CHANGED seharusnya ditolak';
  exception when others then
    if position('PRICE_CHANGED' in sqlerrm) = 0 then raise; end if;
  end;

  -- Versi terbaru diterima
  select u.id, u.version into v_unit, v_ver
  from private.product_units u join private.products p on p.id = u.product_id
  where p.sku = 'LMP-LED-10W' and u.is_default and u.active limit 1;
  v_res := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'a0800000-0000-4000-8000-000000000003',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', v_unit, 'qty', '1', 'expected_unit_version', v_ver)),
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
  if not (v_res->>'ok')::boolean then raise exception 'AT-08: versi terbaru harus diterima'; end if;
end $$;

rollback;
