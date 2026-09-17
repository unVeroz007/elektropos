-- Uji penjualan: K01, K02, K04, S01 (BR-04), BR-05 FIFO, S09, idempotensi, PRICE_CHANGED.
-- Nilai harapan dihitung dari aturan bisnis (docs/02-BUSINESS-RULES.md), bukan dari implementasi.
\set ON_ERROR_STOP on

begin;
\ir sales_helpers.psql

create temp table fx(k text primary key, v uuid) on commit drop;

do $$
declare v_p uuid;
begin
  -- Barang bulk pcs harga 10.001, 100, 3,4, 0,4.
  v_p := pg_temp.product('S-A', 'pcs', 1, false);
  insert into fx values ('A', v_p), ('A_u', pg_temp.unit(v_p, 'pcs', 1, 1, 10001));
  perform pg_temp.stock(v_p, 50, 500000, '2026-01-01 08:00+07');

  v_p := pg_temp.product('S-B', 'pcs', 1, false);
  insert into fx values ('B', v_p), ('B_u', pg_temp.unit(v_p, 'pcs', 1, 1, 100));
  perform pg_temp.stock(v_p, 50, 2500, '2026-01-01 08:00+07');

  v_p := pg_temp.product('S-C', 'pcs', 1, false);
  insert into fx values ('C', v_p), ('C_u', pg_temp.unit(v_p, 'pcs', 1, 1, 3.4));
  perform pg_temp.stock(v_p, 10, 10, '2026-01-01 08:00+07');

  v_p := pg_temp.product('S-Z', 'pcs', 1, false);
  insert into fx values ('Z', v_p), ('Z_u', pg_temp.unit(v_p, 'pcs', 1, 1, 0.4));
  perform pg_temp.stock(v_p, 10, 1, '2026-01-01 08:00+07');

  -- Barang 20 stok untuk K04, satuan pcs dan dus isi 10.
  v_p := pg_temp.product('S-K04', 'pcs', 1, false);
  insert into fx values ('K', v_p), ('K_pcs', pg_temp.unit(v_p, 'pcs', 1, 1, 1000)),
    ('K_dus', pg_temp.unit(v_p, 'dus', 10, 1, 9000, false));
  perform pg_temp.stock(v_p, 20, 20000, '2026-01-01 08:00+07');

  -- FIFO AT-14: lot1 2 pcs Rp20.000, lot2 2 pcs Rp30.000; lot lama DAMAGED/FIELD tidak boleh dipakai.
  v_p := pg_temp.product('S-FIFO', 'pcs', 1, false);
  insert into fx values ('F', v_p), ('F_u', pg_temp.unit(v_p, 'pcs', 1, 1, 20000));
  perform pg_temp.stock(v_p, 5, 1000, '2025-12-01 08:00+07', p_condition => 'DAMAGED');
  perform pg_temp.stock(v_p, 5, 1000, '2025-12-02 08:00+07', p_location => 'FIELD_FATHER');
  insert into fx values ('F_lot1', pg_temp.lot_of(pg_temp.stock(v_p, 2, 20000, '2026-01-01 08:00+07')));
  insert into fx values ('F_lot2', pg_temp.lot_of(pg_temp.stock(v_p, 2, 30000, '2026-01-02 08:00+07')));

  -- Modal pecahan: 3 pcs Rp10.000.
  v_p := pg_temp.product('S-THIRD', 'pcs', 1, false);
  insert into fx values ('T', v_p), ('T_u', pg_temp.unit(v_p, 'pcs', 1, 1, 5000));
  insert into fx values ('T_lot', pg_temp.lot_of(pg_temp.stock(v_p, 3, 10000, '2026-01-01 08:00+07')));
end $$;

create function pg_temp.fx(p_k text) returns uuid language sql as $$ select v from fx where k = p_k $$;
create function pg_temp.line(p_unit text, p_qty text) returns jsonb language sql as $$
  select jsonb_build_object('product_unit_id', pg_temp.fx(p_unit), 'qty', p_qty)
$$;
create function pg_temp.transfer() returns jsonb language sql as $$
  select jsonb_build_object('method', 'TRANSFER', 'confirmed', true)
$$;

-- K01: akun nonaktif & MAINTAINER tidak boleh menjual; tanpa efek.
do $$
declare v_in jsonb;
begin
  v_in := jsonb_build_object('operation_id', pg_temp.op(), 'items', jsonb_build_array(pg_temp.line('B_u', '1')),
    'payment', pg_temp.transfer());
  perform pg_temp.expect_error('disabled', 'finalize_sale_v1', v_in, 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('maintainer', 'finalize_sale_v1', v_in, 'FORBIDDEN');
  perform pg_temp.expect_error('maintainer', 'preview_sale_v1', v_in, 'FORBIDDEN');
  perform pg_temp.eq((select count(*) from private.invoices), 0::bigint, 'K01: tidak ada nota tercipta');
end $$;

-- K02: STAFF mengirim diskon apa pun ditolak; nota nol hanya owner dengan alasan.
do $$
declare v_line jsonb;
begin
  v_line := pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '100');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(v_line), 'payment', pg_temp.transfer()), 'FORBIDDEN');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('B_u', '1')), 'discount_mode', 'percent', 'discount_value', '100',
    'payment', pg_temp.transfer()), 'FORBIDDEN');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('B_u', '1')), 'discount_mode', 'amount', 'discount_value', '0',
    'payment', pg_temp.transfer()), 'FORBIDDEN');
  perform pg_temp.expect_error('staff', 'preview_sale_v1', jsonb_build_object(
    'items', jsonb_build_array(v_line)), 'FORBIDDEN');

  -- Diskon 100% oleh owner tanpa alasan ditolak.
  perform pg_temp.expect_error('owner', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(v_line)), 'APPROVAL_REQUIRED');
  -- Harga kecil membuat B=0 walau tanpa diskon (0,4 → 0): staff tetap tidak boleh membuat nota nol.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('Z_u', '1')), 'payment', pg_temp.transfer()), 'APPROVAL_REQUIRED');
  perform pg_temp.eq((select count(*) from private.invoices), 0::bigint, 'K02: tidak ada nota tercipta');
end $$;

-- K02: nota nol sah oleh owner dengan alasan: tanpa receipt, stok & modal tetap tercatat.
do $$
declare v_res jsonb; v_inv uuid;
begin
  v_res := pg_temp.call('owner', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'reason', 'Garansi tukar dari owner',
    'items', jsonb_build_array(pg_temp.line('B_u', '2') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '100'))));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '0', 'nota nol total 0');
  perform pg_temp.eq((select count(*) from private.payments where invoice_id = v_inv), 0::bigint, 'nota nol tanpa receipt');
  perform pg_temp.eq((select free_reason from private.invoices where id = v_inv), 'Garansi tukar dari owner', 'alasan tersimpan');
  -- Modal 2 dari lot 50 pcs Rp2.500 = 100.
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca
    join private.invoice_items ii on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 100.000000::numeric,
    'nota nol tetap mengakui modal');
end $$;

-- S01/BR-04 vektor emas (AT-07).
do $$
declare v_res jsonb; v_inv uuid;
begin
  -- Rp10.001 diskon 10% -> D=1.000,1 -> B=round(9.000,9)=9.001.
  v_res := pg_temp.call('owner', 'preview_sale_v1', jsonb_build_object(
    'items', jsonb_build_array(pg_temp.line('A_u', '1') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '10'))));
  perform pg_temp.eq(v_res->'items'->0->>'base_net', '9001', 'AT-07 baris 10.001 diskon 10%');
  perform pg_temp.eq(v_res->>'total', '9001', 'AT-07 total preview');

  -- G eksak: 3,4 diskon 50% -> 1,7 -> 2 (pembulatan G dulu akan menghasilkan 1).
  v_res := pg_temp.call('owner', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('C_u', '1') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '50')),
    'payment', pg_temp.transfer()));
  perform pg_temp.eq(v_res->>'total', '2', 'S01: G tidak dibulatkan sebelum diskon');
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq((select gross_exact from private.invoice_items where invoice_id = v_inv), 3.4::numeric, 'gross_exact eksak');
  perform pg_temp.eq((select item_discount_exact from private.invoice_items where invoice_id = v_inv), 1.7::numeric, 'diskon eksak');

  -- Tiga baris Rp100, diskon nota Rp1 -> alokasi [1,0,0], neto [99,100,100], total 299.
  v_res := pg_temp.call('owner', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('B_u', '1'), pg_temp.line('B_u', '1'), pg_temp.line('B_u', '1')),
    'discount_mode', 'amount', 'discount_value', '1', 'payment', pg_temp.transfer()));
  perform pg_temp.eq(v_res->>'total', '299', 'AT-07 total 299');
  perform pg_temp.eq((select string_agg(invoice_discount_alloc::text || '/' || net_total::text, ',' order by line_no)
    from private.invoice_items where invoice_id = (v_res->>'entity_id')::uuid), '1/99,0/100,0/100', 'AT-07 alokasi largest remainder');

  -- Diskon nota 12,5% dari S=10.001+100+100=10.201 -> round(1.275,125)=1.275; alokasi floor(1275×B/10201).
  -- floor: 10001→1250 (rem 25), 100→12 (rem 5088), 100→12 (rem 5088); sisa 1 → line 2 (rem terbesar, seri line_no).
  v_res := pg_temp.call('owner', 'preview_sale_v1', jsonb_build_object(
    'items', jsonb_build_array(pg_temp.line('A_u', '1'), pg_temp.line('B_u', '1'), pg_temp.line('B_u', '1')),
    'discount_mode', 'percent', 'discount_value', '12.5'));
  perform pg_temp.eq(v_res->>'discount', '1275', 'diskon nota persen');
  perform pg_temp.eq(v_res->>'total', '8926', 'total setelah diskon persen');
  perform pg_temp.eq((select string_agg(e->>'invoice_discount_alloc', ',' order by (e->>'line_no')::int)
    from jsonb_array_elements(v_res->'items') e), '1250,13,12', 'alokasi diskon persen');

  -- Validasi diskon.
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'amount', 'discount_value', '101'))), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '100.0001'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'percent', 'discount_value', '1,5'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'amount', 'discount_value', 'NaN'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'amount', 'discount_value', '-1'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'amount', 'discount_value', 5))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1')), 'discount_mode', 'amount', 'discount_value', '101'), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || jsonb_build_object('discount_mode', 'gratis', 'discount_value', '1'))), 'INVALID_INPUT');
  -- Qty curang.
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1.5'))), 'INVALID_QUANTITY');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', 'Infinity'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '0'))), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'preview_sale_v1', jsonb_build_object('items', jsonb_build_array(
    pg_temp.line('B_u', '1') || '{"harga":"1"}'::jsonb)), 'INVALID_INPUT');
end $$;

-- K04: dua baris satuan sama melebihi stok (20: 15+15) ditolak tanpa efek.
do $$
declare v_res jsonb; v_inv uuid;
begin
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('K_pcs', '15'), pg_temp.line('K_pcs', '15')),
    'payment', pg_temp.transfer()), 'INSUFFICIENT_STOCK');
  -- Satuan berbeda produk sama: 2 dus (20) + 1 pcs = 21 > 20.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('K_dus', '2'), pg_temp.line('K_pcs', '1')),
    'payment', pg_temp.transfer()), 'INSUFFICIENT_STOCK');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('K')), 20.000::numeric, 'K04: stok utuh setelah penolakan');

  -- 1 dus + 10 pcs = 20 pas.
  v_res := pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('K_dus', '1'), pg_temp.line('K_pcs', '10')),
    'payment', pg_temp.transfer()));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '19000', 'K04: 9.000 + 10×1.000');
  perform pg_temp.eq((select sum(s.qty_base) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('K')), 0.000::numeric, 'K04: stok habis');
  perform pg_temp.eq((select sum(ca.qty_base) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 20.000::numeric, 'K04: alokasi = qty nota');
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 20000.000000::numeric, 'K04: modal penuh');
end $$;

-- BR-05 FIFO AT-14 + modal pecahan kumulatif.
do $$
declare v_res jsonb; v_inv uuid;
begin
  v_res := pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('F_u', '3')), 'payment', pg_temp.transfer()));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 35000.000000::numeric, 'AT-14 COGS 35.000');
  perform pg_temp.eq((select remaining_qty::text || '/' || remaining_cost::text from private.inventory_lots
    where id = pg_temp.fx('F_lot2')), '1.000/15000.000000', 'AT-14 sisa lot2 1 pcs Rp15.000');
  perform pg_temp.eq((select remaining_qty from private.inventory_lots where id = pg_temp.fx('F_lot1')), 0.000::numeric, 'lot1 habis');
  perform pg_temp.eq((select count(*) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = pg_temp.fx('F') and s.qty_base = 5), 2::bigint, 'posisi DAMAGED/FIELD tidak tersentuh');
  -- Sisa toko 1; jual 2 ditolak walau DAMAGED/FIELD ada 10.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('F_u', '2')), 'payment', pg_temp.transfer()), 'INSUFFICIENT_STOCK');

  -- 3 pcs Rp10.000 dijual satu-satu: 3.333,333333 ; 3.333,333334 ; 3.333,333333.
  perform pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('T_u', '1')), 'payment', pg_temp.transfer()));
  perform pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('T_u', '1')), 'payment', pg_temp.transfer()));
  perform pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('T_u', '1')), 'payment', pg_temp.transfer()));
  perform pg_temp.eq((select string_agg(cost_amount::text, ',' order by cost_amount, id) from private.cost_allocations
    where lot_id = pg_temp.fx('T_lot')), '3333.333333,3333.333333,3333.333334', 'BR-05 modal proporsional half-up');
  perform pg_temp.eq((select remaining_cost from private.inventory_lots where id = pg_temp.fx('T_lot')), 0::numeric, 'lot habis modal 0');
end $$;

-- S09: pembayaran.
do $$
declare v_items jsonb := jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1'));
  v_res jsonb; v_inv uuid; v_before numeric;
begin
  perform pg_temp.stock('a2000000-0000-4000-8000-000000000001', 10, 100000, '2026-01-01 08:00+07');
  -- Laci belum dibuka.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH', 'tendered', '20000')), 'CASH_SESSION_CLOSED');
  perform pg_temp.open_drawer(100000);
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH')), 'INVALID_NUMBER');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH', 'tendered', '14999')), 'INSUFFICIENT_PAYMENT');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH', 'tendered', '20.000')), 'INVALID_NUMBER');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH', 'tendered', '20000',
      'cash_session_id', gen_random_uuid())), 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'TRANSFER')), 'PAYMENT_NOT_CONFIRMED');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'QRIS', 'confirmed', 'true')), 'PAYMENT_NOT_CONFIRMED');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CARD', 'confirmed', true)), 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items), 'INVALID_INPUT');
  perform pg_temp.eq(pg_temp.drawer_expected(), 100000::numeric, 'kas tidak berubah oleh penolakan');

  -- AT-09 tunai: total 15.000, bayar 20.000, kembali 5.000; receipt & kas masuk = total.
  v_res := pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'CASH', 'tendered', '20000')));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'change', '5000', 'kembalian dihitung server');
  perform pg_temp.eq((select amount::text || '/' || tendered::text || '/' || change::text from private.payments
    where invoice_id = v_inv), '15000/20000/5000', 'receipt tunai');
  perform pg_temp.eq(pg_temp.drawer_expected(), 115000::numeric, 'kas laci naik sebesar total, bukan tendered');

  -- Non-tunai tidak mengubah laci.
  v_before := pg_temp.drawer_expected();
  perform pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', v_items, 'payment', jsonb_build_object('method', 'QRIS', 'confirmed', true, 'reference', 'QR-123')));
  perform pg_temp.eq(pg_temp.drawer_expected(), v_before, 'QRIS tidak mengubah laci');
end $$;

-- Idempotensi + get_operation_v1 + client_reference_id + PRICE_CHANGED.
do $$
declare v_in jsonb; v_res1 jsonb; v_res2 jsonb; v_op jsonb; v_count bigint; v_ref uuid := gen_random_uuid();
  v_unit uuid;
begin
  v_in := jsonb_build_object('operation_id', pg_temp.op(), 'client_reference_id', v_ref,
    'items', jsonb_build_array(pg_temp.line('B_u', '1')), 'payment', pg_temp.transfer());
  v_res1 := pg_temp.call('staff', 'finalize_sale_v1', v_in);
  select count(*) into v_count from private.invoices;
  v_res2 := pg_temp.call('staff', 'finalize_sale_v1', v_in);
  perform pg_temp.eq(v_res2, v_res1, 'retry payload sama = hasil sama');
  perform pg_temp.eq((select count(*) from private.invoices), v_count, 'retry tidak membuat nota baru');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_set(v_in, '{items,0,qty}', '"2"'), 'IDEMPOTENCY_CONFLICT');
  -- Operation id baru untuk keranjang yang sama ditolak.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_set(v_in, '{operation_id}', to_jsonb(pg_temp.op())),
    'ALREADY_FINALIZED');

  v_op := pg_temp.call('staff', 'get_operation_v1', jsonb_build_object('command', 'finalize_sale_v1',
    'operation_id', v_in->>'operation_id'));
  perform pg_temp.eq((v_op->>'found')::boolean, true, 'get_operation_v1 menemukan operasi');
  perform pg_temp.eq(v_op->'result'->>'entity_id', v_res1->>'entity_id', 'get_operation_v1 hasil sama');
  -- Operasi milik aktor lain tidak terlihat.
  v_op := pg_temp.call('owner', 'get_operation_v1', jsonb_build_object('command', 'finalize_sale_v1',
    'operation_id', v_in->>'operation_id'));
  perform pg_temp.eq((v_op->>'found')::boolean, false, 'operasi aktor lain tidak terlihat');

  -- PRICE_CHANGED: versi berbeda & satuan nonaktif.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('B_u', '1') || '{"expected_unit_version": 99}'::jsonb),
    'payment', pg_temp.transfer()), 'PRICE_CHANGED');
  update private.product_units set active = false, is_default = false where id = pg_temp.fx('B_u');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('B_u', '1')), 'payment', pg_temp.transfer()), 'PRICE_CHANGED');
  -- Produk diarsip.
  update private.products set active = false where id = pg_temp.fx('A');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', pg_temp.op(),
    'items', jsonb_build_array(pg_temp.line('A_u', '1')), 'payment', pg_temp.transfer()), 'NOT_FOUND');
end $$;

-- Hak eksekusi: anon tidak dapat memanggil.
do $$
begin
  perform set_config('role', 'anon', true);
  begin
    perform public.finalize_sale_v1('{}'::jsonb);
    raise exception 'UJI GAGAL: anon dapat memanggil finalize_sale_v1';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
end $$;

select pg_temp.check_invariants();

rollback;
