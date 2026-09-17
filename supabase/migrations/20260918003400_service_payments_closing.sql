-- Perbaikan audit domain SERVIS (4/5): pembayaran, refund, status bayar, serah terima, tutup.
-- Temuan: K07 (BR-10/BR-11), K09 (BR-07/BR-12).

-- record_service_payment_v1 — OWNER/STAFF -----------------------------------------------
create or replace function public.record_service_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'record_service_payment_v1';
  v_actor uuid;
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_state record;
  v_amount numeric;
  v_method text;
  v_purpose text;
  v_cashbox text;
  v_tendered numeric;
  v_change numeric;
  v_confirmed boolean;
  v_intent uuid;
  v_expected integer;
  v_session private.cash_sessions%rowtype;
  v_payment_id uuid;
  v_occurred timestamptz;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'payment_intent_id',
    'purpose', 'amount', 'method', 'cashbox', 'tendered', 'confirmed', 'reference']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_expected := private.srv_int(p_input, 'expected_version', false, 1, 2147483647);
  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'), v_expected);
  perform private.srv_require_open(v_ticket);

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999);
  v_method := private.srv_text(p_input, 'method', 10, true);
  if v_method not in ('CASH', 'TRANSFER', 'QRIS') then
    raise exception 'INVALID_INPUT: Metode bayar harus CASH, TRANSFER atau QRIS' using errcode = '22023';
  end if;
  v_purpose := private.srv_text(p_input, 'purpose', 20);
  if v_purpose is not null and v_purpose not in ('DEPOSIT', 'SETTLEMENT') then
    raise exception 'INVALID_INPUT: Jenis pembayaran harus DEPOSIT (uang muka) atau SETTLEMENT (pelunasan)' using errcode = '22023';
  end if;
  v_intent := private.srv_uuid(p_input, 'payment_intent_id', false);
  if v_intent is not null and exists (select 1 from private.payments where intent_id = v_intent) then
    raise exception 'IDEMPOTENCY_CONFLICT: Pembayaran ini sudah pernah dicatat' using errcode = '22023';
  end if;

  -- Sebelum final: DP (boleh beberapa). Sesudah final: tepat sebesar sisa.
  select * into v_state from private.srv_payment_state(v_ticket.id);
  if v_state.invoice_id is null then
    if v_purpose = 'SETTLEMENT' then
      raise exception 'INVALID_INPUT: Tagihan belum final; pembayaran dicatat sebagai uang muka' using errcode = '22023';
    end if;
    v_purpose := 'DEPOSIT';
  else
    if v_purpose = 'DEPOSIT' then
      raise exception 'INVALID_INPUT: Tagihan sudah final; uang muka tidak dapat ditambah' using errcode = '22023';
    end if;
    if v_state.outstanding = 0 then
      raise exception 'ALREADY_SETTLED: Tagihan servis sudah lunas' using errcode = '22023';
    end if;
    if v_amount <> v_state.outstanding then
      raise exception 'PAYMENT_AMOUNT_MISMATCH: Pelunasan harus tepat sebesar sisa tagihan Rp%', v_state.outstanding::text
        using errcode = '22023';
    end if;
    v_purpose := 'SETTLEMENT';
  end if;

  if v_method = 'CASH' then
    v_cashbox := coalesce(private.srv_text(p_input, 'cashbox', 20), 'SHOP_DRAWER');
    if v_cashbox not in ('SHOP_DRAWER', 'FATHER_WALLET') then
      raise exception 'INVALID_INPUT: Kas harus SHOP_DRAWER (laci toko) atau FATHER_WALLET (dompet ayah)' using errcode = '22023';
    end if;
    if v_cashbox = 'FATHER_WALLET' and v_role <> 'OWNER' then
      raise exception 'FORBIDDEN: Hanya pemilik yang dapat menerima uang ke dompet ayah' using errcode = '42501';
    end if;
    if p_input ? 'confirmed' and private.srv_bool(p_input, 'confirmed') is not null then
      raise exception 'INVALID_INPUT: Konfirmasi hanya untuk transfer/QRIS' using errcode = '22023';
    end if;
    v_tendered := private.decimal_input_opt(p_input->'tendered', 0, 9999999999999999);
    if v_tendered is null then
      raise exception 'TENDERED_REQUIRED: Isi uang yang diterima dari pelanggan' using errcode = '22023';
    end if;
    if v_tendered < v_amount then
      raise exception 'INSUFFICIENT_TENDERED: Uang diterima kurang dari jumlah yang dibayar' using errcode = '22023';
    end if;
    v_change := v_tendered - v_amount;
    v_session := private.lock_open_cash_session(v_cashbox);
  else
    if private.srv_text(p_input, 'cashbox', 20) is not null
       or private.decimal_input_opt(p_input->'tendered', 0, 9999999999999999) is not null then
      raise exception 'INVALID_INPUT: Kas dan uang diterima hanya untuk pembayaran tunai' using errcode = '22023';
    end if;
    v_confirmed := private.srv_bool(p_input, 'confirmed');
    if v_confirmed is distinct from true then
      raise exception 'CONFIRMATION_REQUIRED: Pastikan dana transfer/QRIS benar-benar masuk lalu centang konfirmasi' using errcode = '22023';
    end if;
  end if;

  insert into private.payments(direction, purpose, service_ticket_id, method, amount, tendered, change,
    cash_session_id, reference, confirmed_by, actor_id, intent_id, operation_id)
  values ('IN', 'SERVICE_RECEIPT', v_ticket.id, v_method, v_amount, v_tendered, v_change,
    v_session.id, private.srv_text(p_input, 'reference', 100),
    case when v_method <> 'CASH' then v_actor end, v_actor, v_intent, (p_input->>'operation_id')::uuid)
  returning id, occurred_at into v_payment_id, v_occurred;

  if v_method = 'CASH' then
    insert into private.cash_movements(session_id, direction, kind, amount, payment_id, reason, actor_id, operation_id)
    values (v_session.id, 'IN', 'CUSTOMER_PAYMENT', v_amount, v_payment_id,
      'Servis ' || v_ticket.number, v_actor, (p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'SERVICE_PAYMENT', 'PAYMENT', v_payment_id, v_purpose || ' ' || v_ticket.number);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_payment_id, 'payment_id', v_payment_id, 'purpose', v_purpose,
    'method', v_method, 'cashbox', v_cashbox, 'amount', v_amount::text,
    'tendered', v_tendered::text, 'change', v_change::text, 'occurred_at', v_occurred,
    'ticket_id', v_ticket.id, 'ticket_number', v_ticket.number,
    'actor_name', (select display_name from private.app_profiles where id = v_actor),
    'payment', private.srv_payment_state_json(v_ticket.id), 'version', v_ticket.version));
end $$;

-- refund_service_payment_v1 — OWNER ------------------------------------------------------
create or replace function public.refund_service_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'refund_service_payment_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_state record;
  v_amount numeric;
  v_limit numeric;
  v_method text;
  v_cashbox text;
  v_reason text;
  v_session private.cash_sessions%rowtype;
  v_receipt record;
  v_left numeric;
  v_take numeric;
  v_first uuid;
  v_refund_id uuid;
  v_allocs jsonb := '[]'::jsonb;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'amount', 'method',
    'cashbox', 'confirmed', 'reference', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', false, 1, 2147483647));
  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999);
  v_reason := private.srv_text(p_input, 'reason', 500, true);
  v_method := private.srv_text(p_input, 'method', 10, true);
  if v_method not in ('CASH', 'TRANSFER', 'QRIS') then
    raise exception 'INVALID_INPUT: Metode refund harus CASH, TRANSFER atau QRIS' using errcode = '22023';
  end if;

  select * into v_state from private.srv_payment_state(v_ticket.id);
  if v_state.invoice_id is not null then
    v_limit := v_state.refund_due;
  elsif v_ticket.work_status = 'CANCELLED' then
    v_limit := v_state.net_received;
  else
    raise exception 'INVOICE_REQUIRED: Uang muka hanya dapat dikembalikan setelah tagihan final atau tiket dibatalkan' using errcode = '22023';
  end if;
  if v_amount > v_limit then
    raise exception 'REFUND_LIMIT_EXCEEDED: Pengembalian melebihi hak pelanggan (maksimal Rp%)', v_limit::text using errcode = '22023';
  end if;

  if v_method = 'CASH' then
    v_cashbox := coalesce(private.srv_text(p_input, 'cashbox', 20), 'SHOP_DRAWER');
    if v_cashbox not in ('SHOP_DRAWER', 'FATHER_WALLET') then
      raise exception 'INVALID_INPUT: Kas harus SHOP_DRAWER atau FATHER_WALLET' using errcode = '22023';
    end if;
    v_session := private.lock_open_cash_session(v_cashbox);
    if private.cash_session_expected(v_session.id) < v_amount then
      raise exception 'INSUFFICIENT_CASH: Saldo kas tidak cukup untuk pengembalian ini' using errcode = '22023';
    end if;
  else
    if private.srv_text(p_input, 'cashbox', 20) is not null then
      raise exception 'INVALID_INPUT: Kas hanya untuk refund tunai' using errcode = '22023';
    end if;
    if private.srv_bool(p_input, 'confirmed') is distinct from true then
      raise exception 'CONFIRMATION_REQUIRED: Pastikan transfer pengembalian sudah dikirim lalu centang konfirmasi' using errcode = '22023';
    end if;
  end if;

  -- Kunci receipt asal menurut id, lalu alokasikan mulai yang terlama.
  perform 1 from private.payments p
    where p.service_ticket_id = v_ticket.id and p.direction = 'IN'
      and p.purpose in ('SERVICE_RECEIPT', 'PAYMENT_REPLACEMENT')
    order by p.id for update;

  insert into private.payments(direction, purpose, service_ticket_id, method, amount, cash_session_id,
    reference, confirmed_by, actor_id, operation_id)
  values ('OUT', 'CUSTOMER_REFUND', v_ticket.id, v_method, v_amount, v_session.id,
    private.srv_text(p_input, 'reference', 100), case when v_method <> 'CASH' then v_actor end,
    v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_refund_id;

  v_left := v_amount;
  for v_receipt in select * from private.srv_receipt_balances(v_ticket.id)
      where balance > 0 order by occurred_at, payment_id loop
    exit when v_left = 0;
    v_take := least(v_left, v_receipt.balance);
    insert into private.refund_allocations(refund_payment_id, original_payment_id, amount)
    values (v_refund_id, v_receipt.payment_id, v_take);
    v_first := coalesce(v_first, v_receipt.payment_id);
    v_allocs := v_allocs || jsonb_build_object('payment_id', v_receipt.payment_id, 'amount', v_take::text);
    v_left := v_left - v_take;
  end loop;
  if v_left > 0 then
    raise exception 'REFUND_LIMIT_EXCEEDED: Sisa penerimaan pelanggan tidak cukup untuk pengembalian ini' using errcode = '22023';
  end if;
  update private.payments set original_payment_id = v_first where id = v_refund_id;

  if v_method = 'CASH' then
    insert into private.cash_movements(session_id, direction, kind, amount, payment_id, reason, actor_id, operation_id)
    values (v_session.id, 'OUT', 'REFUND', v_amount, v_refund_id, v_reason, v_actor, (p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REFUND_SERVICE_PAYMENT', 'PAYMENT', v_refund_id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_refund_id, 'payment_id', v_refund_id, 'amount', v_amount::text,
    'method', v_method, 'cashbox', v_cashbox, 'allocations', v_allocs,
    'ticket_id', v_ticket.id, 'payment', private.srv_payment_state_json(v_ticket.id),
    'version', v_ticket.version));
end $$;

-- get_service_payment_status_v1 — OWNER/STAFF/MAINTAINER ---------------------------------
create or replace function public.get_service_payment_status_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.srv_keys(p_input, array['ticket_id']);
  v_id := private.srv_uuid(p_input, 'ticket_id');
  if not exists (select 1 from private.service_tickets where id = v_id) then
    raise exception 'NOT_FOUND: Tiket servis tidak ditemukan' using errcode = 'P0002';
  end if;
  return private.srv_payment_state_json(v_id) || jsonb_build_object('ticket_id', v_id);
end $$;

-- Syarat bersama penutupan layanan (BR-10/BR-11).
create or replace function private.srv_require_settled(p_ticket private.service_tickets)
returns void language plpgsql stable security definer set search_path = '' as $$
declare v_state record;
begin
  if not private.srv_is_terminal(p_ticket.work_status) then
    raise exception 'INVALID_TRANSITION: Pekerjaan belum berstatus akhir (selesai/tidak bisa diperbaiki/batal)' using errcode = '22023';
  end if;
  select * into v_state from private.srv_payment_state(p_ticket.id);
  if v_state.invoice_id is null then
    raise exception 'INVOICE_REQUIRED: Tagihan final belum dibuat' using errcode = '22023';
  end if;
  if v_state.outstanding > 0 then
    raise exception 'PAYMENT_OUTSTANDING: Masih ada sisa tagihan Rp% yang belum dibayar', v_state.outstanding::text using errcode = '22023';
  end if;
  if v_state.refund_due > 0 then
    raise exception 'REFUND_DUE: Masih ada kelebihan bayar Rp% yang harus dikembalikan', v_state.refund_due::text using errcode = '22023';
  end if;
end $$;
revoke all on function private.srv_require_settled(private.service_tickets) from public, anon, authenticated;

-- handover_service_v1 — OWNER/STAFF ---------------------------------------------------------
create or replace function public.handover_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'handover_service_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_receiver text;
  v_now timestamptz := now();
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'receiver_name',
    'condition_note', 'accessories_note']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  v_receiver := private.srv_text(p_input, 'receiver_name', 120, true);
  if v_ticket.custody_location not in ('SHOP', 'FATHER') then
    raise exception 'INVALID_CUSTODY: Alat tidak sedang dititipkan; gunakan Tutup Layanan' using errcode = '22023';
  end if;
  perform private.srv_require_settled(v_ticket);

  update private.service_tickets set custody_location = 'CUSTOMER', closed_at = v_now, version = version + 1
    where id = v_ticket.id;
  insert into private.service_custody_events(ticket_id, from_location, to_location, condition_note,
    accessories_note, receiver_name, is_handover, actor_id, occurred_at)
  values (v_ticket.id, v_ticket.custody_location, 'CUSTOMER', private.srv_text(p_input, 'condition_note', 1000),
    private.srv_text(p_input, 'accessories_note', 500), v_receiver, true, v_actor, v_now);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'HANDOVER_SERVICE', 'SERVICE_TICKET', v_ticket.id, 'Diterima oleh ' || v_receiver);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', v_now,
    'entity_id', v_ticket.id, 'custody_location', 'CUSTOMER', 'receiver_name', v_receiver,
    'closed_at', v_now, 'version', v_ticket.version + 1));
end $$;

-- close_onsite_service_v1 — OWNER; alat tetap di pelanggan ------------------------------------
create or replace function public.close_onsite_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'close_onsite_service_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_now timestamptz := now();
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'completion_note']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if v_ticket.custody_location <> 'CUSTOMER' then
    raise exception 'INVALID_CUSTODY: Alat masih dititipkan; gunakan Serah Terima' using errcode = '22023';
  end if;
  perform private.srv_require_settled(v_ticket);

  update private.service_tickets set closed_at = v_now, version = version + 1 where id = v_ticket.id;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CLOSE_ONSITE', 'SERVICE_TICKET', v_ticket.id, private.srv_text(p_input, 'completion_note', 1000));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', v_now,
    'entity_id', v_ticket.id, 'closed_at', v_now, 'version', v_ticket.version + 1));
end $$;

do $$ declare f text; begin
  foreach f in array array['record_service_payment_v1', 'refund_service_payment_v1',
    'get_service_payment_status_v1', 'handover_service_v1', 'close_onsite_service_v1']
  loop
    execute format('revoke all on function public.%I(jsonb) from public, anon, authenticated', f);
    execute format('grant execute on function public.%I(jsonb) to authenticated', f);
  end loop;
end $$;
