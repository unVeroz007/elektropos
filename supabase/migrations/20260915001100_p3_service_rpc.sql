-- P3 RPC: servis (tiket, estimasi, part, tagihan, penyerahan)

-- create_service_ticket_v1
create or replace function public.create_service_ticket_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_ticket_id uuid;
  v_number text;
  v_customer_id uuid;
  v_parent_id uuid;
begin
  v_role := private.current_role();
  if v_role not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan membuat tiket' using errcode = '42501';
  end if;
  v_old := private.operation_result('create_service_ticket_v1', p_input);
  if v_old is not null then return v_old; end if;

  -- Buat pelanggan jika diperlukan
  v_customer_id := nullif(p_input->>'customer_id', '')::uuid;
  if v_customer_id is null and (p_input->>'customer_name') is not null then
    insert into private.customers(name, phone_normalized, alternate_contact, address)
    values (
      trim(p_input->>'customer_name'),
      nullif(trim(p_input->>'customer_phone'), ''),
      p_input->>'customer_alt_contact',
      p_input->>'customer_address'
    ) returning id into v_customer_id;
  end if;

  v_parent_id := nullif(p_input->>'parent_ticket_id', '')::uuid;

  v_number := private.next_stock_number('SRV');
  insert into private.service_tickets(
    number, customer_id, mechanic_id, parent_ticket_id,
    service_location, custody_location,
    equipment_type, equipment_brand, equipment_model, equipment_serial,
    complaint, initial_condition, accessories,
    address, scheduled_at
  ) values (
    v_number,
    v_customer_id,
    coalesce(
      (select id from private.app_profiles where role = 'OWNER' and active order by created_at limit 1),
      v_actor
    ),
    v_parent_id,
    coalesce(p_input->>'service_location', 'STORE'),
    case when p_input->>'service_location' = 'ONSITE' then 'CUSTOMER' else 'SHOP' end,
    trim(p_input->>'equipment_type'),
    p_input->>'equipment_brand',
    p_input->>'equipment_model',
    p_input->>'equipment_serial',
    trim(p_input->>'complaint'),
    p_input->>'initial_condition',
    p_input->>'accessories',
    p_input->>'address',
    nullif(p_input->>'scheduled_at', '')::timestamptz
  ) returning id into v_ticket_id;

  -- Event status awal
  insert into private.service_status_events(ticket_id, to_status, kind, actor_id)
  values (v_ticket_id, 'NEW', 'TRANSITION', v_actor);

  -- Event custody awal
  insert into private.service_custody_events(ticket_id, from_location, to_location, actor_id)
  values (v_ticket_id, null, 'CUSTOMER', v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREATE_TICKET', 'SERVICE_TICKET', v_ticket_id, p_input->>'reason');

  return private.finish_operation('create_service_ticket_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket_id, 'number', v_number,
    'operation_id', p_input->>'operation_id', 'server_time', now()));
end $$;
revoke all on function public.create_service_ticket_v1(jsonb) from public,anon,authenticated;
grant execute on function public.create_service_ticket_v1(jsonb) to authenticated;

-- transition_service_v1
create or replace function public.transition_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_target text;
  v_valid boolean;
begin
  v_role := private.current_role();
  if v_role <> 'OWNER' then
    raise exception 'Hanya owner dapat mengubah status servis' using errcode = '42501';
  end if;
  v_old := private.operation_result('transition_service_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  v_target := p_input->>'target_status';
  if v_target is null then
    raise exception 'target_status wajib' using errcode = '22023';
  end if;

  -- Validasi transisi (WF-05)
  v_valid := case v_ticket.work_status
    when 'NEW' then v_target in ('INSPECTING', 'CANCELLED')
    when 'INSPECTING' then v_target in ('AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED')
    when 'AWAITING_APPROVAL' then v_target in ('WORKING', 'UNREPAIRABLE', 'CANCELLED')
    when 'WORKING' then v_target in ('READY', 'AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED')
    when 'READY' then false
    when 'UNREPAIRABLE' then false
    when 'CANCELLED' then false
    else false
  end;

  if not v_valid then
    raise exception 'Transisi % -> % tidak diizinkan', v_ticket.work_status, v_target
      using errcode = '22023';
  end if;

  -- READY membutuhkan test_result
  if v_target = 'READY' and length(trim(coalesce(p_input->>'test_result', ''))) = 0 then
    raise exception 'Transisi ke READY memerlukan hasil uji' using errcode = '22023';
  end if;

  update private.service_tickets set
    work_status = v_target,
    test_result = case when v_target = 'READY' then p_input->>'test_result' else test_result end,
    terminal_reason = case when v_target in ('UNREPAIRABLE', 'CANCELLED') then p_input->>'reason' else terminal_reason end,
    version = version + 1
    where id = v_ticket.id;

  insert into private.service_status_events(ticket_id, from_status, to_status, kind, reason, actor_id)
  values (v_ticket.id, v_ticket.work_status, v_target, 'TRANSITION', p_input->>'reason', v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSITION_TICKET', 'SERVICE_TICKET', v_ticket.id, p_input->>'reason');

  return private.finish_operation('transition_service_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'from_status', v_ticket.work_status,
    'to_status', v_target, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.transition_service_v1(jsonb) from public,anon,authenticated;
grant execute on function public.transition_service_v1(jsonb) to authenticated;

-- record_estimate_v1
create or replace function public.record_estimate_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_rev integer;
  v_est_id uuid;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat membuat estimasi' using errcode = '42501';
  end if;
  v_old := private.operation_result('record_estimate_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;

  select coalesce(max(revision), 0) + 1 into v_rev
  from private.service_estimates where ticket_id = v_ticket.id;

  insert into private.service_estimates(ticket_id, revision, description, min_amount, max_amount, status)
  values (v_ticket.id, v_rev, p_input->>'description',
    nullif(p_input->>'min_amount', '')::numeric,
    (p_input->>'max_amount')::numeric, 'PROPOSED')
  returning id into v_est_id;

  -- Transisi ke AWAITING_APPROVAL jika masih NEW/INSPECTING
  if v_ticket.work_status in ('NEW', 'INSPECTING') then
    update private.service_tickets set work_status = 'AWAITING_APPROVAL', version = version + 1
      where id = v_ticket.id;
    insert into private.service_status_events(ticket_id, from_status, to_status, kind, actor_id)
    values (v_ticket.id, v_ticket.work_status, 'AWAITING_APPROVAL', 'TRANSITION', v_actor);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RECORD_ESTIMATE', 'SERVICE_ESTIMATE', v_est_id, p_input->>'reason');

  return private.finish_operation('record_estimate_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_est_id, 'revision', v_rev,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.record_estimate_v1(jsonb) from public,anon,authenticated;
grant execute on function public.record_estimate_v1(jsonb) to authenticated;

-- approve_estimate_v1
create or replace function public.approve_estimate_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_est private.service_estimates%rowtype;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mencatat persetujuan' using errcode = '42501';
  end if;
  v_old := private.operation_result('approve_estimate_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_est from private.service_estimates
    where id = nullif(p_input->>'estimate_id', '')::uuid for update;
  if not found then raise exception 'Estimasi tidak ditemukan' using errcode = '22023'; end if;
  if v_est.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  update private.service_estimates set
    status = 'APPROVED',
    approved_limit = (p_input->>'agreed_limit')::numeric,
    approved_method = p_input->>'method',
    approved_at = now(),
    approved_by = v_actor,
    customer_consent_note = p_input->>'consent_note',
    version = version + 1
    where id = v_est.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'APPROVE_ESTIMATE', 'SERVICE_ESTIMATE', v_est.id, p_input->>'consent_note');

  return private.finish_operation('approve_estimate_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_est.id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.approve_estimate_v1(jsonb) from public,anon,authenticated;
grant execute on function public.approve_estimate_v1(jsonb) to authenticated;

-- use_service_part_v1
create or replace function public.use_service_part_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_product private.products%rowtype;
  v_unit private.product_units%rowtype;
  v_pos private.stock_positions%rowtype;
  v_lot private.inventory_lots%rowtype;
  v_qty numeric;
  v_cost numeric;
  v_event_id uuid;
  v_price numeric;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat menggunakan part' using errcode = '42501';
  end if;
  v_old := private.operation_result('use_service_part_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.work_status <> 'WORKING' then
    raise exception 'Part hanya dapat digunakan saat status WORKING' using errcode = '22023';
  end if;

  -- Pastikan ada estimasi yang disetujui
  if not exists (select 1 from private.service_estimates where ticket_id = v_ticket.id and status = 'APPROVED') then
    raise exception 'Belum ada estimasi yang disetujui' using errcode = '22023';
  end if;

  select l.* into v_lot from private.inventory_lots l
    join private.stock_positions s on s.lot_id = l.id
    where s.id = (p_input->>'position_id')::uuid;
  if not found then raise exception 'Posisi part tidak ditemukan' using errcode = '22023'; end if;

  select * into v_product from private.products where id = v_lot.product_id;
  select * into v_unit from private.product_units where id = (p_input->>'product_unit_id')::uuid;

  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);
  select * into v_pos from private.stock_positions
    where id = (p_input->>'position_id')::uuid for update;
  if v_pos.qty_base < v_qty then
    raise exception 'INSUFFICIENT_STOCK' using errcode = '22023';
  end if;

  v_cost := private.cost_for_exit_lot(v_lot.id, v_qty);
  v_price := coalesce(private.decimal_input(p_input->'charge_unit_price', 6, 999999999999.999999, false), 0);

  -- Kurangi stok
  update private.stock_positions set qty_base = qty_base - v_qty,
    sealed = false, version = version + 1 where id = v_pos.id;
  update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
    remaining_cost = remaining_cost - v_cost, version = version + 1
    where id = v_lot.id;

  -- Catat event pemakaian
  insert into private.service_part_events(
    ticket_id, product_id, kind, qty_base, charge_unit_price, actor_id)
  values (v_ticket.id, v_product.id, 'USE', v_qty, v_price, v_actor)
  returning id into v_event_id;

  -- Ledger stok
  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta,
    kind, service_part_event_id, actor_id, operation_id)
  values (v_event_id, v_lot.id, v_pos.id, -v_qty, -v_cost,
    'SALE_OUT', v_event_id, v_actor, (p_input->>'operation_id')::uuid);

  -- Cost allocation
  insert into private.cost_allocations(lot_id, origin_position_id, qty_base, cost_amount, occurred_at)
  values (v_lot.id, v_pos.id, v_qty, v_cost, now());

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'USE_PART', 'SERVICE_PART_EVENT', v_event_id, p_input->>'reason');

  return private.finish_operation('use_service_part_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_event_id, 'qty_base', v_qty::text,
    'cost', v_cost::text, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.use_service_part_v1(jsonb) from public,anon,authenticated;
grant execute on function public.use_service_part_v1(jsonb) to authenticated;

-- reverse_service_part_v1
create or replace function public.reverse_service_part_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_use_event private.service_part_events%rowtype;
  v_ticket private.service_tickets%rowtype;
  v_qty numeric;
  v_cost numeric;
  v_rev_id uuid;
  v_lot private.inventory_lots%rowtype;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mereverse part' using errcode = '42501';
  end if;
  v_old := private.operation_result('reverse_service_part_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_use_event from private.service_part_events
    where id = nullif(p_input->>'use_event_id', '')::uuid;
  if not found then raise exception 'Event USE tidak ditemukan' using errcode = '22023'; end if;
  if v_use_event.kind <> 'USE' then
    raise exception 'Hanya event USE yang dapat di-reverse' using errcode = '22023';
  end if;

  v_qty := private.decimal_input(p_input->'qty', 3, 999999999.999);
  if v_qty <= 0 then raise exception 'Qty reverse harus positif' using errcode = '22023'; end if;

  select coalesce(sum(qty_base), 0) into v_cost
  from private.service_part_events
  where reverses_event_id = v_use_event.id and kind = 'REVERSE';
  if v_qty + v_cost > v_use_event.qty_base then
    raise exception 'Reverse melebihi qty USE' using errcode = '22023';
  end if;

  insert into private.service_part_events(
    ticket_id, product_id, kind, qty_base, charge_unit_price, reverses_event_id, actor_id)
  values (v_use_event.ticket_id, v_use_event.product_id, 'REVERSE', v_qty,
    v_use_event.charge_unit_price, v_use_event.id, v_actor)
  returning id into v_rev_id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REVERSE_PART', 'SERVICE_PART_EVENT', v_rev_id, p_input->>'reason');

  return private.finish_operation('reverse_service_part_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_rev_id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.reverse_service_part_v1(jsonb) from public,anon,authenticated;
grant execute on function public.reverse_service_part_v1(jsonb) to authenticated;

-- record_service_payment_v1
create or replace function public.record_service_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_amount numeric;
  v_session_id uuid;
  v_payment_id uuid;
begin
  v_role := private.current_role();
  if v_role not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan menerima pembayaran servis' using errcode = '42501';
  end if;
  v_old := private.operation_result('record_service_payment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999, false);
  if v_amount <= 0 then raise exception 'Jumlah harus positif' using errcode = '22023'; end if;

  v_session_id := nullif(p_input->>'cash_session_id', '')::uuid;

  insert into private.payments(direction, purpose, service_ticket_id, method, amount,
    tendered, change, cash_session_id, actor_id, operation_id, intent_id)
  values ('IN', 'SERVICE_RECEIPT', v_ticket.id, p_input->>'method', v_amount,
    nullif(p_input->>'tendered', '')::numeric,
    nullif(p_input->>'change', '')::numeric,
    v_session_id, v_actor,
    (p_input->>'operation_id')::uuid,
    nullif(p_input->>'payment_intent_id', '')::uuid)
  returning id into v_payment_id;

  if v_session_id is not null and p_input->>'method' = 'CASH' then
    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id)
    values (v_session_id, 'IN', 'CUSTOMER_PAYMENT', v_amount,
      v_payment_id, v_actor, (p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'SERVICE_PAYMENT', 'PAYMENT', v_payment_id, p_input->>'reason');

  return private.finish_operation('record_service_payment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_payment_id, 'amount', v_amount::text,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.record_service_payment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.record_service_payment_v1(jsonb) to authenticated;

-- handover_service_v1
create or replace function public.handover_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_location text;
  v_now timestamptz := now();
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan melakukan penyerahan' using errcode = '42501';
  end if;
  v_old := private.operation_result('handover_service_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  -- Syarat: terminal + final + tidak ada sisa bayar
  if v_ticket.work_status not in ('READY', 'UNREPAIRABLE', 'CANCELLED') then
    raise exception 'Status belum terminal' using errcode = '22023';
  end if;

  v_location := p_input->>'location';

  update private.service_tickets set
    custody_location = v_location,
    closed_at = v_now,
    version = version + 1
    where id = v_ticket.id;

  insert into private.service_custody_events(ticket_id, from_location, to_location,
    condition_note, receiver_name, actor_id)
  values (v_ticket.id, v_ticket.custody_location, v_location,
    p_input->>'condition_note', p_input->>'receiver_name', v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'HANDOVER_SERVICE', 'SERVICE_TICKET', v_ticket.id, p_input->>'receiver_name');

  return private.finish_operation('handover_service_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'location', v_location, 'closed_at', v_now,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.handover_service_v1(jsonb) from public,anon,authenticated;
grant execute on function public.handover_service_v1(jsonb) to authenticated;

-- get_service_ticket_v1
create or replace function public.get_service_ticket_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ticket private.service_tickets%rowtype;
  v_result jsonb;
begin
  perform private.current_role();
  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid;
  if not found then raise exception 'NOT_FOUND' using errcode = '22023'; end if;

  select jsonb_build_object(
    'id', t.id, 'number', t.number,
    'customer_id', t.customer_id,
    'service_location', t.service_location,
    'custody_location', t.custody_location,
    'equipment_type', t.equipment_type,
    'equipment_brand', t.equipment_brand,
    'complaint', t.complaint,
    'work_status', t.work_status,
    'test_result', t.test_result,
    'closed_at', t.closed_at,
    'version', t.version,
    'created_at', t.created_at,
    'status_events', (select coalesce(jsonb_agg(jsonb_build_object(
      'from_status', se.from_status, 'to_status', se.to_status,
      'reason', se.reason, 'actor_id', se.actor_id, 'occurred_at', se.occurred_at)
      order by se.occurred_at), '[]'::jsonb)
      from private.service_status_events se where se.ticket_id = t.id),
    'estimates', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'revision', e.revision, 'description', e.description,
      'min_amount', e.min_amount, 'max_amount', e.max_amount,
      'status', e.status, 'approved_limit', e.approved_limit)
      order by e.revision), '[]'::jsonb)
      from private.service_estimates e where e.ticket_id = t.id),
    'part_events', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', pe.id, 'kind', pe.kind, 'qty_base', pe.qty_base::text,
      'charge_unit_price', pe.charge_unit_price::text)
      order by pe.occurred_at), '[]'::jsonb)
      from private.service_part_events pe where pe.ticket_id = t.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'amount', p.amount::text, 'method', p.method, 'occurred_at', p.occurred_at)
      order by p.occurred_at), '[]'::jsonb)
      from private.payments p where p.service_ticket_id = t.id)
  ) into v_result
  from private.service_tickets t where t.id = v_ticket.id;

  return v_result;
end $$;
revoke all on function public.get_service_ticket_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_service_ticket_v1(jsonb) to authenticated;

-- list_service_tickets_v1
create or replace function public.list_service_tickets_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_limit integer := least(coalesce((p_input->>'limit')::integer, 25), 100);
  v_status text;
  v_result jsonb;
begin
  perform private.current_role();
  v_status := p_input->>'status';
  select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'id', t.id, 'number', t.number,
      'equipment_type', t.equipment_type,
      'complaint', t.complaint,
      'work_status', t.work_status,
      'service_location', t.service_location,
      'custody_location', t.custody_location,
      'created_at', t.created_at
    ) as row_data
    from private.service_tickets t
    where (v_status is null or t.work_status = v_status)
      and t.closed_at is null
    order by created_at desc
    limit v_limit
  ) sub;
  return v_result;
end $$;
revoke all on function public.list_service_tickets_v1(jsonb) from public,anon,authenticated;
grant execute on function public.list_service_tickets_v1(jsonb) to authenticated;

-- create_customer_v1
create or replace function public.create_customer_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_id uuid;
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('create_customer_v1', p_input);
  if v_old is not null then return v_old; end if;

  insert into private.customers(name, phone_normalized, alternate_contact, address)
  values (trim(p_input->>'name'), nullif(trim(p_input->>'phone'), ''),
    p_input->>'alternate_contact', p_input->>'address')
  returning id into v_id;

  return private.finish_operation('create_customer_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.create_customer_v1(jsonb) from public,anon,authenticated;
grant execute on function public.create_customer_v1(jsonb) to authenticated;
