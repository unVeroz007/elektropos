-- AT-21: DP berlebih / pembatalan dengan refund
\set ON_ERROR_STOP on

begin;

-- Setup kas
do $$
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  perform public.open_cash_session_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000001',
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '500000'));
end $$;

-- AT-21: DP 100rb, tagihan final 80rb -> refund_due 20rb
do $$
declare v_ticket uuid; v_ver integer; v_res jsonb; v_sid uuid; v_status jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select id into v_sid from private.cash_sessions where status = 'OPEN' limit 1;

  -- Buat tiket
  v_res := public.create_service_ticket_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000002',
    'customer_name', 'DP Test', 'customer_phone', '081222222222',
    'equipment_type', 'Kipas', 'complaint', 'Mati',
    'service_location', 'STORE'));
  v_ticket := (v_res->>'entity_id')::uuid;

  -- Transisi ke WORKING (dengan estimasi)
  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000003',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'INSPECTING'));

  v_res := public.record_estimate_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000004',
    'ticket_id', v_ticket, 'description', 'Perbaikan', 'max_amount', '150000'));

  perform public.approve_estimate_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000005',
    'estimate_id', (select id from private.service_estimates where ticket_id = v_ticket order by revision desc limit 1),
    'expected_version', 1, 'agreed_limit', '150000', 'method', 'Telp', 'consent_note', 'OK'));

  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000006',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'WORKING'));

  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000007',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'READY', 'test_result', 'OK'));

  -- DP 100rb
  v_res := public.record_service_payment_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000008',
    'ticket_id', v_ticket, 'amount', '100000', 'method', 'CASH', 'cash_session_id', v_sid));
  if not (v_res->>'ok')::boolean then raise exception 'AT-21: DP gagal'; end if;

  -- Status sebelum final: UNPRICED
  v_status := public.get_service_payment_status_v1(jsonb_build_object('ticket_id', v_ticket));
  if v_status->>'status' <> 'UNPRICED' then
    raise exception 'AT-21: sebelum final harus UNPRICED, dapat %', v_status->>'status';
  end if;

  -- Final tagihan 80rb
  select version into v_ver from private.service_tickets where id = v_ticket;
  v_res := public.finalize_service_invoice_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000009',
    'ticket_id', v_ticket, 'expected_version', v_ver,
    'charge_lines', jsonb_build_array(jsonb_build_object(
      'kind', 'LABOR', 'description', 'Perbaikan', 'quantity', '1', 'unit_price', '80000'))));
  if not (v_res->>'ok')::boolean then raise exception 'AT-21: final gagal'; end if;
  if (v_res->>'total')::numeric <> 80000 then
    raise exception 'AT-21: total harus 80000, dapat %', v_res->>'total';
  end if;

  -- Status setelah final: REFUND_DUE
  v_status := public.get_service_payment_status_v1(jsonb_build_object('ticket_id', v_ticket));
  if v_status->>'status' <> 'REFUND_DUE' then
    raise exception 'AT-21: harus REFUND_DUE, dapat %', v_status->>'status';
  end if;
  if (v_status->>'refund_due')::numeric <> 20000 then
    raise exception 'AT-21: refund_due harus 20000, dapat %', v_status->>'refund_due';
  end if;

  -- Refund 20rb
  v_res := public.refund_service_payment_v1(jsonb_build_object(
    'operation_id', 'b2100000-0000-4000-8000-000000000010',
    'ticket_id', v_ticket, 'amount', '20000', 'method', 'CASH',
    'cash_session_id', v_sid, 'reason', 'Kelebihan DP'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-21: refund gagal'; end if;

  -- Status akhir: PAID (refund_due 0)
  v_status := public.get_service_payment_status_v1(jsonb_build_object('ticket_id', v_ticket));
  if (v_status->>'refund_due')::numeric <> 0 then
    raise exception 'AT-21: refund_due harus 0 setelah refund, dapat %', v_status->>'refund_due';
  end if;

  -- Refund ulang melebihi penerimaan ditolak
  begin
    perform public.refund_service_payment_v1(jsonb_build_object(
      'operation_id', 'b2100000-0000-4000-8000-000000000011',
      'ticket_id', v_ticket, 'amount', '50000', 'method', 'CASH',
      'cash_session_id', v_sid, 'reason', 'Coba lebih'));
    raise exception 'AT-21: refund melebihi seharusnya ditolak';
  exception when others then
    if position('REFUND_LIMIT_EXCEEDED' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

-- Verifikasi akhir
do $$
declare v_net numeric; v_rev numeric;
begin
  select coalesce(sum(case when direction='IN' then amount else -amount end), 0) into v_net
  from private.payments where purpose in ('SERVICE_RECEIPT','CUSTOMER_REFUND');
  if v_net < 80000 then
    raise exception 'AT-21: net penerimaan seharusnya >= 80000, dapat %', v_net;
  end if;

  select coalesce(sum(total), 0) into v_rev from private.invoices where kind = 'SERVICE';
  if v_rev <> 80000 then
    raise exception 'AT-21: revenue servis harus tetap 80000, dapat %', v_rev;
  end if;
end $$;

rollback;
