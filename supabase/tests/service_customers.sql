-- Pelanggan (FR-CUS-01, AT-17 tambahan): normalisasi HP, nomor sama tanpa merge, pencarian, kandidat mirip, riwayat.
\set ON_ERROR_STOP on
begin;
\ir service_helpers.psql

do $$
declare v jsonb; v_a uuid; v_b uuid; v_ver int;
begin
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('create_customer_v1', jsonb_build_object('name', 'Tanpa Kontak'), 'CONTACT_REQUIRED');
  perform pg_temp.fail('create_customer_v1', jsonb_build_object('name', 'Salah', 'phone', '08-abc'), 'INVALID_PHONE');
  perform pg_temp.fail('create_customer_v1', jsonb_build_object('name', '', 'phone', '081233334444'), 'INVALID_INPUT');
  perform pg_temp.fail('create_customer_v1', jsonb_build_object('name', 'X', 'phone', '081233334444', 'customer_id', gen_random_uuid()), 'INVALID_INPUT');

  v := pg_temp.call('create_customer_v1', jsonb_build_object('name', 'Budi Hartono', 'phone', '+62 812 3333 4444', 'address', 'Jl. Mawar'));
  v_a := (v->>'customer_id')::uuid;
  perform pg_temp.check(v->>'phone' = '081233334444' and jsonb_array_length(v->'similar_customers') = 0, 'HP ternormalisasi');

  -- Anggota keluarga dengan nomor sama: dibuat terpisah, kandidat ditampilkan, tidak digabung.
  v := pg_temp.call('upsert_customer_v1', jsonb_build_object('name', 'Sri Hartono', 'phone', '0812-3333-4444'));
  v_b := (v->>'customer_id')::uuid;
  perform pg_temp.check(v_a <> v_b and (select count(*) from private.customers where phone_normalized = '081233334444') = 2, 'tanpa auto-merge');
  perform pg_temp.check(v->'similar_customers'->0->>'id' = v_a::text and v->'similar_customers'->0->'match' ? 'PHONE', 'kandidat HP sama');

  v := pg_temp.call('find_similar_customers_v1', jsonb_build_object('name', 'budi'));
  perform pg_temp.check(jsonb_array_length(v->'candidates') = 1 and v->'candidates'->0->>'id' = v_a::text, 'kandidat nama mirip');
  v := pg_temp.call('find_similar_customers_v1', jsonb_build_object('phone', '6281233334444'));
  perform pg_temp.check(jsonb_array_length(v->'candidates') = 2, 'kandidat HP');
  perform pg_temp.fail('find_similar_customers_v1', '{}'::jsonb, 'INVALID_INPUT');

  v := pg_temp.call('search_customers_v1', jsonb_build_object('query', 'harto'));
  perform pg_temp.check(jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 2, 'cari nama mengandung');
  v := pg_temp.call('search_customers_v1', jsonb_build_object('query', '0812 3333'));
  perform pg_temp.check(jsonb_array_length(v) = 2, 'cari HP dari kotak pencarian');
  v := pg_temp.call('search_customers_v1', jsonb_build_object('query', '100%_'));
  perform pg_temp.check(jsonb_array_length(v) = 0, 'wildcard di-escape');

  -- Ubah kontak: expected_version wajib.
  select version into v_ver from private.customers where id = v_a;
  perform pg_temp.fail('upsert_customer_v1', jsonb_build_object('customer_id', v_a, 'name', 'Budi H', 'phone', '081233334444'), 'INVALID_INPUT');
  perform pg_temp.fail('upsert_customer_v1', jsonb_build_object('customer_id', v_a, 'expected_version', v_ver + 1,
    'name', 'Budi H', 'phone', '081233334444'), 'VERSION_CONFLICT');
  v := pg_temp.call('upsert_customer_v1', jsonb_build_object('customer_id', v_a, 'expected_version', v_ver,
    'name', 'Budi Hartono', 'phone', '081299998888', 'alternate_contact', 'Istri 0813'));
  perform pg_temp.check((v->>'version')::int = v_ver + 1 and (select phone_normalized from private.customers where id = v_b) = '081233334444',
    'ubah satu pelanggan tidak mengubah yang lain');

  -- Riwayat pelanggan + tiket memakai pelanggan yang ada.
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object('customer_id', v_a, 'equipment_type', 'Setrika',
    'complaint', 'Tidak panas', 'initial_condition', 'Kabel terkelupas'));
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_id', v_a, 'customer_name', 'Lain',
    'equipment_type', 'Setrika', 'complaint', 'x', 'initial_condition', 'x'), 'INVALID_INPUT');
  v := pg_temp.call('list_customer_history_v1', jsonb_build_object('customer_id', v_a));
  perform pg_temp.check(jsonb_array_length(v->'tickets') = 1 and v->'tickets'->0->>'payment_status' = 'UNPRICED'
    and v->'customer'->>'phone' = '081299998888', 'riwayat pelanggan');

  perform pg_temp.as_user('maint');
  v := pg_temp.call('search_customers_v1', jsonb_build_object('query', 'harto'));
  perform pg_temp.check(jsonb_array_length(v) = 2 and v->0->'phone' = 'null'::jsonb, 'maintainer tanpa kontak');
  perform pg_temp.fail('create_customer_v1', jsonb_build_object('name', 'M', 'phone', '081200000000'), 'FORBIDDEN');
end $$;

rollback;
