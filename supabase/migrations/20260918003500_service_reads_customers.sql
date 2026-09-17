-- Perbaikan audit domain SERVIS (5/5): pembacaan tiket dan pelanggan.
-- Temuan: K12 (list selalu 42703), FR-CUS-01 (pencarian & kandidat mirip).
-- MAINTAINER hanya baca; kontak pelanggan disembunyikan darinya. Modal hanya OWNER/MAINTAINER.

create or replace function private.srv_like_escape(p_text text)
returns text language sql immutable set search_path = '' as $$
  select replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_')
$$;
revoke all on function private.srv_like_escape(text) from public, anon, authenticated;

-- list_service_tickets_v1 — OWNER/STAFF/MAINTAINER ---------------------------------------
create or replace function public.list_service_tickets_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_role text;
  v_statuses text[];
  v_query text;
  v_like text;
  v_phone text;
  v_include_closed boolean;
  v_not_picked boolean;
  v_location text;
  v_limit integer;
  v_cursor text;
  v_cur_ts timestamptz;
  v_cur_id uuid;
  v_items jsonb;
  v_count integer;
  v_next text;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  p_input := coalesce(p_input, '{}'::jsonb);
  perform private.srv_keys(p_input, array['status', 'query', 'include_closed', 'not_picked_up',
    'service_location', 'limit', 'cursor']);

  if jsonb_typeof(p_input->'status') = 'array' then
    select array_agg(x) into v_statuses from jsonb_array_elements_text(p_input->'status') x;
  elsif private.srv_text(p_input, 'status', 30) is not null then
    v_statuses := array[private.srv_text(p_input, 'status', 30)];
  end if;
  v_query := private.srv_text(p_input, 'query', 120);
  if v_query is not null then
    v_like := '%' || private.srv_like_escape(v_query) || '%';
    if v_query ~ '^[0-9 +().-]+$' and length(regexp_replace(v_query, '[^0-9]', '', 'g')) >= 3 then
      v_phone := private.normalize_phone(v_query);
    end if;
  end if;
  v_include_closed := coalesce(private.srv_bool(p_input, 'include_closed'), false);
  v_not_picked := coalesce(private.srv_bool(p_input, 'not_picked_up'), false);
  v_location := private.srv_text(p_input, 'service_location', 10);
  v_limit := coalesce(private.srv_int(p_input, 'limit', false, 1, 100), 25);
  v_cursor := private.srv_text(p_input, 'cursor', 100);
  if v_cursor is not null then
    begin
      v_cur_ts := split_part(v_cursor, '|', 1)::timestamptz;
      v_cur_id := split_part(v_cursor, '|', 2)::uuid;
    exception when others then
      raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
    end;
  end if;

  with page as (
    select t.*, c.name as customer_name, c.phone_normalized as customer_phone,
      c.alternate_contact as customer_alt_contact
    from private.service_tickets t
    left join private.customers c on c.id = t.customer_id
    where (v_statuses is null or t.work_status = any (v_statuses))
      and (v_include_closed or t.closed_at is null)
      and (v_location is null or t.service_location = v_location)
      and (v_query is null or t.number ilike v_like or c.name ilike v_like
        or t.equipment_type ilike v_like
        or (v_phone is not null and c.phone_normalized like '%' || v_phone || '%'))
      and (not v_not_picked or (private.srv_is_terminal(t.work_status)
        and t.custody_location in ('SHOP', 'FATHER') and t.closed_at is null))
      and (v_cur_ts is null or (t.created_at, t.id) < (v_cur_ts, v_cur_id))
    order by t.created_at desc, t.id desc
    limit v_limit + 1
  ), numbered as (
    select p.*, row_number() over (order by p.created_at desc, p.id desc) as rn from page p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', n.id, 'number', n.number,
      'customer_id', n.customer_id, 'customer_name', n.customer_name,
      'customer_phone', case when v_role = 'MAINTAINER' then null else n.customer_phone end,
      'customer_alt_contact', case when v_role = 'MAINTAINER' then null else n.customer_alt_contact end,
      'equipment_type', n.equipment_type, 'equipment_brand', n.equipment_brand,
      'equipment_model', n.equipment_model, 'complaint', left(n.complaint, 200),
      'work_status', n.work_status, 'service_location', n.service_location,
      'custody_location', n.custody_location, 'scheduled_at', n.scheduled_at,
      'parent_ticket_id', n.parent_ticket_id,
      'created_at', n.created_at, 'closed_at', n.closed_at, 'version', n.version,
      'not_picked_up', private.srv_is_terminal(n.work_status)
        and n.custody_location in ('SHOP', 'FATHER') and n.closed_at is null,
      'payment_status', s.status, 'invoice_total', s.invoice_net::text,
      'net_received', s.net_received::text, 'outstanding', s.outstanding::text, 'refund_due', s.refund_due::text)
      order by n.created_at desc, n.id desc) filter (where n.rn <= v_limit), '[]'::jsonb),
    count(*),
    max(case when n.rn = v_limit then n.created_at::text || '|' || n.id::text end)
  into v_items, v_count, v_next
  from numbered n
  cross join lateral private.srv_payment_state(n.id) s;

  return jsonb_build_object('items', v_items,
    'next_cursor', case when v_count > v_limit then v_next end);
end $$;

-- get_service_ticket_v1 — OWNER/STAFF/MAINTAINER --------------------------------------------
create or replace function public.get_service_ticket_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_role text;
  v_cost boolean;
  v_contact boolean;
  v_t private.service_tickets%rowtype;
  v_invoice private.invoices%rowtype;
  v_state record;
  v_approval private.service_estimates%rowtype;
  v_latest private.service_estimates%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  v_cost := v_role in ('OWNER', 'MAINTAINER');
  v_contact := v_role in ('OWNER', 'STAFF');
  perform private.srv_keys(p_input, array['ticket_id']);

  select * into v_t from private.service_tickets where id = private.srv_uuid(p_input, 'ticket_id');
  if not found then
    raise exception 'NOT_FOUND: Tiket servis tidak ditemukan' using errcode = 'P0002';
  end if;
  select * into v_invoice from private.invoices where service_ticket_id = v_t.id;
  select * into v_state from private.srv_payment_state(v_t.id);
  select * into v_latest from private.service_estimates where ticket_id = v_t.id order by revision desc limit 1;
  select * into v_approval from private.service_estimates
    where ticket_id = v_t.id and status = 'APPROVED' order by revision desc limit 1;

  return jsonb_build_object(
    'id', v_t.id, 'number', v_t.number, 'version', v_t.version,
    'work_status', v_t.work_status, 'service_location', v_t.service_location,
    'custody_location', v_t.custody_location,
    'equipment_type', v_t.equipment_type, 'equipment_brand', v_t.equipment_brand,
    'equipment_model', v_t.equipment_model, 'equipment_serial', v_t.equipment_serial,
    'complaint', v_t.complaint, 'initial_condition', v_t.initial_condition, 'accessories', v_t.accessories,
    'address', case when v_contact then v_t.address end, 'scheduled_at', v_t.scheduled_at,
    'terminal_reason', v_t.terminal_reason, 'test_result', v_t.test_result,
    'created_at', v_t.created_at, 'closed_at', v_t.closed_at,
    'mechanic_name', (select display_name from private.app_profiles where id = v_t.mechanic_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.name,
        'phone', case when v_contact then c.phone_normalized end,
        'alternate_contact', case when v_contact then c.alternate_contact end,
        'address', case when v_contact then c.address end, 'version', c.version)
      from private.customers c where c.id = v_t.customer_id),
    'parent_ticket', (select jsonb_build_object('id', p.id, 'number', p.number, 'work_status', p.work_status,
        'created_at', p.created_at, 'closed_at', p.closed_at)
      from private.service_tickets p where p.id = v_t.parent_ticket_id),
    'child_tickets', (select coalesce(jsonb_agg(jsonb_build_object('id', ch.id, 'number', ch.number,
        'work_status', ch.work_status, 'created_at', ch.created_at) order by ch.created_at), '[]'::jsonb)
      from private.service_tickets ch where ch.parent_ticket_id = v_t.id),
    'not_picked_up', private.srv_is_terminal(v_t.work_status)
      and v_t.custody_location in ('SHOP', 'FATHER') and v_t.closed_at is null,
    'allowed_transitions', case when v_t.closed_at is null and v_invoice.id is null
      then to_jsonb(private.srv_allowed_targets(v_t.work_status)) else '[]'::jsonb end,
    'approval', jsonb_build_object(
      'latest_revision', v_latest.revision, 'latest_status', v_latest.status,
      'active', v_latest.status = 'APPROVED',
      'approved_revision', v_approval.revision, 'approved_limit', v_approval.approved_limit::text),
    'status_events', (select coalesce(jsonb_agg(jsonb_build_object(
        'from_status', e.from_status, 'to_status', e.to_status, 'kind', e.kind, 'reason', e.reason,
        'actor_name', a.display_name, 'occurred_at', e.occurred_at) order by e.id), '[]'::jsonb)
      from private.service_status_events e left join private.app_profiles a on a.id = e.actor_id
      where e.ticket_id = v_t.id),
    'custody_events', (select coalesce(jsonb_agg(jsonb_build_object(
        'from_location', e.from_location, 'to_location', e.to_location,
        'condition_note', e.condition_note, 'accessories_note', e.accessories_note,
        'receiver_name', e.receiver_name, 'is_handover', e.is_handover,
        'actor_name', a.display_name, 'occurred_at', e.occurred_at) order by e.id), '[]'::jsonb)
      from private.service_custody_events e left join private.app_profiles a on a.id = e.actor_id
      where e.ticket_id = v_t.id),
    'estimates', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'revision', e.revision, 'description', e.description,
        'min_amount', e.min_amount::text, 'max_amount', e.max_amount::text, 'status', e.status,
        'approved_limit', e.approved_limit::text, 'approved_method', e.approved_method,
        'approved_at', e.approved_at, 'approved_by_name', a.display_name,
        'consent_note', e.customer_consent_note, 'version', e.version) order by e.revision), '[]'::jsonb)
      from private.service_estimates e left join private.app_profiles a on a.id = e.approved_by
      where e.ticket_id = v_t.id),
    'part_events', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'kind', e.kind, 'product_id', e.product_id, 'product_name', pr.name,
        'sku', pr.sku, 'base_unit', pr.base_unit, 'qty', e.qty_base::text,
        'net_qty', case when e.kind = 'USE' then private.srv_use_net_qty(e.id)::text end,
        'charge_unit_price', e.charge_unit_price::text, 'reverses_event_id', e.reverses_event_id,
        'reason', e.reason, 'actor_name', a.display_name, 'occurred_at', e.occurred_at,
        'invoiced', e.recognized_invoice_id is not null,
        'source_location', (select sp.location from private.cost_allocations ca
          join private.stock_positions sp on sp.id = ca.origin_position_id
          where ca.service_part_event_id = e.id order by ca.id limit 1),
        'source_label', (select sp.label from private.cost_allocations ca
          join private.stock_positions sp on sp.id = ca.origin_position_id
          where ca.service_part_event_id = e.id order by ca.id limit 1),
        'cost', case when not v_cost then null
          when e.kind = 'USE' then (select sum(ca.cost_amount - ca.reversed_cost) from private.cost_allocations ca
            where ca.service_part_event_id = e.id)::text
          else (select sum(ra.cost_amount) from private.part_reversal_allocations ra
            where ra.reversal_event_id = e.id)::text end)
        order by e.occurred_at, e.id), '[]'::jsonb)
      from private.service_part_events e
      join private.products pr on pr.id = e.product_id
      left join private.app_profiles a on a.id = e.actor_id
      where e.ticket_id = v_t.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'direction', p.direction, 'purpose', p.purpose, 'method', p.method,
        'amount', p.amount::text, 'tendered', p.tendered::text, 'change', p.change::text,
        'cashbox', cs.cashbox_id, 'reference', p.reference, 'original_payment_id', p.original_payment_id,
        'actor_name', a.display_name, 'occurred_at', p.occurred_at) order by p.occurred_at, p.id), '[]'::jsonb)
      from private.payments p
      left join private.cash_sessions cs on cs.id = p.cash_session_id
      left join private.app_profiles a on a.id = p.actor_id
      where p.service_ticket_id = v_t.id),
    'invoice', case when v_invoice.id is null then null else jsonb_build_object(
      'id', v_invoice.id, 'number', v_invoice.number, 'total', v_invoice.total::text,
      'posted_at', v_invoice.posted_at,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', ii.id, 'line_no', ii.line_no, 'kind', ii.kind, 'description', ii.description_snapshot,
          'quantity', ii.qty_sell::text, 'unit_price', ii.unit_price_snapshot::text,
          'net_total', ii.net_total::text, 'service_part_event_id', ii.service_part_event_id,
          'credited', (select coalesce(sum(ci.amount), 0) from private.credit_note_items ci
            where ci.invoice_item_id = ii.id)::text) order by ii.line_no), '[]'::jsonb)
        from private.invoice_items ii where ii.invoice_id = v_invoice.id),
      'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', cn.id, 'number', cn.number, 'total', cn.total::text, 'reason', cn.reason,
          'posted_at', cn.posted_at) order by cn.posted_at), '[]'::jsonb)
        from private.credit_notes cn where cn.invoice_id = v_invoice.id),
      'cost_recognized', case when v_cost then (select coalesce(sum(r.cost_amount), 0)
        from private.service_cost_recognitions r where r.invoice_id = v_invoice.id)::text end)
    end,
    'payment', private.srv_payment_state_json(v_t.id));
end $$;

-- Pelanggan -------------------------------------------------------------------------------

create or replace function private.srv_similar_customers(p_name text, p_phone text, p_exclude uuid, p_contact boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.obj order by x.score desc, x.name), '[]'::jsonb) from (
    select c.name,
      (case when p_phone is not null and c.phone_normalized = p_phone then 2 else 0 end
        + case when p_name is not null and lower(c.name) = lower(p_name) then 2
               when p_name is not null and length(p_name) >= 3
                 and (lower(c.name) like '%' || private.srv_like_escape(lower(p_name)) || '%'
                   or lower(p_name) like '%' || private.srv_like_escape(lower(c.name)) || '%') then 1
               else 0 end) as score,
      jsonb_build_object('id', c.id, 'name', c.name,
        'phone', case when p_contact then c.phone_normalized end,
        'alternate_contact', case when p_contact then c.alternate_contact end,
        'address', case when p_contact then c.address end, 'version', c.version,
        'match', array_remove(array[
          case when p_phone is not null and c.phone_normalized = p_phone then 'PHONE' end,
          case when p_name is not null and (lower(c.name) = lower(p_name) or (length(p_name) >= 3
            and (lower(c.name) like '%' || private.srv_like_escape(lower(p_name)) || '%'
              or lower(p_name) like '%' || private.srv_like_escape(lower(c.name)) || '%'))) then 'NAME' end], null)) as obj
    from private.customers c
    where c.active and (p_exclude is null or c.id <> p_exclude)
    order by 2 desc, c.name limit 50
  ) x where x.score > 0
$$;
revoke all on function private.srv_similar_customers(text, text, uuid, boolean) from public, anon, authenticated;

-- Simpan pelanggan (baru atau ubah). Tidak pernah menggabungkan otomatis.
create or replace function private.srv_save_customer(p_command text, p_input jsonb, p_allow_update boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_old jsonb;
  v_id uuid;
  v_name text;
  v_phone text;
  v_alt text;
  v_address text;
  v_row private.customers%rowtype;
  v_version integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  perform private.srv_keys(p_input, case when p_allow_update
    then array['operation_id', 'customer_id', 'expected_version', 'name', 'phone', 'alternate_contact', 'address']
    else array['operation_id', 'name', 'phone', 'alternate_contact', 'address'] end);
  v_old := private.srv_begin(p_command, p_input);
  if v_old is not null then return v_old; end if;

  v_name := private.srv_text(p_input, 'name', 120, true);
  v_phone := private.srv_phone(private.srv_text(p_input, 'phone', 40));
  v_alt := private.srv_text(p_input, 'alternate_contact', 120);
  v_address := private.srv_text(p_input, 'address', 500);
  if v_phone is null and v_alt is null then
    raise exception 'CONTACT_REQUIRED: Isi nomor HP atau kontak lain pelanggan' using errcode = '22023';
  end if;

  v_id := case when p_allow_update then private.srv_uuid(p_input, 'customer_id', false) end;
  if v_id is not null then
    select * into v_row from private.customers where id = v_id for update;
    if not found then
      raise exception 'NOT_FOUND: Pelanggan tidak ditemukan' using errcode = 'P0002';
    end if;
    if v_row.version <> private.srv_int(p_input, 'expected_version', true, 1, 2147483647) then
      raise exception 'VERSION_CONFLICT: Data pelanggan sudah berubah. Muat ulang lalu periksa kembali.' using errcode = '40001';
    end if;
    update private.customers set name = v_name, phone_normalized = v_phone, alternate_contact = v_alt,
      address = v_address, version = version + 1
      where id = v_id returning version into v_version;
  else
    insert into private.customers(name, phone_normalized, alternate_contact, address)
    values (v_name, v_phone, v_alt, v_address) returning id, version into v_id, v_version;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id)
  values (v_actor, 'UPSERT_CUSTOMER', 'CUSTOMER', v_id);

  return private.finish_operation(p_command, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_id, 'customer_id', v_id, 'version', v_version, 'phone', v_phone,
    'similar_customers', private.srv_similar_customers(v_name, v_phone, v_id, true)));
end $$;
revoke all on function private.srv_save_customer(text, jsonb, boolean) from public, anon, authenticated;

create or replace function public.create_customer_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.srv_save_customer('create_customer_v1', p_input, false);
end $$;

create or replace function public.upsert_customer_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.srv_save_customer('upsert_customer_v1', p_input, true);
end $$;

-- search_customers_v1 — mengembalikan array (kompatibel). Nama mengandung / HP ternormalisasi.
create or replace function public.search_customers_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_contact boolean;
  v_query text;
  v_phone text;
  v_limit integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  v_contact := (select role from private.app_profiles where id = v_actor) <> 'MAINTAINER';
  p_input := coalesce(p_input, '{}'::jsonb);
  perform private.srv_keys(p_input, array['query', 'phone', 'limit']);
  v_query := private.srv_text(p_input, 'query', 120);
  v_limit := coalesce(private.srv_int(p_input, 'limit', false, 1, 100), 25);
  if private.srv_text(p_input, 'phone', 40) is not null then
    v_phone := private.normalize_phone(private.srv_text(p_input, 'phone', 40));
  elsif v_query ~ '^[0-9 +().-]+$' and length(regexp_replace(v_query, '[^0-9]', '', 'g')) >= 3 then
    v_phone := private.normalize_phone(v_query);
    v_query := null;
  end if;

  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name,
      'phone', case when v_contact then c.phone_normalized end,
      'alternate_contact', case when v_contact then c.alternate_contact end,
      'address', case when v_contact then c.address end,
      'version', c.version,
      'open_tickets', (select count(*) from private.service_tickets t where t.customer_id = c.id and t.closed_at is null),
      'last_ticket_at', (select max(t.created_at) from private.service_tickets t where t.customer_id = c.id))
      order by c.name, c.id), '[]'::jsonb)
    from (select * from private.customers c
      where c.active
        and (v_query is null or c.name ilike '%' || private.srv_like_escape(v_query) || '%')
        and (v_phone is null or c.phone_normalized like '%' || v_phone || '%')
      order by c.name, c.id limit v_limit) c);
end $$;

-- find_similar_customers_v1 — kandidat sebelum membuat pelanggan baru (tanpa merge otomatis).
create or replace function public.find_similar_customers_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_name text; v_phone text;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.srv_keys(p_input, array['name', 'phone']);
  v_name := private.srv_text(p_input, 'name', 120);
  v_phone := private.normalize_phone(private.srv_text(p_input, 'phone', 40));
  if v_name is null and v_phone is null then
    raise exception 'INVALID_INPUT: Isi nama atau nomor HP' using errcode = '22023';
  end if;
  return jsonb_build_object('candidates', private.srv_similar_customers(v_name, v_phone, null,
    (select role from private.app_profiles where id = v_actor) <> 'MAINTAINER'));
end $$;

-- list_customer_history_v1 — riwayat servis & nota pelanggan (tanpa modal).
create or replace function public.list_customer_history_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_contact boolean; v_c private.customers%rowtype; v_limit integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  v_contact := (select role from private.app_profiles where id = v_actor) <> 'MAINTAINER';
  perform private.srv_keys(p_input, array['customer_id', 'limit']);
  v_limit := coalesce(private.srv_int(p_input, 'limit', false, 1, 100), 50);
  select * into v_c from private.customers where id = private.srv_uuid(p_input, 'customer_id');
  if not found then
    raise exception 'NOT_FOUND: Pelanggan tidak ditemukan' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_c.id, 'name', v_c.name,
      'phone', case when v_contact then v_c.phone_normalized end,
      'alternate_contact', case when v_contact then v_c.alternate_contact end,
      'address', case when v_contact then v_c.address end, 'version', v_c.version),
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'number', t.number, 'equipment_type', t.equipment_type, 'complaint', left(t.complaint, 200),
        'work_status', t.work_status, 'service_location', t.service_location,
        'parent_ticket_id', t.parent_ticket_id, 'created_at', t.created_at, 'closed_at', t.closed_at,
        'payment_status', s.status, 'invoice_total', s.invoice_net::text) order by t.created_at desc), '[]'::jsonb)
      from (select * from private.service_tickets where customer_id = v_c.id
        order by created_at desc limit v_limit) t
      cross join lateral private.srv_payment_state(t.id) s),
    'sale_invoices', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'number', i.number, 'posted_at', i.posted_at, 'total', i.total::text)
        order by i.posted_at desc), '[]'::jsonb)
      from (select * from private.invoices where customer_id = v_c.id and kind = 'SALE'
        order by posted_at desc limit v_limit) i));
end $$;

do $$ declare f text; begin
  foreach f in array array['list_service_tickets_v1', 'get_service_ticket_v1', 'create_customer_v1',
    'upsert_customer_v1', 'search_customers_v1', 'find_similar_customers_v1', 'list_customer_history_v1']
  loop
    execute format('revoke all on function public.%I(jsonb) from public, anon, authenticated', f);
    execute format('grant execute on function public.%I(jsonb) to authenticated', f);
  end loop;
end $$;
