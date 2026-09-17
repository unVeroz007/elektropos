-- Kas: buka/tutup/lihat/riwayat/tinjau (D1, S09, K10, BR-12).
\set ON_ERROR_STOP on

begin;

-- Helper uji: panggil RPC sebagai aktor, dan harapkan kode error tertentu.
create function pg_temp.rpc(p_actor text, p_fn text, p_input jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', case p_actor
    when 'owner' then '11111111-1111-4111-8111-111111111111'
    when 'staff' then '22222222-2222-4222-8222-222222222222'
    when 'maint' then '33333333-3333-4333-8333-333333333333'
    when 'off' then '44444444-4444-4444-8444-444444444444' end, true);
  execute format('select public.%I($1)', p_fn) into v using p_input;
  return v;
end $$;
create function pg_temp.fails(p_actor text, p_fn text, p_input jsonb, p_code text) returns void language plpgsql as $$
begin
  perform pg_temp.rpc(p_actor, p_fn, p_input);
  raise exception 'TIDAK_GAGAL';
exception when others then
  -- operation_result lama melempar 'IDEMPOTENCY_CONFLICT' tanpa titik dua.
  if sqlerrm <> p_code and position(p_code || ':' in sqlerrm) <> 1 then
    raise exception 'Uji % %: harap %, dapat: %', p_fn, p_input, p_code, sqlerrm;
  end if;
end $$;
create function pg_temp.eq(p_got anyelement, p_want anyelement, p_what text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'Uji gagal %: harap %, dapat %', p_what, p_want, p_got; end if;
end $$;
create function pg_temp.op() returns jsonb language sql as $$ select jsonb_build_object('operation_id', gen_random_uuid()) $$;

-- Grant: RPC baru dapat dieksekusi authenticated, helper private tidak.
do $$ begin
  perform pg_temp.eq(has_function_privilege('authenticated', 'public.list_cash_sessions_v1(jsonb)', 'execute'), true, 'grant list');
  perform pg_temp.eq(has_function_privilege('authenticated', 'public.review_cash_session_v1(jsonb)', 'execute'), true, 'grant review');
  perform pg_temp.eq(has_function_privilege('authenticated', 'private.cash_session_expected(uuid)', 'execute'), false, 'R01');
  perform pg_temp.eq(has_function_privilege('anon', 'public.open_cash_session_v1(jsonb)', 'execute'), false, 'anon');
end $$;

-- D1: peran.
do $$
declare v jsonb; v_id uuid; v_ver integer; v_op uuid := gen_random_uuid(); v_again jsonb;
begin
  perform pg_temp.fails('maint', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"0"}', 'FORBIDDEN');
  perform pg_temp.fails('off', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"0"}', 'ACCOUNT_INACTIVE');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"FATHER_WALLET","opening_amount":"0"}', 'FORBIDDEN');
  -- Input curang/tidak sah.
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER"}', 'INVALID_NUMBER');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":150000}', 'INVALID_NUMBER');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"-5"}', 'INVALID_NUMBER');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"10.5"}', 'INVALID_NUMBER');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"LACI_X","opening_amount":"1"}', 'INVALID_INPUT');
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"1","session_id":"x"}', 'INVALID_INPUT');

  -- STAFF buka laci toko; sesi pertama tanpa pembanding.
  v := pg_temp.rpc('staff', 'open_cash_session_v1', jsonb_build_object('operation_id', v_op,
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '150000'));
  perform pg_temp.eq(v->>'opening_amount', '150000', 'saldo buka');
  perform pg_temp.eq(v->'opening_variance', 'null'::jsonb, 'variance pertama');
  perform pg_temp.eq((v->>'needs_review')::boolean, false, 'tanpa tinjauan');
  -- Idempoten: kirim ulang tidak membuat sesi kedua; command = nama RPC.
  v_again := pg_temp.rpc('staff', 'open_cash_session_v1', jsonb_build_object('operation_id', v_op,
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '150000'));
  perform pg_temp.eq(v_again->>'entity_id', v->>'entity_id', 'idempoten');
  perform pg_temp.eq((select count(*) from private.cash_sessions), 1::bigint, 'satu sesi');
  perform pg_temp.eq((pg_temp.rpc('staff', 'get_operation_v1', jsonb_build_object('command', 'open_cash_session_v1',
    'operation_id', v_op))->>'found')::boolean, true, 'get_operation_v1');
  perform pg_temp.fails('staff', 'open_cash_session_v1', jsonb_build_object('operation_id', v_op,
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '1'), 'IDEMPOTENCY_CONFLICT');

  -- Satu sesi OPEN per cashbox.
  perform pg_temp.fails('owner', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"0"}', 'CASH_SESSION_ALREADY_OPEN');

  -- STAFF melihat laci, tidak dompet ayah; maintainer baca.
  v := pg_temp.rpc('staff', 'get_cash_session_v1', '{"cashbox_code":"SHOP_DRAWER"}');
  perform pg_temp.eq(v->>'expected', '150000', 'expected awal');
  perform pg_temp.fails('staff', 'get_cash_session_v1', '{"cashbox_code":"FATHER_WALLET"}', 'FORBIDDEN');
  perform pg_temp.eq((pg_temp.rpc('maint', 'get_cash_session_v1', '{}')->>'open')::boolean, true, 'maintainer baca');
  perform pg_temp.fails('staff', 'list_cash_sessions_v1', '{"start_date":"2026-01-01","end_date":"2026-01-02"}', 'FORBIDDEN');

  -- Tutup: selisih tanpa catatan ditolak; versi lama ditolak; STAFF boleh menutup.
  v_id := (v->>'id')::uuid; v_ver := (v->>'version')::integer;
  perform pg_temp.fails('staff', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_id,
    'expected_version', v_ver, 'counted_amount', '149000'), 'NOTE_REQUIRED');
  perform pg_temp.fails('staff', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_id,
    'expected_version', v_ver + 7, 'counted_amount', '150000'), 'VERSION_CONFLICT');
  perform pg_temp.fails('maint', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_id,
    'expected_version', v_ver, 'counted_amount', '150000'), 'FORBIDDEN');
  v := pg_temp.rpc('staff', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_id,
    'expected_version', v_ver, 'counted_amount', '149000', 'note', 'Kurang seribu'));
  perform pg_temp.eq(v->>'variance', '-1000', 'variance tutup');
  perform pg_temp.eq((v->>'needs_review')::boolean, true, 'selisih tutup ditinjau');
  perform pg_temp.fails('staff', 'close_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_id,
    'expected_version', (v->>'version')::integer, 'counted_amount', '149000', 'note', 'x'), 'CASH_SESSION_CLOSED');
  perform pg_temp.eq((pg_temp.rpc('staff', 'get_cash_session_v1', '{}')->>'last_counted_amount'), '149000', 'hitungan terakhir');
end $$;

-- S09: saldo buka dibandingkan hitungan tutup terakhir.
do $$
declare v jsonb; v_sess private.cash_sessions%rowtype;
begin
  perform pg_temp.fails('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"200000"}', 'NOTE_REQUIRED');
  v := pg_temp.rpc('staff', 'open_cash_session_v1', pg_temp.op() || '{"cashbox_code":"SHOP_DRAWER","opening_amount":"200000","note":"Tambah uang receh dari rumah"}');
  perform pg_temp.eq(v->>'opening_variance', '51000', 'selisih buka');
  perform pg_temp.eq(v->>'previous_counted_amount', '149000', 'pembanding');
  select * into v_sess from private.cash_sessions where id = (v->>'entity_id')::uuid;
  perform pg_temp.eq(v_sess.needs_review, true, 'tandai tinjau');
  perform pg_temp.eq(v_sess.opening_variance, 51000::numeric, 'kolom selisih buka');
  perform pg_temp.eq(v_sess.opening_note, 'Tambah uang receh dari rumah', 'catatan buka');

  -- Owner meninjau; staff tidak boleh.
  perform pg_temp.fails('staff', 'review_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_sess.id,
    'expected_version', v_sess.version, 'note', 'ok'), 'FORBIDDEN');
  v := pg_temp.rpc('owner', 'list_cash_sessions_v1', jsonb_build_object('start_date', private.local_today(),
    'end_date', private.local_today(), 'review_pending', true));
  perform pg_temp.eq((v->>'total')::integer, 2, 'dua sesi menunggu tinjauan');
  perform pg_temp.rpc('owner', 'review_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_sess.id,
    'expected_version', v_sess.version, 'note', 'Sudah dicek'));
  -- Sesi tertutup tetap bisa ditinjau (hanya kolom tinjauan berubah).
  select * into v_sess from private.cash_sessions where status = 'CLOSED';
  perform pg_temp.rpc('owner', 'review_cash_session_v1', pg_temp.op() || jsonb_build_object('session_id', v_sess.id,
    'expected_version', v_sess.version, 'note', 'Selisih seribu diterima'));
  v := pg_temp.rpc('maint', 'list_cash_sessions_v1', jsonb_build_object('start_date', private.local_today(),
    'end_date', private.local_today(), 'review_pending', true));
  perform pg_temp.eq((v->>'total')::integer, 0, 'tinjauan selesai');
  perform pg_temp.fails('owner', 'list_cash_sessions_v1', '{"start_date":"2026-02-30","end_date":"2026-03-01"}', 'INVALID_DATE');
end $$;

-- K10: jaring pengaman DB. Mutasi ke sesi CLOSED ditolak walau penulis lupa mengunci.
do $$
declare v_closed uuid; v_open uuid; v_snapshot numeric;
begin
  select id, expected_snapshot into v_closed, v_snapshot from private.cash_sessions where status = 'CLOSED';
  -- Reproduksi bukti audit: pembayaran servis 40.000 setelah tutup (dulu masuk, snapshot tertinggal).
  begin
    insert into private.cash_movements(session_id, direction, kind, amount, reason, actor_id, operation_id)
    values (v_closed, 'IN', 'CUSTOMER_PAYMENT', 40000, 'bayar servis telat',
      '11111111-1111-4111-8111-111111111111', gen_random_uuid());
    raise exception 'TIDAK_GAGAL';
  exception when others then
    if position('CASH_SESSION_CLOSED:' in sqlerrm) <> 1 then raise exception 'Trigger tidak menolak: %', sqlerrm; end if;
  end;
  perform pg_temp.eq(private.cash_session_expected(v_closed), v_snapshot, 'expected sesi tertutup tetap = snapshot');

  -- Riwayat tidak dapat diubah.
  begin
    update private.cash_sessions set counted_amount = 0 where id = v_closed;
    raise exception 'TIDAK_GAGAL';
  exception when others then
    if position('CASH_SESSION_CLOSED:' in sqlerrm) <> 1 then raise exception 'Sesi tertutup dapat diubah: %', sqlerrm; end if;
  end;
  select id into v_open from private.cash_sessions where status = 'OPEN';
  insert into private.cash_movements(session_id, direction, kind, amount, reason, actor_id, operation_id)
  values (v_open, 'IN', 'OWNER_ADD', 1000, 'uji', '11111111-1111-4111-8111-111111111111', gen_random_uuid());
  begin
    update private.cash_movements set amount = 1 where session_id = v_open;
    raise exception 'TIDAK_GAGAL';
  exception when others then
    if position('CASH_HISTORY_IMMUTABLE:' in sqlerrm) <> 1 then raise exception 'Mutasi dapat diubah: %', sqlerrm; end if;
  end;
end $$;

-- get_cash_session_v1: mutasi berlabel.
do $$
declare v jsonb;
begin
  v := pg_temp.rpc('staff', 'get_cash_session_v1', '{"cashbox_code":"SHOP_DRAWER"}');
  perform pg_temp.eq(v->>'expected', '201000', 'expected setelah tambah');
  perform pg_temp.eq(v->'movements'->0->>'label', 'Tambah uang kas oleh pemilik', 'label mutasi');
  perform pg_temp.eq(v->>'opening_variance', '51000', 'selisih buka tampil');
end $$;

rollback;
