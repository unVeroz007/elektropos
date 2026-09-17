-- Barang masuk & stok awal: pembelian tunai (D3), validasi modal, roll per posisi (T08/BR-03), command = nama RPC.
\set ON_ERROR_STOP on

begin;

create function pg_temp.rpc(p_actor text, p_fn text, p_input jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', case p_actor
    when 'owner' then '11111111-1111-4111-8111-111111111111'
    when 'staff' then '22222222-2222-4222-8222-222222222222'
    when 'maint' then '33333333-3333-4333-8333-333333333333' end, true);
  execute format('select public.%I($1)', p_fn) into v using p_input;
  return v;
end $$;
create function pg_temp.fails(p_actor text, p_fn text, p_input jsonb, p_code text) returns void language plpgsql as $$
begin
  perform pg_temp.rpc(p_actor, p_fn, p_input);
  raise exception 'TIDAK_GAGAL';
exception when others then
  if sqlerrm <> p_code and position(p_code || ':' in sqlerrm) <> 1 then
    raise exception 'Uji % %: harap %, dapat: %', p_fn, p_input, p_code, sqlerrm;
  end if;
end $$;
create function pg_temp.eq(p_got anyelement, p_want anyelement, p_what text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'Uji gagal %: harap %, dapat %', p_what, p_want, p_got; end if;
end $$;
create function pg_temp.op() returns jsonb language sql as $$ select jsonb_build_object('operation_id', gen_random_uuid()) $$;
create function pg_temp.expected(p_box text) returns numeric language sql as $$
  select private.cash_session_expected(id) from private.cash_sessions where cashbox_id = p_box and status = 'OPEN' $$;
create function pg_temp.lamp(p_qty text, p_cost text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
    'qty', p_qty, 'acquisition_cost', p_cost)) $$;

-- Validasi stok awal.
do $$
declare v jsonb; v_op uuid := gen_random_uuid();
begin
  perform pg_temp.fails('staff', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1', '1000')), 'FORBIDDEN');
  perform pg_temp.fails('maint', 'post_stock_receipt_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1', '1000')), 'FORBIDDEN');
  -- Modal wajib; nol butuh alasan; stok awal tanpa pembayaran.
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items',
    jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1'))), 'INVALID_NUMBER');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1', '0')), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1', '1000.5')), 'INVALID_NUMBER');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1.5', '1000')), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('1', '1000'),
    'payment', jsonb_build_object('method', 'CASH', 'amount', '1000')), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items',
    pg_temp.lamp('1', '1000') -> 0 || '{"unit_price":"1"}'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items',
    jsonb_build_array(jsonb_build_object('product_unit_id', 'bukan-uuid', 'qty', '1', 'acquisition_cost', '5'))), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items',
    jsonb_build_array(jsonb_build_object('product_unit_id', gen_random_uuid(), 'qty', '1', 'acquisition_cost', '5'))), 'NOT_FOUND');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items',
    pg_temp.lamp('1', '1000') -> 0 || '{"positions":[{"label":"X","qty_base":"1","segment_capacity":"1"}]}'), 'INVALID_INPUT');

  v := pg_temp.rpc('owner', 'post_opening_stock_v1', jsonb_build_object('operation_id', v_op, 'items',
    jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '3',
      'acquisition_cost', '0', 'free_reason', 'Hadiah distributor'))));
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'post_opening_stock_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'command stok awal');
  perform pg_temp.eq((select free_reason from private.stock_document_items where document_id = (v->>'entity_id')::uuid),
    'Hadiah distributor', 'alasan gratis tersimpan');
  perform pg_temp.eq((select count(*) from private.purchase_payments), 0::bigint, 'stok awal tanpa pembayaran');
end $$;

-- T08: roll. "N roll @ kapasitas" -> N posisi bersegel berlabel otomatis + potongan eksplisit.
do $$
declare v jsonb; v_lot uuid;
begin
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '3', 'acquisition_cost', '900000'))),
    'INVALID_INPUT');
  -- Σ posisi harus = qty dasar.
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '3', 'acquisition_cost', '900000',
      'rolls', jsonb_build_object('count', '2', 'capacity', '100')))), 'INVALID_INPUT');
  -- Segel hanya bila utuh.
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '40', 'acquisition_cost', '100000',
      'positions', jsonb_build_array(jsonb_build_object('label', 'P1', 'qty_base', '40', 'segment_capacity', '100', 'sealed', true))))),
    'INVALID_INPUT');
  -- Label wajib & unik (termasuk dalam satu permintaan).
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '40', 'acquisition_cost', '100000',
      'positions', jsonb_build_array(jsonb_build_object('qty_base', '40', 'segment_capacity', '100'))))), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '40', 'acquisition_cost', '100000',
      'positions', jsonb_build_array(jsonb_build_object('label', 'P1', 'qty_base', '20', 'segment_capacity', '50'),
        jsonb_build_object('label', 'P1', 'qty_base', '20', 'segment_capacity', '50'))))), 'LABEL_TAKEN');

  -- 3 roll @100 m (pakai satuan roll) + potongan 37,5 m (pakai satuan meter) pada baris kedua.
  v := pg_temp.rpc('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '3', 'acquisition_cost', '900001',
      'rolls', jsonb_build_object('count', '3', 'capacity', '100', 'label_prefix', 'NYA-A')),
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '137.5', 'acquisition_cost', '400000',
      'rolls', jsonb_build_object('count', '1', 'capacity', '100'),
      'positions', jsonb_build_array(jsonb_build_object('label', 'SISA-1', 'qty_base', '37.5', 'segment_capacity', '100'))))));
  v_lot := (v->'lines'->0->>'lot_id')::uuid;
  perform pg_temp.eq((select string_agg(label || ':' || qty_base || ':' || sealed, ',' order by label)
    from private.stock_positions where lot_id = v_lot), 'NYA-A-01:100.000:true,NYA-A-02:100.000:true,NYA-A-03:100.000:true', 'roll otomatis');
  perform pg_temp.eq((select count(*) from private.inventory_lots where id = v_lot), 1::bigint, 'satu lot per baris');
  perform pg_temp.eq((select remaining_cost from private.inventory_lots where id = v_lot), 900001::numeric, 'modal lot');
  perform pg_temp.eq((select count(*) from private.stock_positions where lot_id = (v->'lines'->1->>'lot_id')::uuid), 2::bigint, 'roll + potongan');
  perform pg_temp.eq((select sealed from private.stock_positions where label = 'SISA-1'), false, 'potongan tidak bersegel');
  perform pg_temp.eq((v->'lines'->1->'positions'->0->>'label') like 'KBL-NYA-1.5-%L2-01', true, 'label default');
  -- Label yang sudah dipakai ditolak.
  perform pg_temp.fails('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '1', 'acquisition_cost', '300000',
      'rolls', jsonb_build_object('count', '1', 'capacity', '100', 'label_prefix', 'NYA-A')))), 'LABEL_TAKEN');
end $$;

-- D3: pembelian dibayar tunai / transfer / validasi.
do $$
declare v jsonb; v_op uuid := gen_random_uuid(); v_supplier uuid; v_payload jsonb;
begin
  v_supplier := (pg_temp.rpc('owner', 'upsert_supplier_v1', pg_temp.op() || '{"name":"CV Sumber Listrik"}')->>'entity_id')::uuid;
  v_payload := jsonb_build_object('operation_id', v_op, 'supplier_id', v_supplier, 'source_note', 'Nota 77',
    'items', pg_temp.lamp('10', '120000') || jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '1', 'acquisition_cost', '330000',
      'rolls', jsonb_build_object('count', '1', 'capacity', '100', 'label_prefix', 'NYA-B'))),
    'payment', jsonb_build_object('method', 'CASH', 'cashbox', 'SHOP_DRAWER', 'amount', '450000'));

  perform pg_temp.fails('owner', 'post_stock_receipt_v1', v_payload || pg_temp.op(), 'CASH_SESSION_CLOSED');
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"400000"}');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', v_payload || pg_temp.op(), 'INSUFFICIENT_CASH');
  perform pg_temp.rpc('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"100000","reason":"tambah"}');
  -- Jumlah bayar harus = Σ modal.
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{payment,amount}', '"449999"'), 'PAYMENT_MISMATCH');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || (v_payload - 'payment'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{payment}',
    '{"method":"CASH","amount":"450000"}'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{payment}',
    '{"method":"TRANSFER","amount":"450000"}'), 'PAYMENT_NOT_CONFIRMED');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{payment,cash_session_id}',
    to_jsonb(gen_random_uuid())), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{supplier_id}',
    to_jsonb(gen_random_uuid())), 'NOT_FOUND');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_set(v_payload, '{payment}',
    '{"method":"SUPPLIER_CREDIT","amount":"450000"}'), 'INSUFFICIENT_CREDIT');

  v := pg_temp.rpc('owner', 'post_stock_receipt_v1', v_payload);
  perform pg_temp.eq(v->>'total_cost', '450000', 'total pembelian');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 50000::numeric, 'kas 500000-450000');
  perform pg_temp.eq((select kind || ':' || direction || ':' || amount from private.cash_movements
    where stock_document_id = (v->>'entity_id')::uuid), 'PURCHASE:OUT:450000', 'mutasi pembelian');
  perform pg_temp.eq((select method || ':' || amount || ':' || cashbox_id from private.purchase_payments
    where stock_document_id = (v->>'entity_id')::uuid), 'CASH:450000:SHOP_DRAWER', 'purchase_payments');
  perform pg_temp.eq((select supplier_id from private.stock_documents where id = (v->>'entity_id')::uuid), v_supplier, 'distributor');
  -- Idempoten: kas tidak berkurang dua kali; command = nama RPC (bug lama: post_receipt_stock_v1).
  perform pg_temp.rpc('owner', 'post_stock_receipt_v1', v_payload);
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 50000::numeric, 'idempoten pembelian');
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'post_stock_receipt_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'command barang masuk');

  -- TRANSFER terkonfirmasi tanpa distributor; tidak menyentuh kas.
  v := pg_temp.rpc('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_build_object('items', pg_temp.lamp('2', '24000'),
    'payment', jsonb_build_object('method', 'TRANSFER', 'amount', '24000', 'confirmed', true, 'reference', 'BRI')));
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 50000::numeric, 'transfer tidak mengubah kas');
  perform pg_temp.eq((select method from private.purchase_payments where stock_document_id = (v->>'entity_id')::uuid), 'TRANSFER', 'metode transfer');
end $$;

-- Invariant ledger BR-06/BR-14.
do $$ begin
  perform pg_temp.eq((select count(*) from private.stock_positions p where p.qty_base <>
    (select coalesce(sum(m.qty_delta), 0) from private.stock_movements m where m.position_id = p.id)), 0::bigint, 'ledger qty');
  perform pg_temp.eq((select count(*) from private.inventory_lots l where l.remaining_cost <>
    (select coalesce(sum(m.cost_delta), 0) from private.stock_movements m where m.lot_id = l.id)), 0::bigint, 'ledger modal');
  perform pg_temp.eq((select count(*) from private.inventory_lots l where l.remaining_qty <>
    (select coalesce(sum(p.qty_base), 0) from private.stock_positions p where p.lot_id = l.id)), 0::bigint, 'lot = posisi');
end $$;

rollback;
