-- Uji roll BR-03 (K05) dan AT-04: posisi fisik pilihan kasir, potongan tidak digabung,
-- roll utuh wajib bersegel, modal mengikuti lot posisi yang dipilih.
\set ON_ERROR_STOP on

begin;
\ir sales_helpers.psql

create temp table fx(k text primary key, v uuid) on commit drop;

-- Kabel NYA (seed): satuan m (Rp7.500, langkah 0,1) dan roll 100m (Rp650.000).
do $$
declare c_p constant uuid := 'a2000000-0000-4000-8000-000000000002';
begin
  insert into fx values
    ('P60', pg_temp.stock(c_p, 60, 300000, '2026-01-01 08:00+07', 'UJI-P60', 100, false)),
    ('P40', pg_temp.stock(c_p, 40, 200000, '2026-01-01 09:00+07', 'UJI-P40', 100, false)),
    ('P6', pg_temp.stock(c_p, 6, 60000, '2026-01-02 08:00+07', 'UJI-P6', 100, false)),
    ('P4', pg_temp.stock(c_p, 4, 20000, '2026-01-03 08:00+07', 'UJI-P4', 50, false)),
    ('R100', pg_temp.stock(c_p, 100, 500000, '2026-01-04 08:00+07', 'UJI-R100', 100, true)),
    ('R100B', pg_temp.stock(c_p, 100, 520000, '2026-01-05 08:00+07', 'UJI-R100B', 100, true)),
    ('DMG', pg_temp.stock(c_p, 30, 1, '2025-12-01 08:00+07', 'UJI-DMG', 100, false, 'SHOP', 'DAMAGED')),
    ('FLD', pg_temp.stock(c_p, 30, 1, '2025-12-01 08:00+07', 'UJI-FLD', 100, false, 'FIELD_FATHER', 'SALEABLE'));
  -- Barang bulk untuk uji salah pakai position_id.
  insert into fx values ('LAMPU_POS', pg_temp.stock('a2000000-0000-4000-8000-000000000001', 5, 50000, '2026-01-01 08:00+07'));
end $$;

create function pg_temp.fx(p_k text) returns uuid language sql as $$ select v from fx where k = p_k $$;
create function pg_temp.meter(p_qty text, p_pos text) returns jsonb language sql as $$
  select jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', p_qty,
    'position_id', pg_temp.fx(p_pos))
$$;
create function pg_temp.roll(p_qty text, p_pos text) returns jsonb language sql as $$
  select jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000003', 'qty', p_qty,
    'position_id', pg_temp.fx(p_pos))
$$;
create function pg_temp.sale_in(p_items jsonb) returns jsonb language sql as $$
  select jsonb_build_object('operation_id', gen_random_uuid(), 'items', p_items,
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true))
$$;
create function pg_temp.pos_qty(p_k text) returns numeric language sql as $$
  select qty_base from private.stock_positions where id = pg_temp.fx(p_k)
$$;

-- K05: potongan 60 + 40 tidak dapat dijual sebagai roll 100m; 6 + 4 tidak dapat menjadi satu potongan 10 m.
do $$
begin
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.roll('1', 'P60'))), 'SEGMENT_NOT_SEALED');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.roll('1', 'P60'), pg_temp.roll('1', 'P40'))), 'SEGMENT_NOT_SEALED');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('10', 'P6'))), 'SEGMENT_TOO_SHORT');
  -- Dua baris pada potongan yang sama diagregasi: 4 + 3 > 6.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('4', 'P6'), pg_temp.meter('3', 'P6'))), 'SEGMENT_TOO_SHORT');
  -- Tanpa pilihan posisi.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', pg_temp.sale_in(jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '1'))), 'POSITION_REQUIRED');
  -- Posisi rusak / di lapangan / milik barang lain / versi basi.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('1', 'DMG'))), 'INSUFFICIENT_STOCK');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('1', 'FLD'))), 'INSUFFICIENT_STOCK');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('1', 'LAMPU_POS'))), 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('1', 'P60') || '{"expected_position_version": 9}'::jsonb)),
    'VERSION_CONFLICT');
  -- Barang bulk tidak boleh memilih posisi.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', pg_temp.sale_in(jsonb_build_array(
    jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1',
      'position_id', pg_temp.fx('LAMPU_POS')))), 'INVALID_INPUT');
  -- Roll utuh: satu baris satu roll; roll sama tidak boleh dua baris.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.roll('2', 'R100'))), 'INVALID_QUANTITY');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.roll('1', 'R100'), pg_temp.meter('1', 'R100'))), 'INVALID_INPUT');

  perform pg_temp.eq((select count(*) from private.invoices), 0::bigint, 'K05: tidak ada nota dari penolakan');
  perform pg_temp.eq(pg_temp.pos_qty('P6') + pg_temp.pos_qty('P4') + pg_temp.pos_qty('R100'), 110.000::numeric,
    'K05: stok tidak berubah');
end $$;

-- Dua potongan fisik = dua baris eksplisit; modal mengikuti lot masing-masing.
do $$
declare v_res jsonb; v_inv uuid;
begin
  v_res := pg_temp.call('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('6', 'P6'), pg_temp.meter('4', 'P4'))));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '75000', '10 m × Rp7.500');
  perform pg_temp.eq(pg_temp.pos_qty('P6') + pg_temp.pos_qty('P4'), 0.000::numeric, 'kedua potongan habis');
  perform pg_temp.eq((select string_agg(ii.line_no || ':' || ca.cost_amount::text, ',' order by ii.line_no)
    from private.cost_allocations ca join private.invoice_items ii on ii.id = ca.invoice_item_id
    where ii.invoice_id = v_inv), '1:60000.000000,2:20000.000000', 'modal per lot potongan');
  perform pg_temp.eq(pg_temp.pos_qty('R100'), 100.000::numeric, 'roll bersegel tidak terpotong');
end $$;

-- AT-04: potong 2,5 m dari roll bersegel 100 m modal Rp500.000 → Rp18.750, sisa 97,5, modal keluar Rp12.500, segel terbuka.
do $$
declare v_res jsonb; v_inv uuid; v_ver integer;
begin
  select version into v_ver from private.stock_positions where id = pg_temp.fx('R100');
  v_res := pg_temp.call('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.meter('2.5', 'R100') || jsonb_build_object('expected_position_version', v_ver))));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '18750', 'AT-04 tagihan');
  perform pg_temp.eq(pg_temp.pos_qty('R100'), 97.500::numeric, 'AT-04 sisa 97,5 m');
  perform pg_temp.eq((select sealed from private.stock_positions where id = pg_temp.fx('R100')), false, 'AT-04 segel terbuka');
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 12500.000000::numeric, 'AT-04 modal keluar');
  perform pg_temp.eq(18750 - (select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 6250.000000::numeric, 'AT-04 laba kotor');

  -- Roll yang sudah dipotong tidak bisa dijual sebagai roll utuh.
  perform pg_temp.expect_error('staff', 'finalize_sale_v1',
    pg_temp.sale_in(jsonb_build_array(pg_temp.roll('1', 'R100'))), 'SEGMENT_NOT_SEALED');

  -- Roll utuh dari roll bersegel lain: modal lot roll itu (Rp520.000).
  v_res := pg_temp.call('staff', 'finalize_sale_v1', pg_temp.sale_in(jsonb_build_array(pg_temp.roll('1', 'R100B'))));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '650000', 'harga roll utuh');
  perform pg_temp.eq(pg_temp.pos_qty('R100B'), 0.000::numeric, 'roll utuh keluar');
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 520000.000000::numeric, 'modal roll utuh');
  perform pg_temp.eq((select qty_base from private.invoice_items where invoice_id = v_inv), 100.000::numeric, 'qty dasar roll');
end $$;

-- Keputusan pemilik 18-09-2026: satuan isi > 1 yang bukan roll utuh (mis. "ikat 10m") dipotong dari satu potongan.
do $$
declare v_res jsonb; v_inv uuid;
begin
  insert into private.product_units(id, product_id, label, factor_base, sale_step, sell_price, is_default, whole_roll)
  values ('a1000000-0000-4000-8000-0000000000a1', 'a2000000-0000-4000-8000-000000000002', 'ikat 10m', 10, 1, 70000, false, false);
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', pg_temp.sale_in(jsonb_build_array(jsonb_build_object(
    'product_unit_id', 'a1000000-0000-4000-8000-0000000000a1', 'qty', '5', 'position_id', pg_temp.fx('P40')))),
    'SEGMENT_TOO_SHORT');
  v_res := pg_temp.call('staff', 'finalize_sale_v1', pg_temp.sale_in(jsonb_build_array(jsonb_build_object(
    'product_unit_id', 'a1000000-0000-4000-8000-0000000000a1', 'qty', '2', 'position_id', pg_temp.fx('P60')))));
  v_inv := (v_res->>'entity_id')::uuid;
  perform pg_temp.eq(v_res->>'total', '140000', '2 ikat × Rp70.000');
  perform pg_temp.eq(pg_temp.pos_qty('P60'), 40.000::numeric, 'potong 20 m dari potongan 60 m');
  perform pg_temp.eq((select qty_base from private.invoice_items where invoice_id = v_inv), 20.000::numeric, 'qty dasar 2 × 10 m');
  perform pg_temp.eq((select sum(ca.cost_amount) from private.cost_allocations ca join private.invoice_items ii
    on ii.id = ca.invoice_item_id where ii.invoice_id = v_inv), 100000.000000::numeric, 'modal 20 m × Rp5.000');
  -- Tanda roll utuh diteruskan ke kasir.
  v_res := pg_temp.call('staff', 'get_product_v1', jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002'));
  perform pg_temp.eq((select string_agg(e->>'label' || '=' || (e->>'whole_roll'), ',' order by e->>'label')
    from jsonb_array_elements(v_res->'units') e), 'ikat 10m=false,m=false,roll 100m=true', 'whole_roll per satuan');
end $$;

-- Daftar posisi layak jual untuk UI.
do $$
declare v_res jsonb;
begin
  v_res := pg_temp.call('staff', 'list_sellable_positions_v1',
    jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002'));
  perform pg_temp.eq((select string_agg(e->>'label' || '=' || (e->>'qty_base') || '/' || (e->>'sealed'), ',' order by e->>'label')
    from jsonb_array_elements(v_res->'positions') e), 'UJI-P40=40.000/false,UJI-P60=40.000/false,UJI-R100=97.500/false',
    'hanya SHOP SALEABLE sisa > 0');
  perform pg_temp.assert(v_res->'positions'->0 ? 'version', 'versi posisi tersedia');
  perform pg_temp.assert(v_res::text not ilike '%cost%', 'tanpa modal');
  perform pg_temp.call('maintainer', 'list_sellable_positions_v1',
    jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002'));
  perform pg_temp.expect_error('disabled', 'list_sellable_positions_v1',
    jsonb_build_object('product_id', 'a2000000-0000-4000-8000-000000000002'), 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('staff', 'list_sellable_positions_v1', jsonb_build_object('product_id', 'x'), 'INVALID_INPUT');
end $$;

select pg_temp.check_invariants();

rollback;
