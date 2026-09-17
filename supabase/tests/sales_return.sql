-- Uji retur penjualan: K06 (modal kumulatif per alokasi asal, multi-lot), T07 (NONE, pecahan, nota nol),
-- K11 (refund_method, kas terkunci, saldo), BR-08 refund kumulatif (AT-13), BR-03 retur roll posisi baru.
\set ON_ERROR_STOP on

begin;
\ir sales_helpers.psql

create temp table fx(k text primary key, v uuid) on commit drop;

do $$
declare v_p uuid;
begin
  -- K06: lot A 6 pcs Rp60.000 (lebih tua), lot B 4 pcs Rp20.000.
  v_p := pg_temp.product('R-MULTI', 'pcs', 1, false);
  insert into fx values ('M', v_p), ('M_u', pg_temp.unit(v_p, 'pcs', 1, 1, 10000));
  insert into fx values ('M_lotA', pg_temp.lot_of(pg_temp.stock(v_p, 6, 60000, '2026-01-01 08:00+07'))),
    ('M_lotB', pg_temp.lot_of(pg_temp.stock(v_p, 4, 20000, '2026-01-02 08:00+07')));
  -- AT-13: 3 pcs harga 33,333333 → neto 100; modal 3 pcs Rp10.000.
  v_p := pg_temp.product('R-THIRD', 'pcs', 1, false);
  insert into fx values ('T', v_p), ('T_u', pg_temp.unit(v_p, 'pcs', 1, 1, 33.333333));
  insert into fx values ('T_lot', pg_temp.lot_of(pg_temp.stock(v_p, 3, 10000, '2026-01-01 08:00+07')));
  -- Kumulatif lintas alokasi: lot A 2 pcs Rp10.000, lot B 2 pcs Rp30.000.
  v_p := pg_temp.product('R-CUM', 'pcs', 1, false);
  insert into fx values ('C', v_p), ('C_u', pg_temp.unit(v_p, 'pcs', 1, 1, 50000));
  insert into fx values ('C_lotA', pg_temp.lot_of(pg_temp.stock(v_p, 2, 10000, '2026-01-01 08:00+07'))),
    ('C_lotB', pg_temp.lot_of(pg_temp.stock(v_p, 2, 30000, '2026-01-02 08:00+07')));
  -- NONE / DAMAGED / pilihan alokasi owner.
  v_p := pg_temp.product('R-NONE', 'pcs', 1, false);
  insert into fx values ('N', v_p), ('N_u', pg_temp.unit(v_p, 'pcs', 1, 1, 15000));
  insert into fx values ('N_lot', pg_temp.lot_of(pg_temp.stock(v_p, 10, 50000, '2026-01-01 08:00+07')));
  v_p := pg_temp.product('R-PICK', 'pcs', 1, false);
  insert into fx values ('K', v_p), ('K_u', pg_temp.unit(v_p, 'pcs', 1, 1, 5000));
  insert into fx values ('K_lotA', pg_temp.lot_of(pg_temp.stock(v_p, 2, 2000, '2026-01-01 08:00+07'))),
    ('K_lotB', pg_temp.lot_of(pg_temp.stock(v_p, 2, 6000, '2026-01-02 08:00+07')));
  -- Roll 100 m bersegel modal Rp500.000 (produk kabel seed).
  insert into fx values ('ROLL', pg_temp.stock('a2000000-0000-4000-8000-000000000002', 100, 500000,
    '2026-01-01 08:00+07', 'RTR-ROLL-1', 100, true));
end $$;

create function pg_temp.fx(p_k text) returns uuid language sql as $$ select v from fx where k = p_k $$;
create function pg_temp.sell(p_user text, p_items jsonb, p_payment jsonb default null, p_extra jsonb default '{}')
returns uuid language plpgsql as $$
begin
  return (pg_temp.call(p_user, 'finalize_sale_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'items', p_items, 'payment', coalesce(p_payment, jsonb_build_object('method', 'TRANSFER', 'confirmed', true)))
    || p_extra)->>'entity_id')::uuid;
end $$;
create function pg_temp.item_of(p_invoice uuid, p_line integer default 1) returns uuid language sql as $$
  select id from private.invoice_items where invoice_id = p_invoice and line_no = p_line
$$;
create function pg_temp.ret_in(p_invoice uuid, p_items jsonb, p_method text default 'TRANSFER') returns jsonb
language sql as $$
  select jsonb_build_object('operation_id', gen_random_uuid(), 'invoice_id', p_invoice, 'reason', 'Uji retur',
    'items', p_items) || case when p_method is null then '{}'::jsonb else jsonb_build_object('refund_method', p_method) end
$$;
create function pg_temp.ret_line(p_item uuid, p_qty text, p_disp text default 'SALEABLE') returns jsonb language sql as $$
  select jsonb_build_object('invoice_item_id', p_item, 'qty_base', p_qty, 'disposition', p_disp)
$$;
create function pg_temp.net_cogs(p_invoice uuid) returns numeric language sql as $$
  select coalesce(sum(ca.cost_amount - ca.reversed_cost), 0) from private.cost_allocations ca
  join private.invoice_items ii on ii.id = ca.invoice_item_id where ii.invoice_id = p_invoice
$$;
create function pg_temp.lot(p_k text) returns text language sql as $$
  select remaining_qty::text || '/' || remaining_cost::text from private.inventory_lots where id = pg_temp.fx(p_k)
$$;

-- K06: 10 pcs dari lot A (6/60.000) + lot B (4/20.000) diretur penuh → COGS neto 0, tiap lot pulih.
do $$
declare v_inv uuid; v_item uuid; v_res jsonb;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('M_u'), 'qty', '10')));
  v_item := pg_temp.item_of(v_inv);
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 80000.000000::numeric, 'COGS awal 80.000');

  -- Hak akses dan input wajib.
  perform pg_temp.expect_error('staff', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'))), 'FORBIDDEN');
  perform pg_temp.expect_error('disabled', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'))), 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')), null), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'))) - 'reason', 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '0.5'))), 'INVALID_QUANTITY');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '11'))), 'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1', 'HILANG'))), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'))) || '{"refund_amount":"999"}', 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'), pg_temp.ret_line(v_item, '1'))), 'INVALID_INPUT');

  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '10'))));
  perform pg_temp.eq(v_res->>'refund_total', '100000', 'refund penuh');
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 0::numeric, 'K06: COGS neto 0');
  perform pg_temp.eq(pg_temp.lot('M_lotA'), '6.000/60000.000000', 'K06: lot A pulih');
  perform pg_temp.eq(pg_temp.lot('M_lotB'), '4.000/20000.000000', 'K06: lot B pulih');
  perform pg_temp.eq((select string_agg(reversed_qty::text, ',' order by qty_base desc) from private.cost_allocations
    where invoice_item_id = v_item), '6.000,4.000', 'K06: reversed_qty per alokasi tidak melebihi alokasi');
  perform pg_temp.eq((select count(distinct rca.target_position_id) from private.return_cost_allocations rca
    join private.credit_note_items cni on cni.id = rca.credit_item_id
    where cni.credit_note_id = (v_res->>'entity_id')::uuid), 2::bigint, 'K06: posisi baru per alokasi');
  perform pg_temp.eq((select cost_reversal_amount from private.credit_note_items
    where credit_note_id = (v_res->>'entity_id')::uuid), 80000.000000::numeric, 'credit note mencatat pembalikan modal');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('M') and s.location = 'SHOP' and s.condition = 'SALEABLE'), 10.000::numeric, 'stok toko pulih');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1'))), 'REFUND_LIMIT_EXCEEDED');
end $$;

-- AT-13 + BR-08: neto 100 qty 3 diretur 1,1,1 → refund 33,34,33; modal 3.333,333333 / 3.333,333334 / 3.333,333333.
-- Refund tunai: laci belum dibuka → CASH_SESSION_CLOSED; saldo kurang → INSUFFICIENT_CASH.
do $$
declare v_inv uuid; v_item uuid; v_res jsonb; v_in jsonb; v_refunds text := ''; v_costs text := '';
  v_drawer uuid; i integer;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('T_u'), 'qty', '3')));
  v_item := pg_temp.item_of(v_inv);
  perform pg_temp.eq((select total from private.invoices where id = v_inv), 100::numeric, 'neto 100');

  perform pg_temp.expect_error('owner', 'return_sale_v1',
    pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')), 'CASH'), 'CASH_SESSION_CLOSED');
  v_drawer := pg_temp.open_drawer(20);
  perform pg_temp.expect_error('owner', 'return_sale_v1',
    pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')), 'CASH'), 'INSUFFICIENT_CASH');
  insert into private.cash_movements(session_id, direction, kind, amount, actor_id, operation_id)
  values (v_drawer, 'IN', 'OWNER_ADD', 1000, pg_temp.uid('owner'), gen_random_uuid());

  for i in 1..3 loop
    v_in := pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')), 'CASH');
    v_res := pg_temp.call('owner', 'return_sale_v1', v_in);
    v_refunds := v_refunds || (v_res->>'refund_total') || ',';
    v_costs := v_costs || (v_res->'items'->0->>'cost_reversal') || ',';
  end loop;
  perform pg_temp.eq(v_refunds, '33,34,33,', 'AT-13 refund kumulatif');
  perform pg_temp.eq(v_costs, '3333.333333,3333.333334,3333.333333,', 'BR-08 modal kumulatif per alokasi');
  perform pg_temp.eq(pg_temp.drawer_expected(), 920::numeric, 'kas laci: 20 + 1.000 - 100');
  perform pg_temp.eq((select count(*) from private.cash_movements where session_id = v_drawer and kind = 'REFUND'), 3::bigint,
    'mutasi REFUND tercatat');
  perform pg_temp.eq(pg_temp.lot('T_lot'), '3.000/10000.000000', 'lot pulih penuh');
  perform pg_temp.expect_error('owner', 'return_sale_v1',
    pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')), 'CASH'), 'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.eq(pg_temp.call('owner', 'return_sale_v1', v_in), v_res, 'retur idempoten');
  perform pg_temp.eq(pg_temp.drawer_expected(), 920::numeric, 'retry retur tidak mengubah kas');
end $$;

-- Kumulatif lintas alokasi: A(2 pcs/10.000), B(2 pcs/30.000); retur 1, 2, 1.
do $$
declare v_inv uuid; v_item uuid; v_costs text := ''; v_res jsonb; v_q text;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('C_u'), 'qty', '4')));
  v_item := pg_temp.item_of(v_inv);
  foreach v_q in array array['1', '2', '1'] loop
    v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, v_q))));
    v_costs := v_costs || (v_res->'items'->0->>'cost_reversal') || ',';
  end loop;
  perform pg_temp.eq(v_costs, '5000.000000,20000.000000,15000.000000,', 'urutan alokasi asal deterministik');
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 0::numeric, 'COGS neto 0');
  perform pg_temp.eq(pg_temp.lot('C_lotA') || ' ' || pg_temp.lot('C_lotB'), '2.000/10000.000000 2.000/30000.000000', 'lot pulih');
end $$;

-- T07: NONE tidak menambah stok dan tidak membalik COGS; DAMAGED ke posisi rusak dengan modal.
do $$
declare v_inv uuid; v_item uuid; v_res jsonb; v_stock numeric;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('N_u'), 'qty', '4')));
  v_item := pg_temp.item_of(v_inv);
  select sum(s.qty_base) into v_stock from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('N');

  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1', 'NONE'))));
  perform pg_temp.eq(v_res->>'refund_total', '15000', 'NONE tetap refund');
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 20000.000000::numeric, 'NONE: COGS tidak dibalik (4 × 5.000)');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('N')), v_stock, 'NONE: stok tidak bertambah');
  perform pg_temp.eq(pg_temp.lot('N_lot'), '6.000/30000.000000', 'NONE: lot tidak berubah');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(
    pg_temp.ret_line(v_item, '1', 'NONE') || jsonb_build_object('allocations', jsonb_build_array()))), 'INVALID_INPUT');

  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '2', 'DAMAGED'))));
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 10000.000000::numeric, 'DAMAGED: COGS dibalik 2 × 5.000');
  perform pg_temp.eq(pg_temp.lot('N_lot'), '8.000/40000.000000', 'DAMAGED: modal tetap di lot');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('N') and s.condition = 'DAMAGED'), 2.000::numeric, 'DAMAGED: posisi rusak');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('N') and s.condition = 'SALEABLE' and s.location = 'SHOP'), 6.000::numeric,
    'DAMAGED tidak menambah stok jual');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '2'))), 'REFUND_LIMIT_EXCEEDED');
end $$;

-- Pilihan alokasi fisik oleh owner: retur 1 pcs dari lot B (6.000/2) → modal 3.000 kembali ke lot B.
do $$
declare v_inv uuid; v_item uuid; v_res jsonb; v_ca_b uuid;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('K_u'), 'qty', '4')));
  v_item := pg_temp.item_of(v_inv);
  select id into v_ca_b from private.cost_allocations where invoice_item_id = v_item and lot_id = pg_temp.fx('K_lotB');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '3')
    || jsonb_build_object('allocations', jsonb_build_array(jsonb_build_object('cost_allocation_id', v_ca_b, 'qty_base', '3'))))),
    'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '2')
    || jsonb_build_object('allocations', jsonb_build_array(jsonb_build_object('cost_allocation_id', v_ca_b, 'qty_base', '1'))))),
    'INVALID_INPUT');
  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(pg_temp.ret_line(v_item, '1')
    || jsonb_build_object('allocations', jsonb_build_array(jsonb_build_object('cost_allocation_id', v_ca_b, 'qty_base', '1'))))));
  perform pg_temp.eq(v_res->'items'->0->>'cost_reversal', '3000.000000', 'modal dari lot pilihan');
  perform pg_temp.eq(pg_temp.lot('K_lotB') || ' ' || pg_temp.lot('K_lotA'), '1.000/3000.000000 0.000/0.000000', 'hanya lot B pulih');
end $$;

-- T07: nota T=0 dapat diretur tanpa refund dan tanpa metode refund.
do $$
declare v_inv uuid; v_res jsonb;
begin
  v_inv := pg_temp.sell('owner', jsonb_build_array(jsonb_build_object('product_unit_id', pg_temp.fx('N_u'), 'qty', '1',
    'discount_mode', 'percent', 'discount_value', '100')), null, jsonb_build_object('reason', 'Hadiah pelanggan', 'payment', null));
  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(
    pg_temp.ret_line(pg_temp.item_of(v_inv), '1')), null));
  perform pg_temp.eq(v_res->>'refund_total', '0', 'retur nota nol tanpa refund');
  perform pg_temp.eq((select count(*) from private.payments where invoice_id = v_inv), 0::bigint, 'tanpa pembayaran refund');
  perform pg_temp.eq(pg_temp.net_cogs(v_inv), 0::numeric, 'modal nota nol dibalik');
end $$;

-- BR-03: retur potongan roll menjadi posisi baru berlabel, tidak disambung ke roll asal.
do $$
declare v_inv uuid; v_res jsonb; v_pos jsonb;
begin
  v_inv := pg_temp.sell('staff', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002',
    'qty', '5', 'position_id', pg_temp.fx('ROLL'))));
  perform pg_temp.expect_error('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(
    pg_temp.ret_line(pg_temp.item_of(v_inv), '2') || '{"label": "RTR-ROLL-1"}')), 'INVALID_INPUT');
  v_res := pg_temp.call('owner', 'return_sale_v1', pg_temp.ret_in(v_inv, jsonb_build_array(
    pg_temp.ret_line(pg_temp.item_of(v_inv), '2') || '{"label": "RTR-POT-2M"}')));
  v_pos := v_res->'items'->0->'positions'->0;
  perform pg_temp.eq(v_pos->>'label', 'RTR-POT-2M', 'label potongan retur');
  perform pg_temp.eq((select qty_base::text || '/' || segment_capacity::text || '/' || sealed::text || '/' || location
    from private.stock_positions where id = (v_pos->>'position_id')::uuid), '2.000/2.000/false/SHOP', 'posisi retur baru');
  perform pg_temp.eq((select qty_base from private.stock_positions where id = pg_temp.fx('ROLL')), 95.000::numeric,
    'roll asal tidak disambung');
  perform pg_temp.eq(v_res->'items'->0->>'cost_reversal', '10000.000000', 'modal 2 m dari roll Rp500.000');
end $$;

select pg_temp.check_invariants();

rollback;
