-- AT-06: roll utuh dan panjang kontinu
\set ON_ERROR_STOP on

begin;

-- AT-06: 6m + 4m dijual sebagai 10m, retur buat posisi baru
do $$
declare v_res jsonb; v_inv_id uuid; v_item_id uuid;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  -- Setup: stok kabel 2 potongan (6m + 4m)
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'f0060000-0000-4000-8000-000000000001',
    'reason', 'Stok uji AT-06',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000002',
      'qty', '10', 'acquisition_cost', '85000',
      'positions', jsonb_build_array(
        jsonb_build_object('qty_base', '6', 'segment_capacity', '10', 'sealed', false, 'label', 'AT06-A'),
        jsonb_build_object('qty_base', '4', 'segment_capacity', '10', 'sealed', false, 'label', 'AT06-B')
      )))));

  -- AT-06: jual 10m dari 6m + 4m (2 potongan = 10m)
  v_res := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'f0060000-0000-4000-8000-000000000002',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '10')),
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
  if not (v_res->>'ok')::boolean then raise exception 'AT-06: jual 10m gagal'; end if;

  -- AT-06: sisa stok harus 0
  if (select coalesce(sum(s.qty_base), 0) from private.stock_positions s
      where label in ('AT06-A', 'AT06-B')) <> 0 then
    raise exception 'AT-06: sisa harus 0';
  end if;

  -- AT-06: retur 4m
  select id into v_inv_id from private.invoices
  where operation_id = 'f0060000-0000-4000-8000-000000000002' order by posted_at desc limit 1;
  select id into v_item_id from private.invoice_items where invoice_id = v_inv_id limit 1;

  v_res := public.return_sale_v1(jsonb_build_object(
    'operation_id', 'f0060000-0000-4000-8000-000000000003',
    'invoice_id', v_inv_id, 'reason', 'Uji retur AT-06',
    'refund_method', 'TRANSFER',
    'items', jsonb_build_array(jsonb_build_object(
      'invoice_item_id', v_item_id, 'qty_base', '4', 'disposition', 'SALEABLE'))));
  if not (v_res->>'ok')::boolean then raise exception 'AT-06: retur gagal'; end if;

  -- AT-06: posisi retur baru terbentuk
  if (select count(*) from private.stock_positions s
      join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = 'a2000000-0000-4000-8000-000000000002'
      and s.qty_base > 0) < 1 then
    raise exception 'AT-06: harus ada posisi baru dari retur';
  end if;
end $$;

-- Verifikasi: posisi punya qty > 0 dari retur
do $$
begin
  if (select count(*) from private.stock_positions s
      join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = 'a2000000-0000-4000-8000-000000000002'
      and s.qty_base = 4) <> 1 then
    raise exception 'AT-06: posisi retur harus 4m';
  end if;
end $$;

rollback;
