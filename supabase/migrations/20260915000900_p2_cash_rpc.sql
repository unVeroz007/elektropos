-- P2 RPC: kas (open/close/transfer/adjust)

insert into private.cashboxes(code, label, custodian) values
  ('SHOP_DRAWER', 'Laci toko', 'TOKO'),
  ('FATHER_WALLET', 'Uang dibawa ayah', 'AYAH')
on conflict (code) do nothing;

create or replace function private.cash_session_expected(p_session uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select s.opening_amount
    + coalesce((select sum(m.amount) from private.cash_movements m
        where m.session_id = s.id and m.direction = 'IN'), 0)
    - coalesce((select sum(m.amount) from private.cash_movements m
        where m.session_id = s.id and m.direction = 'OUT'), 0)
  from private.cash_sessions s where s.id = p_session
$$;

create or replace function public.open_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_code text := p_input->>'cashbox_code';
  v_amount numeric(20,0);
  v_session private.cash_sessions%rowtype;
  v_old jsonb;
begin
  v_role := private.current_role();
  v_old := private.operation_result('open_cash_session_v1', p_input);
  if v_old is not null then return v_old; end if;

  if v_code not in ('SHOP_DRAWER', 'FATHER_WALLET') then
    raise exception 'Laci tidak dikenal' using errcode='22023';
  end if;
  if v_code = 'FATHER_WALLET' and v_role <> 'OWNER' then
    raise exception 'Hanya owner dapat membuka wallet ayah' using errcode='42501';
  end if;
  if v_role not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan membuka kas' using errcode='42501';
  end if;

  v_amount := private.decimal_input(p_input->'opening_amount', 0, 9999999999999999, false);

  if exists (select 1 from private.cash_sessions where cashbox_id = v_code and status = 'OPEN') then
    raise exception 'Kas masih terbuka' using errcode='40001';
  end if;

  insert into private.cash_sessions(cashbox_id, opened_by, business_date, opening_amount)
  values (v_code, v_actor, (now() at time zone 'Asia/Jakarta')::date, v_amount)
  returning * into v_session;

  insert into private.audit_events(actor_id, action, entity_type, entity_id)
  values (v_actor, 'OPEN_CASH_SESSION', 'CASH_SESSION', v_session.id);

  return private.finish_operation('open_cash_session_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'cashbox_code', v_code,
    'opening_amount', v_amount::text, 'version', v_session.version,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.open_cash_session_v1(jsonb) from public,anon,authenticated;
grant execute on function public.open_cash_session_v1(jsonb) to authenticated;

create or replace function public.close_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_session private.cash_sessions%rowtype;
  v_expected numeric(20,0);
  v_counted numeric(20,0);
  v_variance numeric(20,0);
  v_old jsonb;
begin
  v_role := private.current_role();
  v_old := private.operation_result('close_cash_session_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_session from private.cash_sessions
    where id = nullif(p_input->>'session_id','')::uuid for update;
  if not found then raise exception 'Sesi kas tidak ditemukan' using errcode='22023'; end if;
  if v_session.status = 'CLOSED' then raise exception 'Sesi kas sudah ditutup' using errcode='40001'; end if;
  if v_session.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode='40001';
  end if;
  if v_session.cashbox_id = 'FATHER_WALLET' and v_role <> 'OWNER' then
    raise exception 'Hanya owner dapat menutup wallet ayah' using errcode='42501';
  end if;

  v_expected := private.cash_session_expected(v_session.id);
  v_counted := private.decimal_input(p_input->'counted_amount', 0, 9999999999999999, false);
  v_variance := v_counted - v_expected;
  if v_variance <> 0 and length(trim(coalesce(p_input->>'note',''))) = 0 then
    raise exception 'Selisih kas memerlukan keterangan' using errcode='22023';
  end if;

  update private.cash_sessions set
    status = 'CLOSED', closed_at = now(), closed_by = v_actor,
    counted_amount = v_counted, expected_snapshot = v_expected,
    variance = v_variance, note = p_input->>'note', version = version + 1
    where id = v_session.id returning * into v_session;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CLOSE_CASH_SESSION', 'CASH_SESSION', v_session.id, p_input->>'note');

  return private.finish_operation('close_cash_session_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'expected', v_expected::text,
    'counted', v_counted::text, 'variance', v_variance::text,
    'version', v_session.version, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.close_cash_session_v1(jsonb) from public,anon,authenticated;
grant execute on function public.close_cash_session_v1(jsonb) to authenticated;

create or replace function public.transfer_cash_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_source private.cash_sessions%rowtype;
  v_target private.cash_sessions%rowtype;
  v_amount numeric(20,0);
  v_group uuid := gen_random_uuid();
  v_expected numeric(20,0);
  v_old jsonb;
begin
  v_role := private.current_role();
  if v_role <> 'OWNER' then
    raise exception 'Hanya owner dapat memindahkan kas' using errcode='42501';
  end if;
  v_old := private.operation_result('transfer_cash_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_source from private.cash_sessions
    where id = nullif(p_input->>'source_session_id','')::uuid for update;
  if not found then raise exception 'Sesi sumber tidak ditemukan' using errcode='22023'; end if;
  select * into v_target from private.cash_sessions
    where id = nullif(p_input->>'target_session_id','')::uuid for update;
  if not found then raise exception 'Sesi tujuan tidak ditemukan' using errcode='22023'; end if;

  if v_source.id = v_target.id then
    raise exception 'Sesi sumber dan tujuan harus berbeda' using errcode='22023';
  end if;
  if v_source.status <> 'OPEN' or v_target.status <> 'OPEN' then
    raise exception 'Kedua sesi kas harus terbuka' using errcode='40001';
  end if;

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999, false);
  if v_amount <= 0 then raise exception 'Jumlah harus lebih dari nol' using errcode='22023'; end if;

  v_expected := private.cash_session_expected(v_source.id);
  if v_expected < v_amount then
    raise exception 'INSUFFICIENT_STOCK: saldo kas sumber tidak cukup' using errcode='22023';
  end if;

  insert into private.cash_movements(session_id, direction, kind, amount,
    transfer_group_id, reason, actor_id, operation_id)
  values (v_source.id, 'OUT', 'TRANSFER', v_amount, v_group,
    p_input->>'reason', v_actor, (p_input->>'operation_id')::uuid),
    (v_target.id, 'IN', 'TRANSFER', v_amount, v_group,
    p_input->>'reason', v_actor, (p_input->>'operation_id')::uuid);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSFER_CASH', 'CASH_SESSION', v_source.id, p_input->>'reason');

  return private.finish_operation('transfer_cash_v1', p_input, jsonb_build_object(
    'ok', true, 'source_session_id', v_source.id, 'target_session_id', v_target.id,
    'amount', v_amount::text, 'transfer_group_id', v_group,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.transfer_cash_v1(jsonb) from public,anon,authenticated;
grant execute on function public.transfer_cash_v1(jsonb) to authenticated;

create or replace function public.record_cash_adjustment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_session private.cash_sessions%rowtype;
  v_amount numeric(20,0);
  v_direction text := p_input->>'direction';
  v_old jsonb;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat menyesuaikan kas' using errcode='42501';
  end if;
  v_old := private.operation_result('record_cash_adjustment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_session from private.cash_sessions
    where id = nullif(p_input->>'session_id','')::uuid for update;
  if not found then raise exception 'Sesi kas tidak ditemukan' using errcode='22023'; end if;
  if v_session.status <> 'OPEN' then raise exception 'CASH_SESSION_CLOSED' using errcode='40001'; end if;
  if v_direction not in ('IN','OUT') then raise exception 'Arah tidak sah' using errcode='22023'; end if;
  if length(trim(coalesce(p_input->>'reason',''))) = 0 then
    raise exception 'Alasan wajib' using errcode='22023';
  end if;

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999, false);
  if v_amount <= 0 then raise exception 'Jumlah harus lebih dari nol' using errcode='22023'; end if;

  if v_direction = 'OUT' then
    if private.cash_session_expected(v_session.id) < v_amount then
      raise exception 'INSUFFICIENT_STOCK: saldo kas tidak cukup' using errcode='22023';
    end if;
  end if;

  insert into private.cash_movements(session_id, direction, kind, amount,
    reason, actor_id, operation_id)
  values (v_session.id, v_direction,
    case when v_direction = 'IN' then 'OWNER_ADD' else 'OWNER_WITHDRAW' end,
    v_amount, p_input->>'reason', v_actor, (p_input->>'operation_id')::uuid);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CASH_ADJUSTMENT', 'CASH_SESSION', v_session.id, p_input->>'reason');

  return private.finish_operation('record_cash_adjustment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'direction', v_direction,
    'amount', v_amount::text, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.record_cash_adjustment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.record_cash_adjustment_v1(jsonb) to authenticated;
