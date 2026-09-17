-- AT-06: roll utuh dan panjang kontinu (BR-03).
-- Versi lama berkas ini mengesahkan bug (6 m + 4 m dijual sebagai satu potongan 10 m).
-- Perilaku benar: sisa 6 m dan 4 m TIDAK memenuhi satu potongan 10 m; dua potongan harus
-- dicatat sebagai dua baris eksplisit; retur potongan membuat posisi baru.
\set ON_ERROR_STOP on

begin;

do $$
declare v_res jsonb; v_inv uuid; v_item uuid; v_a uuid; v_b uuid; v_msg text;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

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
  select id into v_a from private.stock_positions where label = 'AT06-A';
  select id into v_b from private.stock_positions where label = 'AT06-B';

  -- Satu potongan 10 m dari potongan 6 m: ditolak.
  begin
    perform public.finalize_sale_v1(jsonb_build_object(
      'operation_id', 'f0060000-0000-4000-8000-000000000002',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '10', 'position_id', v_a)),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
  exception when others then v_msg := sqlerrm;
  end;
  if coalesce(position('SEGMENT_TOO_SHORT' in v_msg), 0) <> 1 then
    raise exception 'AT-06: 10 m dari potongan 6 m harus SEGMENT_TOO_SHORT, dapat %', v_msg;
  end if;

  -- Total 100 m dari potongan tidak boleh dijual sebagai roll 100m bersegel.
  v_msg := null;
  begin
    perform public.finalize_sale_v1(jsonb_build_object(
      'operation_id', 'f0060000-0000-4000-8000-000000000003',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '1', 'position_id', v_a)),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
  exception when others then v_msg := sqlerrm;
  end;
  if coalesce(position('SEGMENT_NOT_SEALED' in v_msg), 0) <> 1 then
    raise exception 'AT-06: roll utuh dari potongan harus SEGMENT_NOT_SEALED, dapat %', v_msg;
  end if;

  -- Pelanggan menerima dua potongan: dua baris eksplisit.
  v_res := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'f0060000-0000-4000-8000-000000000004',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '6', 'position_id', v_a),
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '4', 'position_id', v_b)),
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
  if (v_res->>'total') <> '75000' then raise exception 'AT-06: total dua potongan salah: %', v_res->>'total'; end if;
  if (select sum(qty_base) from private.stock_positions where id in (v_a, v_b)) <> 0 then
    raise exception 'AT-06: kedua potongan harus habis';
  end if;

  -- Retur 4 m menjadi posisi baru, tidak disambung ke AT06-B.
  v_inv := (v_res->>'entity_id')::uuid;
  select id into v_item from private.invoice_items where invoice_id = v_inv and line_no = 2;
  v_res := public.return_sale_v1(jsonb_build_object(
    'operation_id', 'f0060000-0000-4000-8000-000000000005',
    'invoice_id', v_inv, 'reason', 'Uji retur AT-06', 'refund_method', 'TRANSFER',
    'items', jsonb_build_array(jsonb_build_object(
      'invoice_item_id', v_item, 'qty_base', '4', 'disposition', 'SALEABLE'))));
  if (v_res->>'refund_total') <> '30000' then raise exception 'AT-06: refund 4 m salah: %', v_res->>'refund_total'; end if;
  if (select qty_base from private.stock_positions where id = v_b) <> 0 then
    raise exception 'AT-06: posisi asal tidak boleh disambung';
  end if;
  if (select count(*) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = 'a2000000-0000-4000-8000-000000000002' and s.qty_base = 4
        and s.id not in (v_a, v_b) and s.label is not null) <> 1 then
    raise exception 'AT-06: retur harus membuat satu posisi baru 4 m berlabel';
  end if;
end $$;

rollback;
