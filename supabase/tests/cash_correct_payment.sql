-- K11: koreksi metode/pemegang pembayaran (BR-07). Penerimaan disimulasikan langsung
-- agar uji tidak bergantung pada kontrak penjualan/servis domain lain.
\set ON_ERROR_STOP on

begin;

create function pg_temp.rpc(p_actor text, p_fn text, p_input jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', case p_actor
    when 'owner' then '11111111-1111-4111-8111-111111111111'
    when 'staff' then '22222222-2222-4222-8222-222222222222' end, true);
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
-- Penerimaan pelanggan (+ mutasi kas bila tunai & p_box diisi).
create function pg_temp.receipt(p_method text, p_amount numeric, p_box text) returns uuid language plpgsql as $$
declare v_pay uuid; v_sess uuid;
begin
  select id into v_sess from private.cash_sessions where cashbox_id = p_box and status = 'OPEN';
  insert into private.payments(direction, purpose, method, amount, cash_session_id, actor_id, operation_id)
  values ('IN', 'SALE_RECEIPT', p_method, p_amount, v_sess, '11111111-1111-4111-8111-111111111111', gen_random_uuid())
  returning id into v_pay;
  if v_sess is not null then
    insert into private.cash_movements(session_id, direction, kind, amount, payment_id, actor_id, operation_id)
    values (v_sess, 'IN', 'CUSTOMER_PAYMENT', p_amount, v_pay, '11111111-1111-4111-8111-111111111111', gen_random_uuid());
  end if;
  return v_pay;
end $$;

do $$
declare
  v jsonb; v_s1 private.cash_sessions%rowtype; v_s2 uuid; v_cash uuid; v_tf uuid; v_part uuid; v_full uuid; v_ref uuid;
  v_op uuid := gen_random_uuid();
begin
  -- Sesi 1: terima tunai 50.000 lalu tutup.
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"0"}');
  v_cash := pg_temp.receipt('CASH', 50000, 'SHOP_DRAWER');
  select * into v_s1 from private.cash_sessions where status = 'OPEN';
  perform pg_temp.rpc('owner', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_s1.id,
    'expected_version', v_s1.version, 'counted_amount', '50000'));

  -- Tanpa sesi terbuka, pembalikan tunai ditolak.
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'Ternyata transfer'), 'CASH_SESSION_CLOSED');

  -- Sesi 2 dengan saldo 30.000: tidak cukup membalik 50.000.
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"30000","note":"Sebagian disetor"}');
  select id into v_s2 from private.cash_sessions where status = 'OPEN';
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'Ternyata transfer'), 'INSUFFICIENT_CASH');
  perform pg_temp.rpc('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"40000","reason":"modal"}');

  -- Validasi input dan peran.
  perform pg_temp.fails('staff', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'x'), 'FORBIDDEN');
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'TRANSFER', 'reason', 'x'), 'PAYMENT_NOT_CONFIRMED');
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'CASH', 'cashbox', 'SHOP_DRAWER', 'reason', 'x'), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true), 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', gen_random_uuid(),
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'x'), 'NOT_FOUND');

  -- CASH -> TRANSFER: pembalikan masuk sesi 2 (OPEN), sesi 1 tidak berubah.
  v := pg_temp.rpc('owner', 'correct_payment_v1', jsonb_build_object('operation_id', v_op, 'original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true, 'reference', 'BCA 123', 'reason', 'Ternyata transfer'));
  perform pg_temp.eq(v->>'amount', '50000', 'nilai koreksi');
  perform pg_temp.eq((select count(*) from private.cash_movements where session_id = v_s1.id), 1::bigint, 'sesi tertutup tidak tersentuh');
  perform pg_temp.eq(private.cash_session_expected(v_s1.id), 50000::numeric, 'expected sesi 1 tetap');
  perform pg_temp.eq((select session_id from private.cash_movements where payment_id = (v->>'reversal_payment_id')::uuid), v_s2, 'pembalikan di sesi berjalan');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 20000::numeric, 'saldo sesi 2 = 30000+40000-50000');
  perform pg_temp.eq((select original_payment_id from private.payments where id = (v->>'replacement_payment_id')::uuid), v_cash, 'pengganti bertaut');
  perform pg_temp.eq((select original_payment_id from private.payments where id = (v->>'reversal_payment_id')::uuid), v_cash, 'pembalikan bertaut');
  perform pg_temp.eq((select confirmed_by from private.payments where id = (v->>'replacement_payment_id')::uuid),
    '11111111-1111-4111-8111-111111111111'::uuid, 'dikonfirmasi owner');
  -- net_received: masuk - keluar = 50.000 tetap.
  perform pg_temp.eq((select sum(case direction when 'IN' then amount else -amount end) from private.payments), 50000::numeric, 'net_received tetap');
  -- Idempoten + command.
  perform pg_temp.rpc('owner', 'correct_payment_v1', jsonb_build_object('operation_id', v_op, 'original_payment_id', v_cash,
    'method', 'TRANSFER', 'confirmed', true, 'reference', 'BCA 123', 'reason', 'Ternyata transfer'));
  perform pg_temp.eq((select count(*) from private.payments where original_payment_id = v_cash), 2::bigint, 'idempoten koreksi');
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'correct_payment_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'get_operation koreksi');
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_cash,
    'method', 'QRIS', 'confirmed', true, 'reason', 'lagi'), 'ALREADY_CORRECTED');

  -- Pengganti TRANSFER dapat dikoreksi lagi -> CASH dompet ayah (butuh sesi terbuka).
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object(
    'original_payment_id', (v->>'replacement_payment_id')::uuid, 'method', 'CASH', 'cashbox', 'FATHER_WALLET', 'reason', 'Dibayar ke ayah'),
    'CASH_SESSION_CLOSED');
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"FATHER_WALLET","opening_amount":"0"}');
  perform pg_temp.rpc('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object(
    'original_payment_id', (v->>'replacement_payment_id')::uuid, 'method', 'CASH', 'cashbox', 'FATHER_WALLET', 'reason', 'Dibayar ke ayah'));
  perform pg_temp.eq(pg_temp.expected('FATHER_WALLET'), 50000::numeric, 'dompet ayah menerima pengganti tunai');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 20000::numeric, 'laci tidak berubah (transfer bukan kas)');

  -- TRANSFER tanpa kas -> CASH laci: tidak ada pembalikan kas, pengganti masuk laci.
  v_tf := pg_temp.receipt('TRANSFER', 25000, null);
  perform pg_temp.rpc('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_tf,
    'method', 'CASH', 'cashbox', 'SHOP_DRAWER', 'reason', 'Sebenarnya tunai'));
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 45000::numeric, 'laci +25000');

  -- Refund sebagian: yang dikoreksi hanya sisa saldo.
  v_part := pg_temp.receipt('CASH', 100000, 'SHOP_DRAWER');
  insert into private.payments(direction, purpose, method, amount, original_payment_id, actor_id, operation_id)
  values ('OUT', 'CUSTOMER_REFUND', 'TRANSFER', 30000, v_part, '11111111-1111-4111-8111-111111111111', gen_random_uuid())
  returning id into v_ref;
  insert into private.refund_allocations(refund_payment_id, original_payment_id, amount) values (v_ref, v_part, 30000);
  v := pg_temp.rpc('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_part,
    'method', 'QRIS', 'confirmed', true, 'reason', 'Salah pilih'));
  perform pg_temp.eq(v->>'amount', '70000', 'koreksi sisa setelah refund');
  perform pg_temp.eq(v->>'already_refunded', '30000', 'refund tercatat');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 75000::numeric, 'laci 45000+100000-70000');

  -- Refund penuh: ditolak.
  v_full := pg_temp.receipt('TRANSFER', 10000, null);
  insert into private.payments(direction, purpose, method, amount, original_payment_id, actor_id, operation_id)
  values ('OUT', 'CUSTOMER_REFUND', 'TRANSFER', 10000, v_full, '11111111-1111-4111-8111-111111111111', gen_random_uuid());
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_full,
    'method', 'QRIS', 'confirmed', true, 'reason', 'x'), 'REFUND_LIMIT_EXCEEDED');

  -- Refund/pembalikan bukan pembayaran yang dapat dikoreksi.
  perform pg_temp.fails('owner', 'correct_payment_v1', pg_temp.op() || jsonb_build_object('original_payment_id', v_ref,
    'method', 'QRIS', 'confirmed', true, 'reason', 'x'), 'INVALID_INPUT');

  -- Invariant kas: expected sesi terbuka = saldo buka + Σ mutasi.
  perform pg_temp.eq((select count(*) from private.cash_sessions s where s.status = 'CLOSED'
    and s.expected_snapshot <> private.cash_session_expected(s.id)), 0::bigint, 'snapshot sesi tertutup tetap');
end $$;

rollback;
