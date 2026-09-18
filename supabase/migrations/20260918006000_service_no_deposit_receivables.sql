-- Keputusan pemilik 18 September 2026 (servis):
--   * tidak ada uang muka: pembayaran diterima setelah tagihan dibuat dari hasil pemeriksaan & part;
--   * uang jasa boleh dicicil (tidak harus langsung lunas);
--   * pemilik boleh menyerahkan alat / menutup kunjungan dengan sisa tagihan (piutang servis).
-- Layanan "selesai" (completed_at) saat diserahkan/kunjungan ditutup; tiket "ditutup" (closed_at) baru saat lunas.

alter table private.service_tickets add column if not exists completed_at timestamptz;
alter table private.service_tickets add column if not exists receivable_note text;
update private.service_tickets set completed_at = closed_at where closed_at is not null and completed_at is null;
alter table private.service_tickets drop constraint if exists service_tickets_closed_requires_completed;
alter table private.service_tickets add constraint service_tickets_closed_requires_completed
  check (closed_at is null or completed_at is not null);
create index if not exists service_tickets_receivable on private.service_tickets(completed_at)
  where completed_at is not null and closed_at is null;

-- Perubahan pekerjaan ditolak setelah layanan selesai; uang memakai srv_require_payable.
create or replace function private.srv_require_open(p_ticket private.service_tickets)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_ticket.closed_at is not null then
    raise exception 'TICKET_CLOSED: Tiket sudah ditutup. Buat tiket baru bila ada pekerjaan tambahan.' using errcode = '22023';
  end if;
  if p_ticket.completed_at is not null then
    raise exception 'TICKET_COMPLETED: Layanan sudah selesai; hanya pembayaran sisa tagihan yang dapat dicatat.'
      using errcode = '22023';
  end if;
end $$;

create or replace function private.srv_require_payable(p_ticket private.service_tickets)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_ticket.closed_at is not null then
    raise exception 'TICKET_CLOSED: Tiket sudah ditutup dan lunas.' using errcode = '22023';
  end if;
end $$;

-- Tutup layanan yang sudah selesai begitu lunas tanpa kelebihan bayar. Pemanggil memegang kunci tiket.
create or replace function private.srv_close_if_settled(p_ticket uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_state record;
begin
  select * into v_state from private.srv_payment_state(p_ticket);
  if v_state.invoice_id is null or v_state.outstanding > 0 or v_state.refund_due > 0 then
    return false;
  end if;
  update private.service_tickets set closed_at = now(), receivable_note = null
    where id = p_ticket and completed_at is not null and closed_at is null;
  return found;
end $$;

-- Syarat menyelesaikan layanan (serah terima / tutup kunjungan). Mengembalikan sisa tagihan.
-- Sisa tagihan hanya boleh atas keputusan pemilik dengan catatan; kelebihan bayar harus dikembalikan dulu.
create or replace function private.srv_require_completable(p_ticket private.service_tickets, p_allow_unpaid boolean,
  p_role text, p_note text)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare v_state record;
begin
  if not private.srv_is_terminal(p_ticket.work_status) then
    raise exception 'INVALID_TRANSITION: Pekerjaan belum berstatus akhir (selesai/tidak bisa diperbaiki/batal)' using errcode = '22023';
  end if;
  select * into v_state from private.srv_payment_state(p_ticket.id);
  if v_state.invoice_id is null then
    raise exception 'INVOICE_REQUIRED: Tagihan servis belum dibuat' using errcode = '22023';
  end if;
  if v_state.refund_due > 0 then
    raise exception 'REFUND_DUE: Masih ada kelebihan bayar Rp% yang harus dikembalikan', v_state.refund_due::text using errcode = '22023';
  end if;
  if v_state.outstanding > 0 then
    if not coalesce(p_allow_unpaid, false) then
      raise exception 'PAYMENT_OUTSTANDING: Masih ada sisa tagihan Rp%. Terima pembayaran, atau pemilik dapat menyerahkan dengan sisa tagihan.',
        v_state.outstanding::text using errcode = '22023';
    end if;
    if p_role is distinct from 'OWNER' then
      raise exception 'FORBIDDEN: Hanya pemilik yang dapat menyerahkan alat dengan sisa tagihan' using errcode = '42501';
    end if;
    if coalesce(length(trim(p_note)), 0) < 3 then
      raise exception 'REASON_REQUIRED: Tulis catatan kapan sisa tagihan akan dibayar' using errcode = '22023';
    end if;
  end if;
  return v_state.outstanding;
end $$;
revoke all on function private.srv_require_settled(private.service_tickets) from public, anon, authenticated;


-- Pembayaran servis: setelah tagihan, boleh dicicil; lunas menutup layanan yang sudah selesai.
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
  perform private.srv_require_payable(v_ticket);

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999);
  v_method := private.srv_text(p_input, 'method', 10, true);
  if v_method not in ('CASH', 'TRANSFER', 'QRIS') then
    raise exception 'INVALID_INPUT: Metode bayar harus CASH, TRANSFER atau QRIS' using errcode = '22023';
  end if;
  v_purpose := private.srv_text(p_input, 'purpose', 20);
  if v_purpose is not null and v_purpose <> 'SETTLEMENT' then
    raise exception 'INVALID_INPUT: Uang muka tidak dipakai; pembayaran dicatat setelah tagihan dibuat' using errcode = '22023';
  end if;
  v_intent := private.srv_uuid(p_input, 'payment_intent_id', false);
  if v_intent is not null and exists (select 1 from private.payments where intent_id = v_intent) then
    raise exception 'IDEMPOTENCY_CONFLICT: Pembayaran ini sudah pernah dicatat' using errcode = '22023';
  end if;

  -- Tanpa uang muka: bayar setelah tagihan dibuat; boleh dicicil sampai sisa tagihan.
  select * into v_state from private.srv_payment_state(v_ticket.id);
  if v_state.invoice_id is null then
    raise exception 'INVOICE_REQUIRED: Tagihan servis belum dibuat. Pembayaran diterima setelah tagihan dibuat.' using errcode = '22023';
  end if;
  if v_state.outstanding = 0 then
    raise exception 'ALREADY_SETTLED: Tagihan servis sudah lunas' using errcode = '22023';
  end if;
  if v_amount > v_state.outstanding then
    raise exception 'PAYMENT_AMOUNT_MISMATCH: Pembayaran melebihi sisa tagihan Rp%', v_state.outstanding::text
      using errcode = '22023';
  end if;
  v_purpose := 'SETTLEMENT';

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

  perform private.srv_close_if_settled(v_ticket.id);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'SERVICE_PAYMENT', 'PAYMENT', v_payment_id, v_purpose || ' ' || v_ticket.number);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_payment_id, 'payment_id', v_payment_id, 'purpose', v_purpose,
    'method', v_method, 'cashbox', v_cashbox, 'amount', v_amount::text,
    'tendered', v_tendered::text, 'change', v_change::text, 'occurred_at', v_occurred,
    'ticket_id', v_ticket.id, 'ticket_number', v_ticket.number,
    'actor_name', (select display_name from private.app_profiles where id = v_actor),
    'payment', private.srv_payment_state_json(v_ticket.id),
    'closed_at', (select closed_at from private.service_tickets where id = v_ticket.id), 'version', v_ticket.version));
end $$;

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

  perform private.srv_close_if_settled(v_ticket.id);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REFUND_SERVICE_PAYMENT', 'PAYMENT', v_refund_id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_refund_id, 'payment_id', v_refund_id, 'amount', v_amount::text,
    'method', v_method, 'cashbox', v_cashbox, 'allocations', v_allocs,
    'ticket_id', v_ticket.id, 'payment', private.srv_payment_state_json(v_ticket.id),
    'version', v_ticket.version));
end $$;

create or replace function public.credit_service_invoice_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'credit_service_invoice_v1';
  v_actor uuid;
  v_old jsonb;
  v_invoice private.invoices%rowtype;
  v_ticket private.service_tickets%rowtype;
  v_reason text;
  v_lines jsonb;
  v_line jsonb;
  v_item private.invoice_items%rowtype;
  v_item_id uuid;
  v_seen uuid[] := '{}';
  v_amount numeric;
  v_credited numeric;
  v_total numeric := 0;
  v_line_no integer := 0;
  v_credit_id uuid;
  v_number text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'invoice_id', 'expected_version', 'reason', 'lines']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  select * into v_invoice from private.invoices where id = private.srv_uuid(p_input, 'invoice_id');
  if not found or v_invoice.kind <> 'SERVICE' then
    raise exception 'NOT_FOUND: Tagihan servis tidak ditemukan' using errcode = 'P0002';
  end if;
  v_ticket := private.srv_lock_ticket(v_invoice.service_ticket_id,
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  select * into v_invoice from private.invoices where id = v_invoice.id for update;

  v_reason := private.srv_text(p_input, 'reason', 500, true);
  v_lines := p_input->'lines';
  if v_lines is null or jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) not between 1 and 50 then
    raise exception 'INVALID_INPUT: Daftar baris koreksi wajib (1-50 baris)' using errcode = '22023';
  end if;

  v_number := private.next_credit_number();
  insert into private.credit_notes(number, invoice_id, kind, reason, total, actor_id, operation_id)
  values (v_number, v_invoice.id, 'PRICE_CORRECTION', v_reason, 0, v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_credit_id;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_line_no := v_line_no + 1;
    perform private.srv_keys(v_line, array['invoice_item_id', 'amount']);
    v_item_id := private.srv_uuid(v_line, 'invoice_item_id');
    if v_item_id = any (v_seen) then
      raise exception 'INVALID_INPUT: Baris tagihan yang sama tidak boleh diulang' using errcode = '22023';
    end if;
    v_seen := v_seen || v_item_id;
    select * into v_item from private.invoice_items where id = v_item_id and invoice_id = v_invoice.id;
    if not found then
      raise exception 'NOT_FOUND: Baris tagihan tidak ditemukan pada tagihan ini' using errcode = 'P0002';
    end if;
    v_amount := private.decimal_input(v_line->'amount', 0, 9999999999999999);
    select coalesce(sum(ci.amount), 0) into v_credited from private.credit_note_items ci
      where ci.invoice_item_id = v_item.id;
    if v_amount > v_item.net_total - v_credited then
      raise exception 'REFUND_LIMIT_EXCEEDED: Potongan melebihi sisa nilai baris "%"', v_item.description_snapshot
        using errcode = '22023';
    end if;
    insert into private.credit_note_items(credit_note_id, invoice_item_id, amount, cost_reversal_amount,
      disposition, line_no)
    values (v_credit_id, v_item.id, v_amount, 0, 'NONE', v_line_no);
    v_total := v_total + v_amount;
  end loop;

  if v_total > v_invoice.total - coalesce((select sum(c.total) from private.credit_notes c
      where c.invoice_id = v_invoice.id and c.id <> v_credit_id), 0) then
    raise exception 'REFUND_LIMIT_EXCEEDED: Total potongan melebihi sisa nilai tagihan' using errcode = '22023';
  end if;
  update private.credit_notes set total = v_total where id = v_credit_id;
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  perform private.srv_close_if_settled(v_ticket.id);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREDIT_SERVICE_INVOICE', 'CREDIT_NOTE', v_credit_id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_credit_id, 'credit_note_id', v_credit_id, 'document_number', v_number,
    'total', v_total::text, 'payment', private.srv_payment_state_json(v_ticket.id),
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- Serah terima: sisa tagihan hanya atas keputusan pemilik (piutang servis).
create or replace function public.handover_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'handover_service_v1';
  v_actor uuid;
  v_role text;
  v_note text;
  v_outstanding numeric;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_receiver text;
  v_now timestamptz := now();
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'receiver_name',
    'condition_note', 'accessories_note', 'allow_unpaid', 'unpaid_note']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  v_receiver := private.srv_text(p_input, 'receiver_name', 120, true);
  if v_ticket.custody_location not in ('SHOP', 'FATHER') then
    raise exception 'INVALID_CUSTODY: Alat tidak sedang dititipkan; gunakan Tutup Kunjungan' using errcode = '22023';
  end if;
  v_note := private.srv_text(p_input, 'unpaid_note', 500);
  v_outstanding := private.srv_require_completable(v_ticket, private.srv_bool(p_input, 'allow_unpaid'), v_role, v_note);

  update private.service_tickets set custody_location = 'CUSTOMER', completed_at = v_now,
      closed_at = case when v_outstanding = 0 then v_now end,
      receivable_note = case when v_outstanding > 0 then v_note end, version = version + 1
    where id = v_ticket.id;
  insert into private.service_custody_events(ticket_id, from_location, to_location, condition_note,
    accessories_note, receiver_name, is_handover, actor_id, occurred_at)
  values (v_ticket.id, v_ticket.custody_location, 'CUSTOMER', private.srv_text(p_input, 'condition_note', 1000),
    private.srv_text(p_input, 'accessories_note', 500), v_receiver, true, v_actor, v_now);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'HANDOVER_SERVICE', 'SERVICE_TICKET', v_ticket.id, 'Diterima oleh ' || v_receiver
    || case when v_outstanding > 0 then ' dengan sisa tagihan ' || v_outstanding::text || ': ' || v_note else '' end);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', v_now,
    'entity_id', v_ticket.id, 'custody_location', 'CUSTOMER', 'receiver_name', v_receiver,
    'completed_at', v_now, 'closed_at', case when v_outstanding = 0 then v_now end,
    'outstanding', v_outstanding::text, 'version', v_ticket.version + 1));
end $$;

create or replace function public.close_onsite_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'close_onsite_service_v1';
  v_actor uuid;
  v_note text;
  v_outstanding numeric;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_now timestamptz := now();
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'completion_note',
    'allow_unpaid', 'unpaid_note']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if v_ticket.custody_location <> 'CUSTOMER' then
    raise exception 'INVALID_CUSTODY: Alat masih dititipkan; gunakan Serah Terima' using errcode = '22023';
  end if;
  v_note := private.srv_text(p_input, 'unpaid_note', 500);
  v_outstanding := private.srv_require_completable(v_ticket, private.srv_bool(p_input, 'allow_unpaid'), 'OWNER', v_note);

  update private.service_tickets set completed_at = v_now,
      closed_at = case when v_outstanding = 0 then v_now end,
      receivable_note = case when v_outstanding > 0 then v_note end, version = version + 1
    where id = v_ticket.id;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CLOSE_ONSITE', 'SERVICE_TICKET', v_ticket.id,
    concat_ws(' · ', private.srv_text(p_input, 'completion_note', 1000),
      case when v_outstanding > 0 then 'Sisa tagihan ' || v_outstanding::text || ': ' || v_note end));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', v_now,
    'entity_id', v_ticket.id, 'completed_at', v_now,
    'closed_at', case when v_outstanding = 0 then v_now end, 'outstanding', v_outstanding::text,
    'version', v_ticket.version + 1));
end $$;

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
    'completed_at', v_t.completed_at,
    'receivable', v_t.completed_at is not null and v_t.closed_at is null,
    'receivable_note', v_t.receivable_note,
    'allowed_transitions', case when v_t.completed_at is null and v_invoice.id is null
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
  v_receivable boolean;
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
    'receivable', 'service_location', 'limit', 'cursor']);

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
  v_receivable := coalesce(private.srv_bool(p_input, 'receivable'), false);
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
      and (not v_receivable or (t.completed_at is not null and t.closed_at is null))
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
      'completed_at', n.completed_at, 'receivable', n.completed_at is not null and n.closed_at is null,
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

create or replace function public.get_dashboard_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_today date; v_start timestamptz; v_end timestamptz;
  v_sales jsonb; v_cash jsonb; v_backup private.backup_runs%rowtype; v_last_ok timestamptz;
  v_terminal text[] := array['READY', 'UNREPAIRABLE', 'CANCELLED', 'ONSITE_DONE'];
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(coalesce(p_input, '{}'::jsonb), array[]::text[]);
  v_today := private.local_today();
  v_start := private.local_day_start(v_today);
  v_end := private.local_day_start(v_today + 1);
  v_sales := private.ops_sales_summary(v_start, v_end);

  select coalesce(jsonb_agg(jsonb_build_object('cashbox', b.code, 'label', b.label,
      'open', s.id is not null, 'session_id', s.id, 'opened_at', s.opened_at,
      'business_date', s.business_date, 'opened_by', ap.display_name)
      || case when v_role in ('OWNER', 'MAINTAINER') and s.id is not null
           then jsonb_build_object('expected_amount', private.cash_session_expected(s.id)::text)
           else '{}'::jsonb end
      order by b.code desc), '[]'::jsonb) into v_cash
    from private.cashboxes b
    left join private.cash_sessions s on s.cashbox_id = b.code and s.status = 'OPEN'
    left join private.app_profiles ap on ap.id = s.opened_by
    where b.active;

  select * into v_backup from private.backup_runs order by started_at desc limit 1;
  select max(coalesce(completed_at, started_at)) into v_last_ok from private.backup_runs where status = 'SUCCEEDED';

  return jsonb_build_object(
    'schema_version', 2, 'refreshed_at', now(), 'server_date', v_today, 'timezone', 'Asia/Jakarta',
    'today', v_sales,
    -- Kunci ringkas kompatibel dengan UI lama.
    'sales_total', v_sales->'sales'->>'net', 'sales_count', (v_sales->'sales'->>'invoice_count')::integer,
    'service_total', v_sales->'service'->>'net',
    'refund_total', v_sales->'customer_refunds'->>'total',
    'receipts_cash', v_sales->'customer_receipts'->'by_method'->>'CASH',
    'receipts_transfer', ((v_sales->'customer_receipts'->'by_method'->>'TRANSFER')::numeric
      + (v_sales->'customer_receipts'->'by_method'->>'QRIS')::numeric)::text,
    'cash_session_open', exists (select 1 from private.cash_sessions where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'),
    'cash_sessions', v_cash,
    'service', jsonb_build_object(
      'active_by_status', (select coalesce(jsonb_object_agg(work_status, n), '{}'::jsonb) from (
        select work_status, count(*) n from private.service_tickets where completed_at is null group by work_status) x),
      'active_total', (select count(*) from private.service_tickets where completed_at is null),
      -- Piutang servis: layanan selesai tetapi tagihan belum lunas (keputusan pemilik 18-09-2026).
      'receivable_count', (select count(*) from private.service_tickets where completed_at is not null and closed_at is null),
      'receivable_total', (select coalesce(sum(s.outstanding), 0)::text from private.service_tickets t
        cross join lateral private.srv_payment_state(t.id) s
        where t.completed_at is not null and t.closed_at is null),
      'receivables', (select coalesce(jsonb_agg(x.j order by x.completed_at), '[]'::jsonb) from (
        select t.completed_at, jsonb_build_object('ticket_id', t.id, 'number', t.number, 'customer_name', c.name,
          'completed_at', t.completed_at, 'outstanding', s.outstanding::text, 'note', t.receivable_note) j
        from private.service_tickets t left join private.customers c on c.id = t.customer_id
        cross join lateral private.srv_payment_state(t.id) s
        where t.completed_at is not null and t.closed_at is null
        order by t.completed_at limit 10) x),
      -- BR-11: status terminal dan alat masih di toko/ayah, walau sudah lunas.
      'not_picked_up_count', (select count(*) from private.service_tickets
        where work_status = any (v_terminal) and custody_location in ('SHOP', 'FATHER')),
      'not_picked_up', (select coalesce(jsonb_agg(x.j order by x.created_at), '[]'::jsonb) from (
        select t.created_at, jsonb_build_object('ticket_id', t.id, 'number', t.number, 'customer_name', c.name,
          'equipment_type', t.equipment_type, 'work_status', t.work_status, 'custody_location', t.custody_location) j
        from private.service_tickets t left join private.customers c on c.id = t.customer_id
        where t.work_status = any (v_terminal) and t.custody_location in ('SHOP', 'FATHER')
        order by t.created_at limit 10) x),
      'scheduled_today', (select coalesce(jsonb_agg(x.j order by x.scheduled_at), '[]'::jsonb) from (
        select t.scheduled_at, jsonb_build_object('ticket_id', t.id, 'number', t.number, 'customer_name', c.name,
          'address', t.address, 'scheduled_at', t.scheduled_at, 'work_status', t.work_status) j
        from private.service_tickets t left join private.customers c on c.id = t.customer_id
        where t.scheduled_at >= v_start and t.scheduled_at < v_end and t.completed_at is null
        order by t.scheduled_at limit 20) x)),
    'low_stock', (select count(*) from private.products p where p.active and p.min_stock > 0 and
      (select coalesce(sum(s.qty_base), 0) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
       where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE') < p.min_stock),
    'low_stock_items', (select coalesce(jsonb_agg(x.j order by x.ratio, x.name), '[]'::jsonb) from (
      select p.name, q.qty / p.min_stock ratio, jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name', p.name,
        'base_unit', p.base_unit, 'stock_shop', q.qty::text, 'min_stock', p.min_stock::text) j
      from private.products p
      cross join lateral (select coalesce(sum(s.qty_base), 0) qty from private.stock_positions s
        join private.inventory_lots l on l.id = s.lot_id
        where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE') q
      where p.active and p.min_stock > 0 and q.qty < p.min_stock
      order by q.qty / p.min_stock, p.name limit 10) x),
    'backup', jsonb_build_object(
      'last_status', v_backup.status, 'last_started_at', v_backup.started_at,
      'last_completed_at', v_backup.completed_at, 'last_success_at', v_last_ok,
      'age_hours', case when v_last_ok is not null then round(extract(epoch from now() - v_last_ok) / 3600.0, 1) end,
      'stale', v_last_ok is null or now() - v_last_ok > interval '24 hours'));
end $$;

do $$ declare f text; begin
  foreach f in array array['private.srv_require_open(private.service_tickets)',
    'private.srv_require_payable(private.service_tickets)', 'private.srv_close_if_settled(uuid)',
    'private.srv_require_completable(private.service_tickets, boolean, text, text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
