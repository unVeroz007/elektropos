-- FR-INV-03/BR-06: stok opname untuk posisi/produk terpilih, versi, validasi hitungan, modal selisih.
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
  where l.product_id = 'a2000000-0000-4000-8000-000000000001' order by l.posted_at, s.id limit 1
$$;

select pg_temp.act('11111111-1111-4111-8111-111111111111');
select public.post_opening_stock_v1(jsonb_build_object(
  'operation_id', 'd2000000-0000-4000-8000-000000000001', 'reason', 'Stok awal',
  'items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '10', 'acquisition_cost', '100000'),
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '150', 'acquisition_cost', '450000',
      'positions', jsonb_build_array(
        jsonb_build_object('qty_base', '100', 'segment_capacity', '100', 'sealed', true, 'label', 'R001'),
        jsonb_build_object('qty_base', '50', 'segment_capacity', '100', 'sealed', false, 'label', 'R002'))))));

create temp table ids(name text primary key, id uuid);
grant all on ids to public;

-- Membuat hitungan: menyimpan versi & qty sistem saat mulai.
do $$
declare v_res jsonb; v_count jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform pg_temp.expect_error(format('select public.create_stock_count_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid())), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.create_stock_count_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'position_ids', jsonb_build_array((pg_temp.pos('R001')).id, (pg_temp.pos('R001')).id))), 'INVALID_INPUT');

  v_res := public.create_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000010',
    'position_ids', jsonb_build_array((pg_temp.pos('R001')).id, (pg_temp.pos('R002')).id), 'note', 'Opname kabel'));
  if (v_res->>'item_count')::integer <> 2 or v_res->>'status' <> 'DRAFT' then raise exception 'create count salah: %', v_res; end if;
  insert into ids values ('roll', (v_res->>'entity_id')::uuid);
  if not (public.get_operation_v1(jsonb_build_object('command', 'create_stock_count_v1',
      'operation_id', 'd2000000-0000-4000-8000-000000000010'))->>'found')::boolean then
    raise exception 'get_operation_v1 create_stock_count_v1 tidak ditemukan';
  end if;

  v_res := public.create_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000011',
    'product_ids', jsonb_build_array('a2000000-0000-4000-8000-000000000001')));
  insert into ids values ('lamp', (v_res->>'entity_id')::uuid);

  v_count := public.get_stock_count_v1(jsonb_build_object('count_id', (select id from ids where name = 'roll')));
  if v_count->'items'->0->>'system_qty' <> '100.000' or (v_count->'items'->0->>'expected_version')::integer <> 1
     or v_count->'items'->0->>'label' <> 'R001' then
    raise exception 'get_stock_count_v1 salah: %', v_count;
  end if;

  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select public.get_stock_count_v1(%L)', jsonb_build_object(
    'count_id', (select id from ids where name = 'roll'))), 'FORBIDDEN');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'count_id', (select id from ids where name = 'roll'), 'items', '[]'::jsonb)), 'FORBIDDEN');
end $$;

-- Validasi hitungan (bug lama: counted '-5' tidak divalidasi) dan kelengkapan.
do $$
declare v_count uuid := (select id from ids where name = 'roll'); v_r1 uuid := (pg_temp.pos('R001')).id; v_r2 uuid := (pg_temp.pos('R002')).id;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '-5'),
      jsonb_build_object('position_id', v_r2, 'counted_qty', '50')))), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', 97.5),
      jsonb_build_object('position_id', v_r2, 'counted_qty', '50')))), 'INVALID_NUMBER');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '97.5')))), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '97.5'),
      jsonb_build_object('position_id', v_r1, 'counted_qty', '97.5')))), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '97.55'),
      jsonb_build_object('position_id', v_r2, 'counted_qty', '50')))), 'INVALID_NUMBER');
  -- Selisih lebih pada roll wajib modal/alasan dan label potongan baru.
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '100'),
      jsonb_build_object('position_id', v_r2, 'counted_qty', '51')))), 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_count, 'items', jsonb_build_array(jsonb_build_object('position_id', v_r1, 'counted_qty', '100'),
      jsonb_build_object('position_id', v_r2, 'counted_qty', '51', 'zero_cost_reason', 'lebih ukur')))), 'new_label');
  if (select count(*) from private.stock_documents where kind = 'COUNT') <> 0 then
    raise exception 'Penolakan hitungan tidak boleh meninggalkan dokumen';
  end if;
end $$;

-- VERSION_CONFLICT: posisi berubah setelah hitungan dimulai; seluruh batch ditolak.
do $$
declare v_res jsonb; v_c uuid;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_res := public.create_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000012',
    'position_ids', jsonb_build_array((pg_temp.pos('R002')).id)));
  v_c := (v_res->>'entity_id')::uuid;
  -- Hitungan lain pada R002 juga tertunda (tidak memblokir toko); transfer tetap boleh.
  perform public.transfer_stock_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000013',
    'position_id', (pg_temp.pos('R002')).id, 'expected_version', 1, 'qty_base', '10',
    'destination_location', 'FIELD_FATHER', 'destination_label', 'R002-F', 'reason', 'Kunjungan'));
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_c, 'items', jsonb_build_array(jsonb_build_object('position_id', (pg_temp.pos('R002')).id, 'counted_qty', '40')))),
    'VERSION_CONFLICT');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', (select id from ids where name = 'roll'), 'items', jsonb_build_array(
      jsonb_build_object('position_id', (pg_temp.pos('R001')).id, 'counted_qty', '100'),
      jsonb_build_object('position_id', (pg_temp.pos('R002')).id, 'counted_qty', '40')))), 'VERSION_CONFLICT');
end $$;

-- Posting sukses: selisih kurang memakai modal lot posisi, selisih lebih jadi lot koreksi.
do $$
declare v_res jsonb; v_lot private.inventory_lots; v_c uuid; v_item private.stock_count_items; v_new private.inventory_lots;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v_res := public.create_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000014',
    'position_ids', jsonb_build_array((pg_temp.pos('R001')).id, (pg_temp.pos('R002')).id)));
  v_c := (v_res->>'entity_id')::uuid;
  v_res := public.post_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000015',
    'count_id', v_c, 'reason', 'Opname bulanan', 'items', jsonb_build_array(
      jsonb_build_object('position_id', (pg_temp.pos('R001')).id, 'counted_qty', '97.5', 'reason', 'Terpotong tanpa nota'),
      jsonb_build_object('position_id', (pg_temp.pos('R002')).id, 'counted_qty', '40'))));
  -- Lot kabel 150 m / 450.000 -> 2,5 m = 7.500.
  if (v_res->>'adjusted_lines')::integer <> 1 or v_res->>'cost_delta' <> '-7500.000000' or v_res->>'status' <> 'POSTED' then
    raise exception 'post count hasil salah: %', v_res;
  end if;
  if (pg_temp.pos('R001')).qty_base <> 97.5 or (pg_temp.pos('R001')).sealed then
    raise exception 'post count: R001 seharusnya 97.5 dan tidak bersegel';
  end if;
  select * into v_lot from private.inventory_lots where id = (pg_temp.pos('R001')).lot_id;
  if v_lot.remaining_qty <> 147.5 or v_lot.remaining_cost <> 442500 then
    raise exception 'post count: lot seharusnya 147.5/442500, dapat %/%', v_lot.remaining_qty, v_lot.remaining_cost;
  end if;
  select * into v_item from private.stock_count_items where count_id = v_c and position_id = (pg_temp.pos('R001')).id;
  if v_item.counted_qty <> 97.5 or v_item.difference <> -2.5 or v_item.cost_delta <> -7500 or v_item.document_item_id is null then
    raise exception 'post count: baris hitung tidak tercatat benar';
  end if;
  if not exists (select 1 from private.stock_movements where kind = 'COUNT_OUT' and qty_delta = -2.5 and cost_delta = -7500) then
    raise exception 'post count: movement COUNT_OUT tidak ada';
  end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'post_stock_count_v1',
      'operation_id', 'd2000000-0000-4000-8000-000000000015'))->>'found')::boolean then
    raise exception 'get_operation_v1 post_stock_count_v1 tidak ditemukan';
  end if;
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_c, 'items', jsonb_build_array(
      jsonb_build_object('position_id', (pg_temp.pos('R001')).id, 'counted_qty', '97.5'),
      jsonb_build_object('position_id', (pg_temp.pos('R002')).id, 'counted_qty', '40')))), 'ALREADY_FINALIZED');

  -- Lampu: ditemukan 2 pcs lebih dengan modal terkonfirmasi.
  v_c := (select id from ids where name = 'lamp');
  perform pg_temp.expect_error(format('select public.post_stock_count_v1(%L)', jsonb_build_object('operation_id', gen_random_uuid(),
    'count_id', v_c, 'items', jsonb_build_array(jsonb_build_object('position_id', (pg_temp.lamp_pos()).id,
      'counted_qty', '12', 'acquisition_cost', '24000')))), 'cost_confirmed');
  v_res := public.post_stock_count_v1(jsonb_build_object('operation_id', 'd2000000-0000-4000-8000-000000000016',
    'count_id', v_c, 'items', jsonb_build_array(jsonb_build_object('position_id', (pg_temp.lamp_pos()).id,
      'counted_qty', '12', 'acquisition_cost', '24000', 'cost_confirmed', true))));
  if v_res->>'cost_delta' <> '24000.000000' then raise exception 'post count lebih salah: %', v_res; end if;
  select l.* into v_new from private.inventory_lots l join private.stock_document_items di on di.id = l.origin_item_id
    join private.stock_documents d on d.id = di.document_id where d.kind = 'COUNT' and l.product_id = 'a2000000-0000-4000-8000-000000000001';
  if v_new.original_qty <> 2 or v_new.original_cost <> 24000 then
    raise exception 'post count lebih: lot koreksi salah';
  end if;
  if (select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = 'a2000000-0000-4000-8000-000000000001') <> 12 then
    raise exception 'post count lebih: total lampu seharusnya 12';
  end if;
end $$;

-- Daftar hitungan.
do $$
declare v_res jsonb;
begin
  perform pg_temp.act('33333333-3333-4333-8333-333333333333');
  v_res := public.list_stock_counts_v1(jsonb_build_object('status', 'POSTED'));
  if jsonb_array_length(v_res->'rows') <> 2 then raise exception 'list_stock_counts_v1 POSTED salah: %', v_res; end if;
  v_res := public.list_stock_counts_v1(jsonb_build_object('status', 'DRAFT', 'limit', 1));
  if jsonb_array_length(v_res->'rows') <> 1 or not (v_res->>'has_more')::boolean then
    raise exception 'list_stock_counts_v1 DRAFT salah: %', v_res;
  end if;
end $$;

do $$
begin
  if exists (select 1 from private.stock_positions p where p.qty_base <>
      (select coalesce(sum(m.qty_delta), 0) from private.stock_movements m where m.position_id = p.id))
     or exists (select 1 from private.inventory_lots l where l.remaining_cost <>
      (select coalesce(sum(m.cost_delta), 0) from private.stock_movements m where m.lot_id = l.id)
      or l.remaining_qty <> (select coalesce(sum(s.qty_base), 0) from private.stock_positions s where s.lot_id = l.id)) then
    raise exception 'Invariant ledger/lot gagal setelah opname';
  end if;
end $$;

rollback;
