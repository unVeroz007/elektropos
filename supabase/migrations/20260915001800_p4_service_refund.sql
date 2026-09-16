-- P4: refund pembayaran servis + credit note servis (AT-21)

-- refund_service_payment_v1 — kembalikan kelebihan DP / DP batal
create or replace function public.refund_service_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_payment private.payments%rowtype;
  v_amount numeric(20,0);
  v_session_id uuid;
  v_refund_id uuid;
  v_method text;
  v_net numeric(20,0);
  v_refunded numeric(20,0);
  v_invoice private.invoices%rowtype;
  v_invoice_net numeric(20,0);
  v_refund_due numeric(20,0);
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengembalikan pembayaran servis' using errcode = '42501';
  end if;
  v_old := private.operation_result('refund_service_payment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;

  if length(trim(coalesce(p_input->>'reason', ''))) = 0 then
    raise exception 'Alasan refund wajib' using errcode = '22023';
  end if;

  v_amount := private.decimal_input(p_input->'amount', 0, 9999999999999999, false);
  if v_amount <= 0 then raise exception 'Jumlah refund harus positif' using errcode = '22023'; end if;

  -- Hitung kewajiban refund (BR-10)
  select coalesce(sum(amount), 0) into v_net from private.payments
    where service_ticket_id = v_ticket.id and direction = 'IN';
  select coalesce(sum(amount), 0) into v_refunded from private.payments
    where service_ticket_id = v_ticket.id and direction = 'OUT' and purpose = 'CUSTOMER_REFUND';

  -- Jika sudah ada invoice final, batas refund = refund_due
  select * into v_invoice from private.invoices where service_ticket_id = v_ticket.id limit 1;
  if v_invoice.id is not null then
    v_invoice_net := v_invoice.total - coalesce(
      (select sum(total) from private.credit_notes where invoice_id = v_invoice.id), 0);
    v_refund_due := greatest(v_net - v_invoice_net - v_refunded, 0);
    if v_amount > v_refund_due then
      raise exception 'REFUND_LIMIT_EXCEEDED: refund melebihi kewajiban (% tersisa)', v_refund_due
        using errcode = '22023';
    end if;
  else
    -- Belum ada invoice final: batas = sisa penerimaan
    if v_refunded + v_amount > v_net then
      raise exception 'REFUND_LIMIT_EXCEEDED: refund melebihi penerimaan' using errcode = '22023';
    end if;
  end if;

  -- Ambil receipt asal (yang masih punya saldo)
  select p.* into v_payment from private.payments p
    where p.service_ticket_id = v_ticket.id and p.direction = 'IN'
      and p.purpose = 'SERVICE_RECEIPT'
      and p.amount > coalesce((select sum(ra.amount) from private.refund_allocations ra
        where ra.original_payment_id = p.id), 0)
    order by p.occurred_at limit 1;

  v_method := coalesce(p_input->>'method', 'CASH');
  if v_method = 'CASH' then
    select id into v_session_id from private.cash_sessions
      where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'
      order by opened_at desc limit 1 for update;
    if not found then raise exception 'CASH_SESSION_CLOSED' using errcode = '40001'; end if;
    if private.cash_session_expected(v_session_id) < v_amount then
      raise exception 'INSUFFICIENT_STOCK: saldo kas tidak cukup untuk refund' using errcode = '22023';
    end if;
  end if;

  insert into private.payments(direction, purpose, service_ticket_id, method, amount,
    cash_session_id, original_payment_id, actor_id, operation_id)
  values ('OUT', 'CUSTOMER_REFUND', v_ticket.id, v_method, v_amount,
    v_session_id, v_payment.id, v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_refund_id;

  if v_payment.id is not null then
    insert into private.refund_allocations(refund_payment_id, original_payment_id, amount)
    values (v_refund_id, v_payment.id, v_amount);
  end if;

  if v_method = 'CASH' and v_session_id is not null then
    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id)
    values (v_session_id, 'OUT', 'REFUND', v_amount, v_refund_id, v_actor,
      (p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REFUND_SERVICE_PAYMENT', 'PAYMENT', v_refund_id, p_input->>'reason');

  return private.finish_operation('refund_service_payment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_refund_id, 'amount', v_amount::text,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.refund_service_payment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.refund_service_payment_v1(jsonb) to authenticated;

-- credit_service_invoice_v1 — kurangi tagihan servis via credit note
create or replace function public.credit_service_invoice_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_invoice private.invoices%rowtype;
  v_credit_id uuid;
  v_number text;
  v_total numeric(20,0) := 0;
  v_line jsonb;
  v_item private.invoice_items%rowtype;
  v_line_no integer := 0;
  v_amount numeric(20,0);
  v_reason text;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengkredit tagihan servis' using errcode = '42501';
  end if;
  v_old := private.operation_result('credit_service_invoice_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_invoice from private.invoices
    where id = nullif(p_input->>'invoice_id', '')::uuid for update;
  if not found then raise exception 'Nota tidak ditemukan' using errcode = '22023'; end if;
  if v_invoice.kind <> 'SERVICE' then
    raise exception 'Kredit ini hanya untuk tagihan servis' using errcode = '22023';
  end if;

  v_reason := trim(coalesce(p_input->>'reason', ''));
  if length(v_reason) = 0 then raise exception 'Alasan kredit wajib' using errcode = '22023'; end if;

  -- Hitung total kredit dulu
  for v_line in select value from jsonb_array_elements(p_input->'lines') loop
    v_amount := private.decimal_input(v_line->'amount', 0, 9999999999999999, false);
    v_total := v_total + v_amount;
  end loop;
  if v_total <= 0 then raise exception 'Total kredit harus positif' using errcode = '22023'; end if;

  -- Kredit tidak melebihi sisa tagihan (total - kredit sebelumnya)
  if v_total > v_invoice.total - coalesce(
      (select sum(total) from private.credit_notes where invoice_id = v_invoice.id), 0) then
    raise exception 'Total kredit melebihi sisa tagihan' using errcode = '22023';
  end if;

  v_number := private.next_credit_number();
  insert into private.credit_notes(number, invoice_id, kind, reason, total, actor_id, operation_id)
  values (v_number, v_invoice.id, 'PRICE_CORRECTION', v_reason, v_total, v_actor,
    (p_input->>'operation_id')::uuid)
  returning id into v_credit_id;

  for v_line in select value from jsonb_array_elements(p_input->'lines') loop
    v_line_no := v_line_no + 1;
    v_amount := private.decimal_input(v_line->'amount', 0, 9999999999999999, false);

    select * into v_item from private.invoice_items
      where id = (v_line->>'invoice_item_id')::uuid and invoice_id = v_invoice.id;
    if not found then raise exception 'Baris nota tidak ditemukan' using errcode = '22023'; end if;

    insert into private.credit_note_items(credit_note_id, invoice_item_id, amount,
      cost_reversal_amount, disposition, line_no)
    values (v_credit_id, v_item.id, v_amount, 0, 'NONE', v_line_no);
  end loop;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREDIT_SERVICE_INVOICE', 'CREDIT_NOTE', v_credit_id, v_reason);

  return private.finish_operation('credit_service_invoice_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_credit_id, 'document_number', v_number,
    'total', v_total::text, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.credit_service_invoice_v1(jsonb) from public,anon,authenticated;
grant execute on function public.credit_service_invoice_v1(jsonb) to authenticated;

-- get_service_payment_status_v1 — status derived servis
create or replace function public.get_service_payment_status_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ticket private.service_tickets%rowtype;
  v_invoice private.invoices%rowtype;
  v_net numeric(20,0) := 0;
  v_invoice_net numeric(20,0) := 0;
begin
  perform private.current_role();
  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid;
  if not found then raise exception 'NOT_FOUND' using errcode = '22023'; end if;

  select * into v_invoice from private.invoices where service_ticket_id = v_ticket.id limit 1;

  select coalesce(sum(case when direction = 'IN' then amount else -amount end), 0)
    into v_net from private.payments where service_ticket_id = v_ticket.id;

  if found and v_invoice.id is not null then
    v_invoice_net := v_invoice.total - coalesce(
      (select sum(total) from private.credit_notes where invoice_id = v_invoice.id), 0);
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket.id,
    'invoice_id', v_invoice.id,
    'invoice_total', case when v_invoice.id is null then null else v_invoice.total::text end,
    'invoice_net', case when v_invoice.id is null then null else v_invoice_net::text end,
    'net_received', v_net::text,
    'outstanding', case when v_invoice.id is null then null
      else greatest(v_invoice_net - v_net, 0)::text end,
    'refund_due', case when v_invoice.id is null then null
      else greatest(v_net - v_invoice_net, 0)::text end,
    'status', case
      when v_invoice.id is null and v_net > 0 then 'UNPRICED'
      when v_invoice.id is null then 'UNPRICED'
      when v_net > v_invoice_net then 'REFUND_DUE'
      when v_net >= v_invoice_net and v_invoice_net > 0 then 'PAID'
      when v_net > 0 then 'PARTIAL'
      when v_invoice_net = 0 then 'PAID'
      else 'UNPAID' end);
end $$;
revoke all on function public.get_service_payment_status_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_service_payment_status_v1(jsonb) to authenticated;
