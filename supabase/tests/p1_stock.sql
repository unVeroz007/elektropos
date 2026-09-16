-- AT-15 / AT-16: stok awal, idempotensi, transfer, kerusakan, opname.
\set ON_ERROR_STOP on

begin;

-- Atur sesi owner untuk seluruh skenario.
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

-- AT-15: stok awal menambah qty/modal tanpa purchase payment.
do $$
declare v_result jsonb; v_qty_after numeric;
begin
  v_result := public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'c0000000-0000-4000-8000-000000000001',
    'reason', 'Stok awal pembukaan',
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
        'qty', '10', 'acquisition_cost', '100000', 'note', 'Lampu 10 pcs'),
      jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000002',
        'qty', '150', 'acquisition_cost', '450000', 'note', 'Kabel 150 m',
        'positions', jsonb_build_array(
          jsonb_build_object('qty_base', '100', 'segment_capacity', '100', 'sealed', true, 'label', 'R001'),
          jsonb_build_object('qty_base', '50', 'segment_capacity', '100', 'sealed', false, 'label', 'R002'))))));
  if not (v_result->>'ok')::boolean then
    raise exception 'AT-15 gagal: stok awal tidak diposting.';
  end if;
end $$;

-- Kembali ke root untuk assertion baca data
select set_config('role', 'postgres', true);

do $$
declare v_qty_after numeric;
begin
  select sum(s.qty_base) into v_qty_after
  from private.stock_positions s
  join private.inventory_lots l on l.id = s.lot_id
  where l.product_id = 'a2000000-0000-4000-8000-000000000001';
  if v_qty_after <> 10 then
    raise exception 'AT-15 gagal: qty lampu seharusnya 10, dapat %.', v_qty_after;
  end if;

  if exists (select 1 from private.purchase_payments) then
    raise exception 'AT-15 gagal: OPENING tidak boleh membuat purchase payment.';
  end if;
end $$;

select set_config('role', 'authenticated', true);

-- AT-15: posting ulang dengan key sama menambah stok sekali.
do $$
begin
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'c0000000-0000-4000-8000-000000000001',
    'reason', 'Stok awal pembukaan',
    'items', jsonb_build_array(
      jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
        'qty', '10', 'acquisition_cost', '100000', 'note', 'Lampu 10 pcs'),
      jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000002',
        'qty', '150', 'acquisition_cost', '450000', 'note', 'Kabel 150 m',
        'positions', jsonb_build_array(
          jsonb_build_object('qty_base', '100', 'segment_capacity', '100', 'sealed', true, 'label', 'R001'),
          jsonb_build_object('qty_base', '50', 'segment_capacity', '100', 'sealed', false, 'label', 'R002'))))));
end $$;

select set_config('role', 'postgres', true);

do $$
declare v_qty_after numeric;
begin
  select sum(s.qty_base) into v_qty_after
  from private.stock_positions s
  join private.inventory_lots l on l.id = s.lot_id
  where l.product_id = 'a2000000-0000-4000-8000-000000000001';
  if v_qty_after <> 10 then
    raise exception 'AT-15 gagal: idempotensi gagal, qty menjadi %.', v_qty_after;
  end if;
end $$;

select set_config('role', 'authenticated', true);

-- AT-15: key sama dengan payload berbeda ditolak (IDEMPOTENCY_CONFLICT).
do $$
begin
  begin
    perform public.post_opening_stock_v1(jsonb_build_object(
      'operation_id', 'c0000000-0000-4000-8000-000000000001',
      'reason', 'Payload berbeda',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
        'qty', '5', 'acquisition_cost', '50000'))));
    raise exception 'AT-15 gagal: key sama + payload berbeda seharusnya ditolak.';
  exception when others then
    if position('IDEMPOTENCY_CONFLICT' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

select set_config('role', 'postgres', true);

-- AT-16: transfer 20 m dari roll 50 m ke FIELD_FATHER.
do $$
declare v_source uuid; v_shop numeric; v_field numeric;
begin
  select id into v_source from private.stock_positions where label = 'R002';
  
  -- temporarily change role inside DO block
  perform set_config('role', 'authenticated', true);
  
  perform public.transfer_stock_v1(jsonb_build_object(
    'operation_id', 'c0000000-0000-4000-8000-000000000002',
    'position_id', v_source,
    'expected_version', 1,
    'qty_base', '20',
    'destination_location', 'FIELD_FATHER',
    'destination_label', 'R002-FIELD',
    'reason', 'Dibawa ayah untuk kunjungan'));
    
  perform set_config('role', 'postgres', true);
  
  select coalesce(sum(qty_base), 0) into v_shop from private.stock_positions
    where location = 'SHOP' and label = 'R002';
  select coalesce(sum(qty_base), 0) into v_field from private.stock_positions
    where location = 'FIELD_FATHER' and label = 'R002-FIELD';
  if v_shop <> 30 then raise exception 'AT-16 gagal: SHOP seharusnya 30, dapat %.', v_shop; end if;
  if v_field <> 20 then raise exception 'AT-16 gagal: FIELD_FATHER seharusnya 20, dapat %.', v_field; end if;
end $$;

-- AT-16: kepemilikan total tetap setelah transfer (lot tidak berubah).
do $$
declare v_lot numeric; v_pos numeric;
begin
  select sum(l.remaining_qty) into v_lot
    from private.inventory_lots l
    where l.product_id = 'a2000000-0000-4000-8000-000000000002';
  select sum(p.qty_base) into v_pos
    from private.stock_positions p
    join private.inventory_lots l on l.id = p.lot_id
    where l.product_id = 'a2000000-0000-4000-8000-000000000002';
  if v_lot <> v_pos then
    raise exception 'AT-16 gagal: total lot % tidak sama dengan total posisi %.', v_lot, v_pos;
  end if;
  if v_lot <> 150 then
    raise exception 'AT-16 gagal: total kabel seharusnya 150, dapat %.', v_lot;
  end if;
end $$;

-- AT-16: version lama ditolak (VERSION_CONFLICT).
do $$
declare v_source uuid;
begin
  select id into v_source from private.stock_positions where label = 'R002';
  
  perform set_config('role', 'authenticated', true);
  begin
    perform public.transfer_stock_v1(jsonb_build_object(
      'operation_id', 'c0000000-0000-4000-8000-000000000003',
      'position_id', v_source, 'expected_version', 1, 'qty_base', '5',
      'destination_location', 'FIELD_FATHER', 'destination_label', 'R002-X',
      'reason', 'versi lama'));
    raise exception 'AT-16 gagal: expected_version lama seharusnya ditolak.';
  exception when others then
    if position('VERSION_CONFLICT' in sqlerrm) = 0 then raise; end if;
  end;
  perform set_config('role', 'postgres', true);
end $$;

-- AT-16: disposal mengurangi stok dan mencatat kerugian tanpa membuat penjualan.
do $$
declare v_dest uuid; v_result jsonb; v_qty numeric;
begin
  select id into v_dest from private.stock_positions where label = 'R002-FIELD';
  
  perform set_config('role', 'authenticated', true);
  v_result := public.dispose_stock_v1(jsonb_build_object(
    'operation_id', 'c0000000-0000-4000-8000-000000000004',
    'position_id', v_dest, 'expected_version', 1, 'qty_base', '2',
    'reason', 'Rusak saat dipasang'));
  perform set_config('role', 'postgres', true);
    
  if not (v_result->>'ok')::boolean then raise exception 'AT-16 gagal: disposal tidak berhasil.'; end if;
  if (v_result->>'cost_removed')::numeric <= 0 then
    raise exception 'AT-16 gagal: disposal harus menghapus modal.';
  end if;
  
  select qty_base into v_qty from private.stock_positions where id = v_dest;
  if v_qty <> 18 then raise exception 'AT-16 gagal: sisa FIELD seharusnya 18, dapat %.', v_qty; end if;
  if exists (select 1 from private.stock_documents where kind = 'DISPOSAL' and id = (v_result->>'entity_id')::uuid) = false then
    raise exception 'AT-16 gagal: dokumen DISPOSAL tidak tercatat.';
  end if;
end $$;

-- AT-16: stok negatif tidak mungkin (qty melebihi posisi ditolak).
do $$
declare v_dest uuid;
begin
  select id into v_dest from private.stock_positions where label = 'R002-FIELD';
  
  perform set_config('role', 'authenticated', true);
  begin
    perform public.dispose_stock_v1(jsonb_build_object(
      'operation_id', 'c0000000-0000-4000-8000-000000000005',
      'position_id', v_dest, 'expected_version', 2, 'qty_base', '999',
      'reason', 'melebihi stok'));
    raise exception 'AT-16 gagal: disposal melebihi stok seharusnya ditolak.';
  exception when others then
    if position('INSUFFICIENT_STOCK' in sqlerrm) = 0 then raise; end if;
  end;
  perform set_config('role', 'postgres', true);
end $$;

-- Invariant ledger: sum movement per posisi = qty posisi.
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
  from private.stock_positions p
  where p.qty_base <> (
    select coalesce(sum(m.qty_delta), 0) from private.stock_movements m where m.position_id = p.id);
  if v_bad > 0 then
    raise exception 'Invariant ledger gagal: % posisi tidak cocok dengan movement.', v_bad;
  end if;
end $$;

-- Invariant modal: sum movement cost per lot = remaining_cost.
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
  from private.inventory_lots l
  where l.remaining_cost <> (
    select coalesce(sum(m.cost_delta), 0) from private.stock_movements m where m.lot_id = l.id);
  if v_bad > 0 then
    raise exception 'Invariant modal gagal: % lot tidak cocok dengan cost_delta.', v_bad;
  end if;
end $$;

rollback;

