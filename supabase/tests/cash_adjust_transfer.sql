-- Kas: penyesuaian owner dan pindah kas antar pemegang (BR-12).
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

-- Penyesuaian.
do $$
declare v jsonb; v_op uuid := gen_random_uuid();
begin
  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"50000","reason":"modal"}', 'CASH_SESSION_CLOSED');
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"100000"}');
  perform pg_temp.fails('staff', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"50000","reason":"modal"}', 'FORBIDDEN');
  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"50000"}', 'INVALID_INPUT');
  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","amount":"0","reason":"x"}', 'INVALID_NUMBER');
  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"IN","kind":"EXPENSE","amount":"5","reason":"x"}', 'INVALID_INPUT');
  -- Klien tidak boleh memilih sesi.
  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() || jsonb_build_object('cashbox_code', 'SHOP_DRAWER',
    'direction', 'IN', 'amount', '5', 'reason', 'x', 'session_id', gen_random_uuid()), 'INVALID_INPUT');

  v := pg_temp.rpc('owner', 'record_cash_adjustment_v1', jsonb_build_object('operation_id', v_op,
    'cashbox_code', 'SHOP_DRAWER', 'direction', 'IN', 'amount', '50000', 'reason', 'Tambah receh'));
  perform pg_temp.eq(v->>'expected', '150000', 'saldo setelah tambah');
  perform pg_temp.rpc('owner', 'record_cash_adjustment_v1', jsonb_build_object('operation_id', v_op,
    'cashbox_code', 'SHOP_DRAWER', 'direction', 'IN', 'amount', '50000', 'reason', 'Tambah receh'));
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 150000::numeric, 'idempoten penyesuaian');
  perform pg_temp.eq((pg_temp.rpc('owner', 'get_operation_v1', jsonb_build_object('command', 'record_cash_adjustment_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'get_operation penyesuaian');

  perform pg_temp.fails('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"OUT","kind":"EXPENSE","amount":"150001","reason":"listrik"}', 'INSUFFICIENT_CASH');
  v := pg_temp.rpc('owner', 'record_cash_adjustment_v1', pg_temp.op() ||
    '{"cashbox_code":"SHOP_DRAWER","direction":"OUT","kind":"EXPENSE","amount":"30000","reason":"Bayar listrik"}');
  perform pg_temp.eq(v->>'kind', 'EXPENSE', 'jenis biaya');
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 120000::numeric, 'saldo setelah biaya');
end $$;

-- Pindah kas.
do $$
declare v jsonb; v_group uuid;
begin
  perform pg_temp.fails('owner', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"SHOP_DRAWER","target_cashbox":"FATHER_WALLET","amount":"10000","reason":"setor"}', 'CASH_SESSION_CLOSED');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"FATHER_WALLET","opening_amount":"0"}', 'FORBIDDEN');
  perform pg_temp.rpc('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"FATHER_WALLET","opening_amount":"20000"}');
  perform pg_temp.fails('owner', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"SHOP_DRAWER","target_cashbox":"SHOP_DRAWER","amount":"10000","reason":"x"}', 'INVALID_INPUT');
  perform pg_temp.fails('staff', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"SHOP_DRAWER","target_cashbox":"FATHER_WALLET","amount":"10000","reason":"x"}', 'FORBIDDEN');
  perform pg_temp.fails('owner', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"FATHER_WALLET","target_cashbox":"SHOP_DRAWER","amount":"20001","reason":"x"}', 'INSUFFICIENT_CASH');
  perform pg_temp.fails('owner', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"FATHER_WALLET","target_cashbox":"SHOP_DRAWER","amount":"1000"}', 'INVALID_INPUT');

  v := pg_temp.rpc('owner', 'transfer_cash_v1', pg_temp.op() ||
    '{"source_cashbox":"SHOP_DRAWER","target_cashbox":"FATHER_WALLET","amount":"70000","reason":"Dibawa belanja"}');
  v_group := (v->>'transfer_group_id')::uuid;
  perform pg_temp.eq(pg_temp.expected('SHOP_DRAWER'), 50000::numeric, 'laci setelah pindah');
  perform pg_temp.eq(pg_temp.expected('FATHER_WALLET'), 90000::numeric, 'dompet setelah pindah');
  perform pg_temp.eq((select sum(case direction when 'IN' then amount else -amount end) from private.cash_movements
    where transfer_group_id = v_group), 0::numeric, 'pindah kas bersih nol');
  perform pg_temp.eq((select count(*) from private.payments), 0::bigint, 'pindah kas bukan pembayaran');
end $$;

rollback;
