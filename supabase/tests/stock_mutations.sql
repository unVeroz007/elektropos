-- T05/BR-06: transfer, penyesuaian (IN/OUT), disposal. Peran, validasi angka,
-- versi, label roll, modal lot, idempotensi (command = nama RPC), invariant ledger.
\set ON_ERROR_STOP on

begin;

create function pg_temp.act(p_sub text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_sub, true)
$$;
create function pg_temp.expect_error(p_sql text, p_code text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) = 0 then
      raise exception 'Diharapkan error % tetapi dapat: %', p_code, sqlerrm;
    end if;
    return;
  end;
  raise exception 'Diharapkan error % tetapi perintah berhasil: %', p_code, left(p_sql, 160);
end $$;
create function pg_temp.pos(p_label text) returns private.stock_positions language sql as $$
  select * from private.stock_positions where label = p_label
$$;
create function pg_temp.lamp_pos() returns private.stock_positions language sql as $$
  select s.* from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
  join private.stock_documents d on d.id = (select document_id from private.stock_document_items where id = l.origin_item_id)
  where l.product_id = 'a2000000-0000-4000-8000-000000000001' and d.kind = 'OPENING'
$$;

-- Stok awal: lampu 10 pcs modal 100.000; kabel roll R001 100 m (segel) + R002 50 m, modal 450.000.
select pg_temp.act('11111111-1111-4111-8111-111111111111');
select public.post_opening_stock_v1(jsonb_build_object(
  'operation_id', 'd1000000-0000-4000-8000-000000000001', 'reason', 'Stok awal',
  'items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '10', 'acquisition_cost', '100000'),
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '150', 'acquisition_cost', '450000',
      'positions', jsonb_build_array(
        jsonb_build_object('qty_base', '100', 'segment_capacity', '100', 'sealed', true, 'label', 'R001'),
        jsonb_build_object('qty_base', '50', 'segment_capacity', '100', 'sealed', false, 'label', 'R002'))))));

-- Peran: mutasi stok hanya OWNER; akun nonaktif ditolak.
do $$
declare v_pos uuid := (pg_temp.lamp_pos()).id; v_sub text; v_code text;
begin
  foreach v_sub in array array['22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333',
                               '44444444-4444-4444-8444-444444444444'] loop
    perform pg_temp.act(v_sub);
    v_code := case when v_sub like '4444%' then 'ACCOUNT_INACTIVE' else 'FORBIDDEN' end;
    perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
      'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos, 'expected_version', 1,
      'qty_base', '1', 'reason', 'x')), v_code);
    perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', jsonb_build_object(
      'operation_id', gen_random_uuid(), 'position_id', v_pos, 'expected_version', 1, 'qty_base', '1',
      'destination_location', 'FIELD_FATHER', 'reason', 'x')), v_code);
    perform pg_temp.expect_error(format('select public.dispose_stock_v1(%L)', jsonb_build_object(
      'operation_id', gen_random_uuid(), 'position_id', v_pos, 'expected_version', 1, 'qty_base', '1', 'reason', 'x')), v_code);
    perform pg_temp.expect_error(format('select public.create_stock_count_v1(%L)', jsonb_build_object(
      'operation_id', gen_random_uuid(), 'position_ids', jsonb_build_array(v_pos))), v_code);
  end loop;
end $$;

-- anon tidak punya EXECUTE.
do $$
begin
  perform set_config('role', 'anon', true);
  perform pg_temp.expect_error('select public.adjust_stock_v1(''{}'')', 'permission denied');
  perform pg_temp.expect_error('select public.list_stock_positions_v1(''{}'')', 'permission denied');
  perform set_config('role', 'postgres', true);
end $$;

-- Penyesuaian OUT: qty positif + direction; modal keluar proporsional lot.
do $$
declare v_pos private.stock_positions; v_res jsonb; v_lot private.inventory_lots; v_op jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_pos := pg_temp.lamp_pos();
  -- Bug lama: '-2' ditolak format dan cabang negatif mati. Sekarang negatif tetap ditolak sebagai angka,
  -- arah dinyatakan lewat direction.
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '-2', 'reason', 'hilang')), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '2', 'reason', 'hilang')), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '2')), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '1.5', 'reason', 'pecahan')), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '11', 'reason', 'melebihi')), 'INSUFFICIENT_STOCK');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version + 5,
    'qty_base', '1', 'reason', 'versi')), 'VERSION_CONFLICT');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'direction', 'OUT', 'position_id', v_pos.id, 'expected_version', v_pos.version,
    'qty_base', '1', 'reason', 'x', 'cost', '1')), 'INVALID_INPUT');

  v_res := public.adjust_stock_v1(jsonb_build_object(
    'operation_id', 'd1000000-0000-4000-8000-000000000010', 'direction', 'OUT', 'position_id', v_pos.id,
    'expected_version', v_pos.version, 'qty_base', '2', 'reason', 'Pecah di rak'));
  if v_res->>'cost_delta' <> '-20000.000000' or v_res->>'position_qty_base' <> '8.000' then
    raise exception 'adjust OUT: hasil salah %', v_res;
  end if;
  select l.* into v_lot from private.inventory_lots l where l.id = v_pos.lot_id;
  if v_lot.remaining_qty <> 8 or v_lot.remaining_cost <> 80000 then
    raise exception 'adjust OUT: lot seharusnya 8/80000, dapat %/%', v_lot.remaining_qty, v_lot.remaining_cost;
  end if;
  -- Idempotensi: payload sama -> hasil sama, stok tidak berkurang dua kali.
  if public.adjust_stock_v1(jsonb_build_object(
    'operation_id', 'd1000000-0000-4000-8000-000000000010', 'direction', 'OUT', 'position_id', v_pos.id,
    'expected_version', v_pos.version, 'qty_base', '2', 'reason', 'Pecah di rak')) <> v_res then
    raise exception 'adjust OUT: ulangan idempoten berbeda';
  end if;
  if (pg_temp.lamp_pos()).qty_base <> 8 then raise exception 'adjust OUT: ulangan mengurangi stok lagi'; end if;
  v_op := public.get_operation_v1(jsonb_build_object('command', 'adjust_stock_v1', 'operation_id', 'd1000000-0000-4000-8000-000000000010'));
  if not (v_op->>'found')::boolean or v_op->'result' <> v_res then
    raise exception 'get_operation_v1 adjust_stock_v1 tidak ditemukan: %', v_op;
  end if;
end $$;

-- Penyesuaian IN: wajib modal terkonfirmasi atau alasan modal nol; lot koreksi baru.
do $$
declare v_res jsonb; v_lot private.inventory_lots; v_doc private.stock_documents; v_base jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_base := jsonb_build_object('direction', 'IN', 'product_id', 'a2000000-0000-4000-8000-000000000001',
    'location', 'SHOP', 'condition', 'SALEABLE', 'qty_base', '3', 'reason', 'Ditemukan di gudang');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid())), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', v_base || jsonb_build_object(
    'operation_id', gen_random_uuid(), 'acquisition_cost', '36000')), 'cost_confirmed');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', v_base || jsonb_build_object(
    'operation_id', gen_random_uuid(), 'acquisition_cost', '36000', 'cost_confirmed', true, 'zero_cost_reason', 'x')), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', v_base || jsonb_build_object(
    'operation_id', gen_random_uuid(), 'acquisition_cost', '36000.5', 'cost_confirmed', true)), 'INVALID_NUMBER');

  v_res := public.adjust_stock_v1(v_base || jsonb_build_object('operation_id', 'd1000000-0000-4000-8000-000000000011',
    'acquisition_cost', '36000', 'cost_confirmed', true));
  select l.* into v_lot from private.inventory_lots l join private.stock_positions s on s.lot_id = l.id
    where s.id = (v_res->>'position_id')::uuid;
  select d.* into v_doc from private.stock_documents d where d.id = (v_res->>'entity_id')::uuid;
  if v_lot.original_qty <> 3 or v_lot.original_cost <> 36000 or v_lot.remaining_cost <> 36000 or v_doc.kind <> 'ADJUSTMENT' then
    raise exception 'adjust IN: lot koreksi salah (% / % / %)', v_lot.original_qty, v_lot.original_cost, v_doc.kind;
  end if;
  if exists (select 1 from private.purchase_payments where stock_document_id = v_doc.id) then
    raise exception 'adjust IN: koreksi tidak boleh menyamar sebagai pembelian';
  end if;

  v_res := public.adjust_stock_v1(v_base || jsonb_build_object('operation_id', 'd1000000-0000-4000-8000-000000000012',
    'qty_base', '1', 'zero_cost_reason', 'Bonus distributor'));
  if v_res->>'cost_delta' <> '0.000000' then raise exception 'adjust IN modal nol salah: %', v_res; end if;

  -- Roll: wajib label baru yang unik.
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'direction', 'IN', 'product_id', 'a2000000-0000-4000-8000-000000000002', 'qty_base', '5', 'reason', 'sisa potongan',
    'zero_cost_reason', 'sisa')), 'label');
  perform pg_temp.expect_error(format('select public.adjust_stock_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'direction', 'IN', 'product_id', 'a2000000-0000-4000-8000-000000000002', 'qty_base', '5', 'reason', 'sisa potongan',
    'zero_cost_reason', 'sisa', 'label', 'R001')), 'Label posisi sudah dipakai');
  v_res := public.adjust_stock_v1(jsonb_build_object('operation_id', 'd1000000-0000-4000-8000-000000000013',
    'direction', 'IN', 'product_id', 'a2000000-0000-4000-8000-000000000002', 'qty_base', '5.5', 'reason', 'sisa potongan',
    'acquisition_cost', '16500', 'cost_confirmed', true, 'label', 'K-ADJ'));
  if (pg_temp.pos('K-ADJ')).qty_base <> 5.5 or (pg_temp.pos('K-ADJ')).segment_capacity <> 5.5 then
    raise exception 'adjust IN roll: posisi salah';
  end if;
end $$;

-- Transfer: alasan wajib, langkah qty, label roll, versi; biaya lot tetap.
do $$
declare v_src private.stock_positions := pg_temp.pos('R001'); v_res jsonb; v_base jsonb; v_cost numeric;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_base := jsonb_build_object('position_id', v_src.id, 'expected_version', v_src.version,
    'destination_location', 'FIELD_FATHER', 'qty_base', '30', 'reason', 'Dibawa ke lokasi', 'destination_label', 'R001-F');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', (v_base - 'reason') || jsonb_build_object('operation_id', gen_random_uuid())), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'qty_base', '0.05')), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'qty_base', 30)), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', (v_base - 'destination_label') || jsonb_build_object('operation_id', gen_random_uuid())), 'label');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'destination_label', 'R002')), 'Label posisi sudah dipakai');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'qty_base', '100.1')), 'INSUFFICIENT_STOCK');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'destination_location', 'SHOP')), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.transfer_stock_v1(%L)', v_base || jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', 99)), 'VERSION_CONFLICT');

  select remaining_cost into v_cost from private.inventory_lots where id = v_src.lot_id;
  v_res := public.transfer_stock_v1(v_base || jsonb_build_object('operation_id', 'd1000000-0000-4000-8000-000000000020'));
  if (pg_temp.pos('R001')).qty_base <> 70 or (pg_temp.pos('R001')).sealed or (pg_temp.pos('R001')).version <> v_src.version + 1 then
    raise exception 'transfer: posisi asal salah';
  end if;
  if (pg_temp.pos('R001-F')).qty_base <> 30 or (pg_temp.pos('R001-F')).location <> 'FIELD_FATHER'
     or (pg_temp.pos('R001-F')).segment_capacity <> 30 or (pg_temp.pos('R001-F')).sealed then
    raise exception 'transfer: posisi tujuan salah';
  end if;
  if (select remaining_cost from private.inventory_lots where id = v_src.lot_id) <> v_cost then
    raise exception 'transfer: biaya lot berubah';
  end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'transfer_stock_v1',
      'operation_id', 'd1000000-0000-4000-8000-000000000020'))->>'found')::boolean then
    raise exception 'get_operation_v1 transfer_stock_v1 tidak ditemukan';
  end if;
end $$;

-- Disposal: command = dispose_stock_v1 (bug lama 'post_disposal_v1'); modal keluar eksak.
do $$
declare v_pos private.stock_positions := pg_temp.pos('R001-F'); v_res jsonb; v_lot private.inventory_lots;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform pg_temp.expect_error(format('select public.dispose_stock_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'position_id', v_pos.id, 'expected_version', v_pos.version, 'qty_base', '2')), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.dispose_stock_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'position_id', v_pos.id, 'expected_version', v_pos.version, 'qty_base', '30.1', 'reason', 'x')), 'INSUFFICIENT_STOCK');
  v_res := public.dispose_stock_v1(jsonb_build_object('operation_id', 'd1000000-0000-4000-8000-000000000030',
    'position_id', v_pos.id, 'expected_version', v_pos.version, 'qty_base', '2', 'reason', 'Rusak terjepit'));
  if v_res->>'cost_removed' <> '6000.000000' then
    raise exception 'disposal: modal keluar seharusnya 6000, dapat %', v_res->>'cost_removed';
  end if;
  select * into v_lot from private.inventory_lots where id = v_pos.lot_id;
  if v_lot.remaining_qty <> 148 or v_lot.remaining_cost <> 444000 then
    raise exception 'disposal: lot seharusnya 148/444000, dapat %/%', v_lot.remaining_qty, v_lot.remaining_cost;
  end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'dispose_stock_v1',
      'operation_id', 'd1000000-0000-4000-8000-000000000030'))->>'found')::boolean then
    raise exception 'get_operation_v1 dispose_stock_v1 tidak ditemukan (bug nama command)';
  end if;
  if exists (select 1 from private.operations where command = 'post_disposal_v1') then
    raise exception 'disposal masih memakai command lama';
  end if;
end $$;

-- Baca posisi & riwayat: STAFF tanpa modal, OWNER dengan modal.
do $$
declare v_res jsonb; v_row jsonb;
begin
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  v_res := public.list_stock_positions_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002'));
  if jsonb_array_length(v_res->'rows') <> 4 or v_res::text like '%cost%' then
    raise exception 'list_stock_positions_v1 staff salah: %', v_res;
  end if;
  v_res := public.list_stock_movements_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002', 'limit', 2));
  if jsonb_array_length(v_res->'rows') <> 2 or not (v_res->>'has_more')::boolean or v_res::text like '%cost%' then
    raise exception 'list_stock_movements_v1 staff salah: %', v_res;
  end if;
  -- Dalam satu transaksi uji now() sama; ambil disposal dengan filter jenis.
  v_row := public.list_stock_movements_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002',
    'kind', 'DISPOSAL'))->'rows'->0;
  if v_row->>'kind' <> 'DISPOSAL' or v_row->>'reason' <> 'Rusak terjepit' or v_row->>'qty_delta' <> '-2.000' then
    raise exception 'riwayat terbaru seharusnya disposal: %', v_row;
  end if;
  perform pg_temp.expect_error('select public.list_stock_movements_v1(''{}'')', 'INVALID_INPUT');

  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_res := public.list_stock_movements_v1(jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002', 'kind', 'DISPOSAL'));
  if v_res->'rows'->0->>'cost_delta' <> '-6000.000000' then
    raise exception 'owner harus melihat cost_delta: %', v_res;
  end if;
end $$;

-- Invariant: ledger = posisi, cost ledger = lot, sum posisi = lot, tidak ada negatif.
do $$
begin
  if exists (select 1 from private.stock_positions p where p.qty_base <>
      (select coalesce(sum(m.qty_delta), 0) from private.stock_movements m where m.position_id = p.id)) then
    raise exception 'Invariant: qty posisi != ledger';
  end if;
  if exists (select 1 from private.inventory_lots l where l.remaining_cost <>
      (select coalesce(sum(m.cost_delta), 0) from private.stock_movements m where m.lot_id = l.id)
      or l.remaining_qty <> (select coalesce(sum(s.qty_base), 0) from private.stock_positions s where s.lot_id = l.id)) then
    raise exception 'Invariant: lot != ledger/posisi';
  end if;
  if exists (select 1 from private.stock_positions where qty_base < 0)
     or exists (select 1 from private.inventory_lots where remaining_qty < 0 or remaining_cost < 0) then
    raise exception 'Invariant: stok/modal negatif';
  end if;
end $$;

rollback;
