-- Uji katalog: K01 (peran), S06 (versi satuan hanya bila harga/opsi berubah, barcode ikut pindah),
-- S04 (kode error, impor divalidasi ulang, SKU duplikat case-insensitive), barcode, kategori.
\set ON_ERROR_STOP on

begin;
\ir sales_helpers.psql

create function pg_temp.product_in(p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('operation_id', gen_random_uuid(), 'sku', 'CAT-001', 'name', 'Stop Kontak 3 Lubang',
    'base_unit', 'pcs', 'quantity_step', '1', 'track_segments', false, 'unit_label', 'pcs',
    'factor_base', '1', 'sale_step', '1', 'sell_price', '25000', 'barcode', '0088001', 'shelf', 'C-01') || p_extra
$$;

-- K01 + validasi.
do $$
begin
  perform pg_temp.expect_error('staff', 'upsert_product_v1', pg_temp.product_in(), 'FORBIDDEN');
  perform pg_temp.expect_error('maintainer', 'upsert_product_v1', pg_temp.product_in(), 'FORBIDDEN');
  perform pg_temp.expect_error('disabled', 'upsert_product_v1', pg_temp.product_in(), 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"harga_modal":"1"}'), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"sell_price":"25.000,00"}'), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"sell_price":"0"}'), 'INVALID_NUMBER');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"sku":"lmp-led-10w"}'), 'DUPLICATE_SKU');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"barcode":"8991234567890"}'), 'DUPLICATE_BARCODE');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"name":""}'), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"operation_id":"abc"}'), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in('{"sale_step":"0.5"}'), 'INVALID_QUANTITY');
  perform pg_temp.eq((select count(*) from private.products where sku = 'CAT-001'), 0::bigint, 'tidak ada produk dari penolakan');
end $$;

-- S06: ubah nama/rak tidak menyentuh satuan; ubah harga membuat versi satuan baru & barcode ikut pindah.
do $$
declare v_in jsonb; v_res jsonb; v_res2 jsonb; v_pid uuid; v_unit1 uuid; v_unit2 uuid; v_ver integer; v_op jsonb;
begin
  v_in := pg_temp.product_in();
  v_res := pg_temp.call('owner', 'upsert_product_v1', v_in);
  v_pid := (v_res->>'entity_id')::uuid;
  v_unit1 := (v_res->>'unit_id')::uuid;
  perform pg_temp.eq(pg_temp.call('owner', 'upsert_product_v1', v_in), v_res, 'upsert idempoten');
  v_op := pg_temp.call('owner', 'get_operation_v1', jsonb_build_object('command', 'upsert_product_v1', 'operation_id', v_in->>'operation_id'));
  perform pg_temp.eq((v_op->>'found')::boolean, true, 'get_operation_v1 upsert_product_v1');

  -- Rename + rak, barcode yang sama dikirim ulang (bukan duplikat).
  v_res2 := pg_temp.call('owner', 'upsert_product_v1', pg_temp.product_in(jsonb_build_object('product_id', v_pid,
    'expected_version', (v_res->>'version')::integer, 'name', 'Stop Kontak 3 Lubang Putih', 'shelf', 'C-02')));
  perform pg_temp.eq((v_res2->>'unit_id')::uuid, v_unit1, 'S06: satuan tetap saat hanya nama/rak berubah');
  perform pg_temp.eq((v_res2->>'unit_changed')::boolean, false, 'S06: unit_changed=false');
  perform pg_temp.eq((select active from private.product_units where id = v_unit1), true, 'S06: satuan lama tetap aktif');
  perform pg_temp.eq((select count(*) from private.product_barcodes where product_id = v_pid), 1::bigint, 'barcode tidak diduplikasi');

  -- Keranjang dengan versi satuan lama tetap sah setelah rename.
  perform pg_temp.stock(v_pid, 5, 50000, '2026-01-01 08:00+07');
  perform pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', v_unit1, 'qty', '1', 'expected_unit_version', 1)),
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));

  -- Ubah harga.
  select version into v_ver from private.products where id = v_pid;
  v_res2 := pg_temp.call('owner', 'upsert_product_v1', pg_temp.product_in(jsonb_build_object('product_id', v_pid,
    'expected_version', v_ver, 'name', 'Stop Kontak 3 Lubang Putih', 'shelf', 'C-02', 'sell_price', '27500',
    'reason', 'Harga distributor naik')));
  v_unit2 := (v_res2->>'unit_id')::uuid;
  perform pg_temp.assert(v_unit2 <> v_unit1, 'S06: harga berubah → satuan versi baru');
  perform pg_temp.eq((v_res2->>'unit_version')::integer, 2, 'versi satuan naik');
  perform pg_temp.eq((select active from private.product_units where id = v_unit1), false, 'satuan lama nonaktif');
  perform pg_temp.eq((select product_unit_id from private.product_barcodes where code = '0088001'), v_unit2, 'barcode pindah ke satuan baru');
  perform pg_temp.eq((select before_price::text || '>' || after_price::text from private.product_price_history
    where unit_id = v_unit2), '25000.000000>27500.000000', 'riwayat harga');
  perform pg_temp.eq(pg_temp.call('staff', 'find_by_barcode_v1', '{"code":"0088001"}')->>'sell_price', '27500.000000', 'scan harga baru');
  perform pg_temp.expect_error('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', v_unit1, 'qty', '1')),
    'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)), 'PRICE_CHANGED');

  -- Konflik versi, barcode milik barang lain, ubah pelacakan roll.
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in(jsonb_build_object('product_id', v_pid,
    'expected_version', v_ver)), 'VERSION_CONFLICT');
  select version into v_ver from private.products where id = v_pid;
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in(jsonb_build_object('product_id', v_pid,
    'expected_version', v_ver, 'sell_price', '27500', 'barcode', '0012345678901')), 'DUPLICATE_BARCODE');
  perform pg_temp.expect_error('owner', 'upsert_product_v1', pg_temp.product_in(jsonb_build_object('product_id', v_pid,
    'expected_version', v_ver, 'track_segments', true)), 'INVALID_INPUT');

  -- Arsip.
  perform pg_temp.expect_error('staff', 'archive_product_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', v_pid, 'expected_version', v_ver), 'FORBIDDEN');
  perform pg_temp.call('owner', 'archive_product_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', v_pid, 'expected_version', v_ver));
  perform pg_temp.expect_error('owner', 'archive_product_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', v_pid, 'expected_version', v_ver), 'VERSION_CONFLICT');
  perform pg_temp.eq(jsonb_array_length(pg_temp.call('staff', 'search_products_v1', '{"query":"stop kontak"}')), 0, 'arsip hilang dari pencarian');
end $$;

-- Baca katalog: peran, modal hanya owner/maintainer.
do $$
declare v_res jsonb;
begin
  v_res := pg_temp.call('maintainer', 'search_products_v1', '{"query":"0012345678901"}');
  perform pg_temp.eq(v_res->0->>'sku', 'KBL-NYA-1.5', 'barcode nol depan cocok (maintainer boleh baca)');
  perform pg_temp.expect_error('disabled', 'search_products_v1', '{}', 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('staff', 'search_products_v1', '{"limit":"banyak"}', 'INVALID_INPUT');
  perform pg_temp.stock('a2000000-0000-4000-8000-000000000001', 3, 30000, '2026-01-01 08:00+07');
  v_res := pg_temp.call('staff', 'get_product_v1', '{"product_id":"a2000000-0000-4000-8000-000000000001"}');
  perform pg_temp.assert(not (v_res ? 'lots') and v_res::text not ilike '%cost%', 'STAFF tanpa modal');
  v_res := pg_temp.call('owner', 'get_product_v1', '{"product_id":"a2000000-0000-4000-8000-000000000001"}');
  perform pg_temp.eq(v_res->'lots'->0->>'remaining_cost', '30000.000000', 'owner melihat modal');
  perform pg_temp.expect_error('disabled', 'get_product_v1', '{"product_id":"a2000000-0000-4000-8000-000000000001"}', 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('staff', 'get_product_v1', '{"product_id":"x"}', 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'get_product_v1', jsonb_build_object('product_id', gen_random_uuid()), 'NOT_FOUND');
  perform pg_temp.expect_error('disabled', 'find_by_barcode_v1', '{"code":"8991234567890"}', 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('disabled', 'list_product_barcodes_v1', '{"product_id":"a2000000-0000-4000-8000-000000000001"}', 'ACCOUNT_INACTIVE');
end $$;

-- Barcode.
do $$
declare v_old_unit uuid;
begin
  perform pg_temp.expect_error('staff', 'add_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', 'a2000000-0000-4000-8000-000000000001', 'code', '777'), 'FORBIDDEN');
  v_old_unit := pg_temp.unit('a2000000-0000-4000-8000-000000000001', 'lama', 1, 1, 1, false);
  update private.product_units set active = false where id = v_old_unit;
  perform pg_temp.expect_error('owner', 'add_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', 'a2000000-0000-4000-8000-000000000001', 'product_unit_id', v_old_unit, 'code', '777'), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'add_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', 'a2000000-0000-4000-8000-000000000002', 'code', '8991234567890'), 'DUPLICATE_BARCODE');
  perform pg_temp.expect_error('owner', 'add_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'product_id', 'a2000000-0000-4000-8000-000000000001', 'code', '   '), 'INVALID_INPUT');
  perform pg_temp.expect_error('owner', 'remove_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'code', 'TIDAK-ADA'), 'NOT_FOUND');
  perform pg_temp.expect_error('staff', 'remove_product_barcode_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'code', '8991234567890'), 'FORBIDDEN');
end $$;

-- S04: impor katalog. SKU duplikat dalam batch beda huruf ditolak; commit memvalidasi ulang.
do $$
declare v_rows jsonb; v_res jsonb; v_before bigint;
begin
  v_rows := jsonb_build_array(
    jsonb_build_object('sku', 'IMP-ABC', 'name', 'Impor A', 'base_unit', 'pcs', 'quantity_step', '1', 'unit_label', 'pcs',
      'factor_base', '1', 'sale_step', '1', 'sell_price', '1000', 'barcode', '5501'),
    jsonb_build_object('sku', 'imp-abc', 'name', 'Impor B', 'base_unit', 'pcs', 'quantity_step', '1', 'unit_label', 'pcs',
      'factor_base', '1', 'sale_step', '1', 'sell_price', '1000'),
    jsonb_build_object('sku', 'IMP-C', 'name', 'Impor C', 'base_unit', 'pcs', 'quantity_step', '1', 'unit_label', 'pcs',
      'factor_base', '1', 'sale_step', '1', 'sell_price', 'NaN', 'barcode', '5501'));
  perform pg_temp.expect_error('staff', 'preview_catalog_import_v1', jsonb_build_object('rows', v_rows), 'FORBIDDEN');
  v_res := pg_temp.call('owner', 'preview_catalog_import_v1', jsonb_build_object('rows', v_rows));
  perform pg_temp.eq((v_res->>'ok')::boolean, false, 'preview menolak');
  perform pg_temp.eq((select string_agg((e->>'line') || ':' || (e->>'code'), ',' order by e->>'line', e->>'code')
    from jsonb_array_elements(v_res->'errors') e), '2:DUPLICATE_SKU,3:DUPLICATE_BARCODE,3:INVALID_PRICE', 'daftar error impor');
  perform pg_temp.eq(v_res->>'valid', '1', 'baris valid');

  select count(*) into v_before from private.products;
  perform pg_temp.expect_error('owner', 'commit_catalog_import_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'rows', v_rows, 'import_hash', 'h1'), 'INVALID_INPUT');
  perform pg_temp.eq((select count(*) from private.products), v_before, 'commit tidak percaya preview');

  v_res := pg_temp.call('owner', 'commit_catalog_import_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'rows', jsonb_build_array(v_rows->0), 'import_hash', 'h2'));
  perform pg_temp.eq(v_res->>'count', '1', 'impor valid');
  perform pg_temp.eq(pg_temp.call('staff', 'find_by_barcode_v1', '{"code":"5501"}')->>'sku', 'IMP-ABC', 'barcode impor');
  -- Impor ulang SKU yang sudah ada (beda huruf) ditolak.
  perform pg_temp.expect_error('owner', 'commit_catalog_import_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'rows', jsonb_build_array(v_rows->1), 'import_hash', 'h3'), 'INVALID_INPUT');
end $$;

-- Kategori.
do $$
declare v_a uuid; v_b uuid;
begin
  perform pg_temp.expect_error('staff', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(), 'name', 'Lampu'), 'FORBIDDEN');
  v_a := (pg_temp.call('owner', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(), 'name', 'Lampu'))->>'entity_id')::uuid;
  v_b := (pg_temp.call('owner', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(), 'name', 'Kabel'))->>'entity_id')::uuid;
  perform pg_temp.eq((pg_temp.call('owner', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'name', 'lampu'))->>'entity_id')::uuid, v_a, 'nama sama beda huruf memakai kategori yang ada');
  perform pg_temp.expect_error('owner', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'category_id', v_b, 'name', 'LAMPU'), 'DUPLICATE_NAME');
  perform pg_temp.expect_error('owner', 'upsert_category_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'category_id', gen_random_uuid(), 'name', 'Baru'), 'NOT_FOUND');
  perform pg_temp.act('staff');
  perform pg_temp.eq(jsonb_array_length(public.list_categories_v1()), 2, 'staff melihat kategori');
  perform pg_temp.act('disabled');
  begin
    perform public.list_categories_v1();
    raise exception 'UJI GAGAL: akun nonaktif dapat membaca kategori';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
