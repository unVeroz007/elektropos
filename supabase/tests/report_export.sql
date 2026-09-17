-- S03/SEC-04: export_csv_v1 — pagination sebelum agregasi, urutan stabil, has_more,
-- cursor, filter tanggal WIB, netralisasi formula (termasuk tab/CR), escape CSV, peran.
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
create function pg_temp.inv(p_number text, p_at timestamptz, p_total numeric, p_customer uuid default null)
returns uuid language sql as $$
  insert into private.invoices(number, kind, customer_id, actor_id, posted_at, subtotal_net_lines, discount_total, total, operation_id)
  values (p_number, 'SALE', p_customer, '11111111-1111-4111-8111-111111111111', p_at, p_total, 0, p_total, gen_random_uuid())
  returning id
$$;
create function pg_temp.export(p jsonb) returns jsonb language sql as $$
  select public.export_csv_v1(jsonb_build_object('dataset', 'invoices', 'start_date', '2026-08-10', 'end_date', '2026-08-10') || p)
$$;

do $$
declare v_c1 uuid; v_c2 uuid; v_inv uuid; v_rcpt uuid;
begin
  insert into private.customers(name) values (E'\t=1+1') returning id into v_c1;
  insert into private.customers(name) values ('Budi, "Toko" Jaya') returning id into v_c2;
  v_inv := pg_temp.inv('X-1', '2026-08-10 00:00+07', 1000, v_c1);
  v_rcpt := null;
  insert into private.payments(direction, purpose, invoice_id, method, amount, actor_id, occurred_at, operation_id)
    values ('IN', 'SALE_RECEIPT', v_inv, 'CASH', 1000, '11111111-1111-4111-8111-111111111111', '2026-08-10 00:00+07', gen_random_uuid())
    returning id into v_rcpt;
  -- Koreksi metode: CASH -> TRANSFER; kolom metode menampilkan metode berlaku.
  insert into private.payments(direction, purpose, invoice_id, original_payment_id, method, amount, actor_id, occurred_at, operation_id)
    values ('OUT', 'PAYMENT_REVERSAL', v_inv, v_rcpt, 'CASH', 1000, '11111111-1111-4111-8111-111111111111', now(), gen_random_uuid()),
           ('IN', 'PAYMENT_REPLACEMENT', v_inv, v_rcpt, 'TRANSFER', 1000, '11111111-1111-4111-8111-111111111111', now(), gen_random_uuid());
  perform pg_temp.inv('X-2', '2026-08-10 09:00+07', 2000, v_c2);
  -- Dua nota dengan waktu sama: urutan ditentukan id.
  perform pg_temp.inv('X-3', '2026-08-10 12:00+07', 3000);
  perform pg_temp.inv('X-4', '2026-08-10 12:00+07', 4000);
  perform pg_temp.inv('X-5', '2026-08-10 23:59:59+07', 5000);
  perform pg_temp.inv('X-OUT', '2026-08-11 00:00+07', 6000);
  perform pg_temp.inv('X-OUT2', '2026-08-09 23:59:59+07', 7000);
end $$;

-- Offset: bug lama limit diabaikan dan offset>0 kosong.
do $$
declare v1 jsonb; v2 jsonb; v3 jsonb; v_all text[]; v_expected text[];
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  select array_agg(number order by posted_at, id) into v_expected from private.invoices
    where number in ('X-1', 'X-2', 'X-3', 'X-4', 'X-5');
  v1 := pg_temp.export('{"limit": 2}');
  v2 := pg_temp.export('{"limit": 2, "offset": 2}');
  v3 := pg_temp.export('{"limit": 2, "offset": 4}');
  if (v1->>'count')::integer <> 2 or not (v1->>'has_more')::boolean or (v1->>'next_offset')::integer <> 2
     or (v2->>'count')::integer <> 2 or not (v2->>'has_more')::boolean
     or (v3->>'count')::integer <> 1 or (v3->>'has_more')::boolean or v3->'next_offset' <> 'null'::jsonb then
    raise exception 'Export offset salah: % | % | %', v1->>'count', v2->>'count', v3->>'count';
  end if;
  select array_agg(e->>'number' order by p, n) into v_all from (
    select 1 p, * from jsonb_array_elements(v1->'rows') with ordinality t(e, n)
    union all select 2, * from jsonb_array_elements(v2->'rows') with ordinality t(e, n)
    union all select 3, * from jsonb_array_elements(v3->'rows') with ordinality t(e, n)) x;
  if v_all <> v_expected then
    raise exception 'Export urutan tidak stabil: % vs %', v_all, v_expected;
  end if;
  if (pg_temp.export('{"limit": 5}')->>'has_more')::boolean then
    raise exception 'Export: has_more harus false bila tepat habis';
  end if;

  -- Cursor menghasilkan urutan sama.
  v1 := pg_temp.export('{"limit": 3}');
  v2 := pg_temp.export(jsonb_build_object('limit', 3, 'cursor', v1->'next_cursor'));
  if (v2->>'count')::integer <> 2 or (v2->>'has_more')::boolean
     or array(select e->>'number' from jsonb_array_elements(v1->'rows') e union all select e->>'number' from jsonb_array_elements(v2->'rows') e) <> v_expected then
    raise exception 'Export cursor salah: %', v2;
  end if;
  perform pg_temp.expect_error(format('select pg_temp.export(%L)', jsonb_build_object('cursor', v1->'next_cursor', 'offset', 1)), 'INVALID_INPUT');
  perform pg_temp.expect_error('select pg_temp.export(''{"limit": 1001}'')', 'INVALID_INPUT');
  perform pg_temp.expect_error('select pg_temp.export(''{"end_date": "2027-08-11"}'')', 'INVALID_DATE');
end $$;

-- Isi baris: kolom berurutan, formula dinetralkan (tab/CR), escape CSV.
do $$
declare v jsonb; v_row jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v := pg_temp.export('{}');
  if v->'columns' <> '["number","kind","posted_at","customer","petugas","payment_methods","subtotal","discount","total"]'::jsonb then
    raise exception 'Export: kolom salah %', v->'columns';
  end if;
  select e into v_row from jsonb_array_elements(v->'rows') e where e->>'number' = 'X-1';
  if v_row->>'customer' <> E'''\t=1+1' or v_row->>'payment_methods' <> 'TRANSFER' or v_row->>'petugas' <> 'Ayah Owner'
     or v_row->>'posted_at' <> '2026-08-10 00:00:00' or v_row ? '_cursor' then
    raise exception 'Export: baris X-1 salah %', v_row;
  end if;
  if v->>'csv_header' <> '"number","kind","posted_at","customer","petugas","payment_methods","subtotal","discount","total"' then
    raise exception 'Export: header CSV salah %', v->>'csv_header';
  end if;
  if position('"Budi, ""Toko"" Jaya"' in v->>'csv_rows') = 0 then
    raise exception 'Export: escape CSV salah %', v->>'csv_rows';
  end if;
  if private.csv_safe(E'\rabc') <> E'''\rabc' or private.csv_safe(E'\tabc') <> E'''\tabc'
     or private.csv_safe(' =cmd') <> ''' =cmd' or private.csv_safe('-5') <> '''-5' or private.csv_safe('@x') <> '''@x'
     or private.csv_safe('Lampu 10W') <> 'Lampu 10W' then
    raise exception 'csv_safe tidak menetralkan semua pola formula';
  end if;
end $$;

-- Peran: STAFF boleh nota (tanpa modal), tidak boleh katalog; modal hanya OWNER dengan flag.
do $$
declare v jsonb;
begin
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  if (pg_temp.export('{}')->>'count')::integer <> 5 then raise exception 'STAFF harus bisa ekspor nota'; end if;
  perform pg_temp.expect_error('select public.export_csv_v1(''{"dataset":"products"}'')', 'FORBIDDEN');
  perform pg_temp.expect_error('select pg_temp.export(''{"include_cost": true}'')', 'INVALID_INPUT');

  perform pg_temp.act('33333333-3333-4333-8333-333333333333');
  v := public.export_csv_v1('{"dataset":"products"}');
  if v::text ~* 'cost' or (v->>'count')::integer <> 2 then raise exception 'MAINTAINER katalog salah %', v; end if;
  perform pg_temp.expect_error('select public.export_csv_v1(''{"dataset":"products","include_cost":true}'')', 'FORBIDDEN');

  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform public.post_opening_stock_v1(jsonb_build_object('operation_id', 'd5000000-0000-4000-8000-000000000001',
    'reason', 'awal', 'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
      'qty', '4', 'acquisition_cost', '40001'))));
  v := public.export_csv_v1('{"dataset":"products","include_cost":true,"limit":1}');
  if v->'columns'->>-1 <> 'inventory_cost' or v->'rows'->0->>'sku' <> 'KBL-NYA-1.5' or not (v->>'has_more')::boolean then
    raise exception 'OWNER katalog+modal halaman 1 salah %', v;
  end if;
  v := public.export_csv_v1(jsonb_build_object('dataset', 'products', 'include_cost', true, 'limit', 1, 'cursor', v->'next_cursor'));
  if v->'rows'->0->>'sku' <> 'LMP-LED-10W' or v->'rows'->0->>'inventory_cost' <> '40001'
     or v->'rows'->0->>'stock_shop' <> '4.000' or (v->>'has_more')::boolean then
    raise exception 'OWNER katalog+modal halaman 2 salah %', v;
  end if;
  perform pg_temp.expect_error('select public.export_csv_v1(''{"dataset":"payroll"}'')', 'INVALID_INPUT');

  perform pg_temp.act('44444444-4444-4444-8444-444444444444');
  perform pg_temp.expect_error('select pg_temp.export(''{}'')', 'ACCOUNT_INACTIVE');
end $$;

rollback;
