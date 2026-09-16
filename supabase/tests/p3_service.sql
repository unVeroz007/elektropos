-- AT-17/18/19/20/22/23: servis lengkap
\set ON_ERROR_STOP on

begin;

-- Setup stok
do $$
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-00000000f001',
    'reason', 'Stok',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000001',
      'qty', '10', 'acquisition_cost', '100000'))));
end $$;

-- AT-17: buat tiket toko + onsite + siklus lengkap
do $$
declare v_res jsonb; v_ticket uuid; v_ver integer; v_est_id uuid;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_res := public.create_service_ticket_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000001',
    'customer_name', 'Joko', 'customer_phone', '081234567890',
    'equipment_type', 'TV', 'complaint', 'Layar',
    'service_location', 'STORE'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-17: gagal'; end if;
  v_ticket := (v_res->>'entity_id')::uuid;

  v_res := public.create_service_ticket_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000010',
    'customer_name', 'Sari', 'customer_phone', '085678901234',
    'equipment_type', 'AC', 'complaint', 'Tidak dingin',
    'service_location', 'ONSITE', 'address', 'Jl. Melati',
    'scheduled_at', '2026-09-20T09:00:00+07:00'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-17: onsite'; end if;

  -- AT-18: INSPECTING
  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000003',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'INSPECTING', 'reason', 'Diagnosis'));

  -- AT-18: Estimasi + Approve
  v_res := public.record_estimate_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000004',
    'ticket_id', v_ticket, 'description', 'Ganti lampu',
    'min_amount', '80000', 'max_amount', '120000'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-18: estimasi'; end if;

  select id into v_est_id from private.service_estimates where status = 'PROPOSED' order by revision desc limit 1;
  v_res := public.approve_estimate_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000005',
    'estimate_id', v_est_id, 'expected_version', 1,
    'agreed_limit', '120000', 'method', 'Telp', 'consent_note', 'OK'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-18: approve'; end if;

  -- AT-18: WORKING
  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000006',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'WORKING', 'reason', 'Mulai'));

  -- AT-19: USE + REVERSE
  declare v_pos_id uuid; v_unit_id uuid; v_use_id uuid;
  begin
    select s.id, u.id into v_pos_id, v_unit_id
    from private.stock_positions s
    join private.inventory_lots l on l.id = s.lot_id
    join private.product_units u on u.product_id = l.product_id and u.is_default and u.active
    where s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base >= 1 limit 1;
    if v_pos_id is null then raise exception 'AT-19: tidak ada stok'; end if;

    v_res := public.use_service_part_v1(jsonb_build_object(
      'operation_id', 'f0000000-0000-4000-8000-000000000011',
      'ticket_id', v_ticket, 'product_unit_id', v_unit_id,
      'position_id', v_pos_id, 'qty_base', '1', 'charge_unit_price', '15000'));
    if not (v_res->>'ok')::boolean then raise exception 'AT-19: USE'; end if;

    select id into v_use_id from private.service_part_events where kind = 'USE' order by occurred_at desc limit 1;
    v_res := public.reverse_service_part_v1(jsonb_build_object(
      'operation_id', 'f0000000-0000-4000-8000-000000000012',
      'use_event_id', v_use_id, 'qty', '1', 'reason', 'Salah'));
    if not (v_res->>'ok')::boolean then raise exception 'AT-19: REVERSE'; end if;
  end;

  -- AT-18: READY
  select version into v_ver from private.service_tickets where id = v_ticket;
  perform public.transition_service_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000007',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'target_status', 'READY', 'test_result', 'OK'));

  -- AT-20: DP
  declare v_sid uuid;
  begin
    select id into v_sid from private.cash_sessions where status = 'OPEN' limit 1;
    v_res := public.record_service_payment_v1(jsonb_build_object(
      'operation_id', 'f0000000-0000-4000-8000-000000000008',
      'ticket_id', v_ticket, 'amount', '50000', 'method', 'CASH', 'cash_session_id', v_sid));
    if not (v_res->>'ok')::boolean then raise exception 'AT-20: DP'; end if;
  end;

  -- Finalisasi tagihan
  select version into v_ver from private.service_tickets where id = v_ticket;
  v_res := public.finalize_service_invoice_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000020',
    'ticket_id', v_ticket, 'expected_version', v_ver,
    'charge_lines', jsonb_build_array(
      jsonb_build_object('kind', 'LABOR', 'description', 'Ganti lampu', 'quantity', '1', 'unit_price', '100000'),
      jsonb_build_object('kind', 'VISIT', 'description', 'Biaya kunjungan', 'quantity', '1', 'unit_price', '25000'))));
  if not (v_res->>'ok')::boolean then raise exception 'Finalisasi gagal: %', (v_res); end if;

  -- AT-22: handover
  select version into v_ver from private.service_tickets where id = v_ticket;
  v_res := public.handover_service_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000009',
    'ticket_id', v_ticket, 'expected_version', v_ver, 'location', 'CUSTOMER',
    'receiver_name', 'Joko'));
  if not (v_res->>'ok')::boolean then raise exception 'AT-22: handover'; end if;

  -- AT-23: keluhan kembali
  v_res := public.create_service_ticket_v1(jsonb_build_object(
    'operation_id', 'f0000000-0000-4000-8000-000000000013',
    'customer_name', 'Joko', 'customer_phone', '081234567890',
    'equipment_type', 'TV', 'complaint', 'Layar berkedip',
    'service_location', 'STORE', 'parent_ticket_id', v_ticket));
  if not (v_res->>'ok')::boolean then raise exception 'AT-23: gagal'; end if;

  raise notice 'AT-23 tiket parent: %', v_ticket;
end $$;

-- Verifikasi langsung (luar DO block, sebagai postgres)
do $$
begin
  if (select count(*) from private.service_tickets where closed_at is not null) < 1 then
    raise exception 'Harus ada tiket closed';
  end if;
  if (select count(*) from private.service_tickets where parent_ticket_id is not null) < 1 then
    raise exception 'AT-23: harus ada tiket kembali';
  end if;
  if (select count(*) from private.service_part_events) < 2 then
    raise exception 'AT-19: harus ada USE+REVERSE';
  end if;
  if (select count(*) from private.payments where purpose = 'SERVICE_RECEIPT') < 1 then
    raise exception 'AT-20: harus ada pembayaran';
  end if;
end $$;

rollback;
