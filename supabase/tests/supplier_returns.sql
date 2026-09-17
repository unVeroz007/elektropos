-- D5: distributor, retur ke distributor dan penyelesaian klaim (BR-05, BR-06, BR-12).
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
create function pg_temp.pos(p_label text) returns jsonb language sql as $$
  select jsonb_build_object('position_id', id, 'expected_version', version) from private.stock_positions where label = p_label $$;
create function pg_temp.lamp_pos() returns jsonb language sql as $$
  select jsonb_build_object('position_id', p.id, 'expected_version', p.version) from private.stock_positions p
  join private.inventory_lots l on l.id = p.lot_id join private.stock_documents d on d.id = (
    select document_id from private.stock_document_items where id = l.origin_item_id)
  where l.product_id = 'a2000000-0000-4000-8000-000000000001' and d.kind = 'OPENING' $$;

-- Distributor.
do $$
declare v jsonb; v_id uuid; v_op uuid := gen_random_uuid();
begin
  perform pg_temp.fails('staff', 'upsert_supplier_v1', pg_temp.op() || '{"name":"CV A"}', 'FORBIDDEN');
  perform pg_temp.fails('owner', 'upsert_supplier_v1', pg_temp.op() || '{"name":"  "}', 'INVALID_INPUT');
  v := pg_temp.rpc('owner', 'upsert_supplier_v1', jsonb_build_object('operation_id', v_op, 'name', 'PT Terang Jaya', 'contact', '0811'));
  v_id := (v->>'entity_id')::uuid;
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'upsert_supplier_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'command distributor');
  perform pg_temp.fails('owner', 'upsert_supplier_v1', pg_temp.op() || '{"name":"pt terang  jaya"}', 'DUPLICATE_NAME');
  perform pg_temp.fails('owner', 'upsert_supplier_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_id,
    'expected_version', 9, 'name', 'PT Terang Jaya Abadi'), 'VERSION_CONFLICT');
  v := pg_temp.rpc('owner', 'upsert_supplier_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_id,
    'expected_version', 1, 'name', 'PT Terang Jaya Abadi', 'address', 'Jl. Pasar'));
  perform pg_temp.eq((v->>'version')::integer, 2, 'versi distributor');
  perform pg_temp.fails('staff', 'list_suppliers_v1', '{}', 'FORBIDDEN');
  v := pg_temp.rpc('maint', 'list_suppliers_v1', '{"query":"terang"}');
  perform pg_temp.eq(v->'items'->0->>'credit_balance', '0', 'saldo kredit awal');

  -- Stok untuk diretur: lampu 10 pcs modal 100.000; kabel 1 roll 100 m modal 300.000.
  perform pg_temp.rpc('owner', 'post_opening_stock_v1', pg_temp.op() || jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '10', 'acquisition_cost', '100000'),
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', '1', 'acquisition_cost', '300000',
      'rolls', jsonb_build_object('count', '1', 'capacity', '100', 'label_prefix', 'RT')))));
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"0"}');
end $$;

-- Buat retur: modal keluar BR-05, stok keluar, klaim = Σ modal.
do $$
declare v jsonb; v_sup uuid := (select id from private.suppliers); v_ret uuid; v_doc uuid; v_payload jsonb;
begin
  v_payload := jsonb_build_object('supplier_id', v_sup, 'reason', 'Lampu mati & kabel cacat', 'items', jsonb_build_array(
    pg_temp.lamp_pos() || '{"qty_base":"3"}', pg_temp.pos('RT-01') || '{"qty_base":"25"}'));
  perform pg_temp.fails('staff', 'create_supplier_return_v1', pg_temp.op() || v_payload, 'FORBIDDEN');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || (v_payload - 'reason'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,0,qty_base}', '"11"'), 'INSUFFICIENT_STOCK');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,0,qty_base}', '"1.5"'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,0,expected_version}', '5'), 'VERSION_CONFLICT');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,1}', v_payload->'items'->0), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,0,position_id}',
    to_jsonb(gen_random_uuid())), 'NOT_FOUND');

  v := pg_temp.rpc('owner', 'create_supplier_return_v1', pg_temp.op() || v_payload);
  v_ret := (v->>'entity_id')::uuid;
  perform pg_temp.eq(v->>'claim_value', '105000.000000', 'klaim = 30000 + 75000');
  select stock_document_id into v_doc from private.supplier_returns where id = v_ret;
  perform pg_temp.eq((select sum(qty_base) from private.stock_positions where id = (pg_temp.lamp_pos()->>'position_id')::uuid), 7::numeric, 'lampu sisa 7');
  perform pg_temp.eq((select qty_base::text || ':' || sealed from private.stock_positions where label = 'RT-01'), '75.000:false', 'roll terpotong');
  perform pg_temp.eq((select count(*) from private.stock_movements m join private.stock_document_items i on i.id = m.stock_document_item_id
    where i.document_id = v_doc and m.kind = 'SUPPLIER_RETURN_OUT'), 2::bigint, 'mutasi retur');
  perform pg_temp.eq((select remaining_cost from private.inventory_lots l join private.stock_positions p on p.lot_id = l.id
    where p.label = 'RT-01'), 225000::numeric, 'modal roll sisa');

  -- REFUND: TRANSFER harus dikonfirmasi; CASH masuk kas; selisih tercatat.
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REFUND', 'amount', '100000', 'method', 'TRANSFER'), 'PAYMENT_NOT_CONFIRMED');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REFUND', 'method', 'CASH', 'cashbox', 'SHOP_DRAWER'), 'INVALID_NUMBER');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REJECTED', 'amount', '1', 'note', 'x'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REFUND', 'amount', '100000', 'method', 'CASH', 'cashbox', 'FATHER_WALLET'), 'CASH_SESSION_CLOSED');
  v := pg_temp.rpc('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REFUND', 'amount', '100000', 'method', 'CASH', 'cashbox', 'SHOP_DRAWER'));
  perform pg_temp.eq(v->>'settlement_difference', '-5000.000000', 'rugi retur 5000');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 100000::numeric, 'uang kembali masuk laci');
  perform pg_temp.eq((select kind from private.cash_movements where supplier_return_id = v_ret), 'SUPPLIER_REFUND', 'jenis mutasi');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 2, 'outcome', 'REJECTED', 'note', 'x'), 'ALREADY_SETTLED');
end $$;

-- CREDIT lalu dipakai membayar pembelian.
do $$
declare v jsonb; v_sup uuid := (select id from private.suppliers); v_ret uuid;
begin
  v := pg_temp.rpc('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_sup,
    'reason', 'Lampu kedip', 'items', jsonb_build_array(pg_temp.lamp_pos() || '{"qty_base":"1"}')));
  v_ret := (v->>'entity_id')::uuid;
  perform pg_temp.eq(v->>'claim_value', '10000.000000', 'klaim 1 lampu');
  v := pg_temp.rpc('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'CREDIT', 'amount', '12000'));
  perform pg_temp.eq(v->>'settlement_difference', '2000.000000', 'untung retur');
  perform pg_temp.eq((pg_temp.rpc('owner', 'list_suppliers_v1', '{}')->'items'->0->>'credit_balance'), '12000', 'saldo kredit');
  perform pg_temp.fails('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_sup,
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '2', 'acquisition_cost', '13000')),
    'payment', jsonb_build_object('method', 'SUPPLIER_CREDIT', 'amount', '13000')), 'INSUFFICIENT_CREDIT');
  perform pg_temp.rpc('owner', 'post_stock_receipt_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_sup,
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1', 'acquisition_cost', '12000')),
    'payment', jsonb_build_object('method', 'SUPPLIER_CREDIT', 'amount', '12000')));
  perform pg_temp.eq(private.supplier_credit_balance(v_sup), 0::numeric, 'kredit terpakai');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 100000::numeric, 'kredit tidak mengubah kas');
end $$;

-- REPLACEMENT: lot baru bernilai klaim (proporsional qty) dan REJECTED.
do $$
declare v jsonb; v_sup uuid := (select id from private.suppliers); v_ret uuid; v_op uuid := gen_random_uuid(); v_payload jsonb;
begin
  v := pg_temp.rpc('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_sup,
    'reason', 'Tukar', 'items', jsonb_build_array(pg_temp.lamp_pos() || '{"qty_base":"1"}')));
  v_ret := (v->>'entity_id')::uuid;
  v_payload := jsonb_build_object('operation_id', v_op, 'supplier_return_id', v_ret, 'expected_version', 1, 'outcome', 'REPLACEMENT',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '2'),
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1')));
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_set(v_payload, '{items,0,acquisition_cost}', '"5000"'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_set(jsonb_set(v_payload,
    '{items,0,acquisition_cost}', '"5000"'), '{items,1,acquisition_cost}', '"4999.999999"'), 'INVALID_INPUT');
  v := pg_temp.rpc('owner', 'settle_supplier_return_v1', v_payload);
  perform pg_temp.eq(v->>'settlement_difference', '0', 'pengganti tanpa selisih');
  perform pg_temp.eq((select string_agg(l.original_cost::text, ',' order by i.line_no) from private.stock_document_items i
    join private.inventory_lots l on l.origin_item_id = i.id where i.document_id = (v->>'replacement_document_id')::uuid),
    '6666.666667,3333.333333', 'alokasi modal pengganti');
  perform pg_temp.eq((select count(*) from private.stock_movements m join private.stock_document_items i on i.id = m.stock_document_item_id
    where i.document_id = (v->>'replacement_document_id')::uuid and m.kind = 'SUPPLIER_REPLACEMENT_IN'), 2::bigint, 'mutasi pengganti');
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'settle_supplier_return_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'command penyelesaian');
  perform pg_temp.rpc('owner', 'settle_supplier_return_v1', v_payload);
  perform pg_temp.eq((select count(*) from private.stock_documents where kind = 'SUPPLIER_REPLACEMENT'), 1::bigint, 'idempoten pengganti');

  v := pg_temp.rpc('owner', 'create_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_id', v_sup,
    'reason', 'Pecah', 'items', jsonb_build_array(pg_temp.pos('RT-01') || '{"qty_base":"75"}')));
  v_ret := (v->>'entity_id')::uuid;
  perform pg_temp.eq(v->>'claim_value', '225000.000000', 'klaim sisa roll = seluruh modal sisa');
  perform pg_temp.fails('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REJECTED'), 'INVALID_INPUT');
  v := pg_temp.rpc('owner', 'settle_supplier_return_v1', pg_temp.op() || jsonb_build_object('supplier_return_id', v_ret,
    'expected_version', 1, 'outcome', 'REJECTED', 'note', 'Distributor menolak, cacat pemakaian'));
  perform pg_temp.eq(v->>'settlement_difference', '-225000.000000', 'kerugian klaim ditolak');
  perform pg_temp.eq((select remaining_cost::text || ':' || remaining_qty from private.inventory_lots l
    join private.stock_positions p on p.lot_id = l.id where p.label = 'RT-01'), '0.000000:0.000', 'lot habis, modal nol');

  v := pg_temp.rpc('maint', 'list_supplier_returns_v1', '{"status":"SETTLED"}');
  perform pg_temp.eq(jsonb_array_length(v->'items'), 4, 'daftar retur selesai');
  -- Dalam satu transaksi uji created_at sama, jadi cari berdasarkan hasil.
  perform pg_temp.eq((select x->'items'->0->>'position_label' from jsonb_array_elements(v->'items') x
    where x->>'outcome' = 'REJECTED'), 'RT-01', 'detail barang');
  perform pg_temp.fails('staff', 'list_supplier_returns_v1', '{}', 'FORBIDDEN');
end $$;

-- Integrasi laporan: retur distributor tampil untuk owner, tersembunyi dari staff.
do $$
declare v jsonb; v_today text := (now() at time zone 'Asia/Jakarta')::date::text;
begin
  v := pg_temp.rpc('owner', 'get_report_v1', jsonb_build_object('start_date', v_today, 'end_date', v_today));
  perform pg_temp.eq((v->'supplier_returns'->>'count')::int,
    (select count(*)::int from private.supplier_returns), 'jumlah retur distributor di laporan');
  perform pg_temp.eq(v->'supplier_returns'->>'claim_value',
    private.ops_money((select sum(claim_value) from private.supplier_returns)), 'nilai klaim di laporan');
  perform pg_temp.eq(v->'supplier_returns'->>'settlement_difference',
    private.ops_money((select coalesce(sum(settlement_difference), 0) from private.supplier_returns)), 'selisih penyelesaian di laporan');
  v := pg_temp.rpc('staff', 'get_report_v1', jsonb_build_object('start_date', v_today, 'end_date', v_today));
  perform pg_temp.eq(v ? 'supplier_returns', false, 'staff tanpa data modal retur distributor');
end $$;

-- Invariant ledger + tidak ada stok/modal negatif.
do $$ begin
  perform pg_temp.eq((select count(*) from private.stock_positions p where p.qty_base <>
    (select coalesce(sum(m.qty_delta), 0) from private.stock_movements m where m.position_id = p.id)), 0::bigint, 'ledger qty');
  perform pg_temp.eq((select count(*) from private.inventory_lots l where l.remaining_cost <>
    (select coalesce(sum(m.cost_delta), 0) from private.stock_movements m where m.lot_id = l.id)), 0::bigint, 'ledger modal');
  perform pg_temp.eq((select count(*) from private.inventory_lots where remaining_qty < 0 or remaining_cost < 0
    or (remaining_qty = 0 and remaining_cost <> 0)), 0::bigint, 'tanpa negatif');
end $$;

rollback;
