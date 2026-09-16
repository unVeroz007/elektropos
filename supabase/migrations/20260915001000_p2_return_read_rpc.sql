-- P2 RPC: return_sale_v1, correct_payment_v1, dan fungsi baca

-- === return_sale_v1 ===
create or replace function public.return_sale_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_invoice private.invoices%rowtype;
  v_item private.invoice_items%rowtype;
  v_credit_id uuid;
  v_credit_number text;
  v_line jsonb;
  v_line_no integer := 0;
  v_return_qty numeric(18,3);
  v_already numeric(18,3);
  v_item_net numeric(20,0);
  v_item_qty numeric(18,3);
  v_refund_amount numeric(20,0);
  v_cost_reversal numeric(24,6);
  v_disposition text;
  v_target_pos uuid;
  v_lot private.inventory_lots%rowtype;
  v_ca private.cost_allocations%rowtype;
  v_credit_item_id uuid;
  v_total numeric(20,0) := 0;
  v_refund_payment_id uuid;
  v_original_payment_id uuid;
  v_method text;
  v_session_id uuid;
  v_net_received numeric(20,0);
  v_already_refunded numeric(20,0);
  v_result jsonb;
begin
  v_role := private.current_role();
  if v_role <> 'OWNER' then
    raise exception 'Hanya owner yang dapat memproses retur' using errcode='42501';
  end if;
  v_old := private.operation_result('return_sale_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_invoice from private.invoices
    where id = nullif(p_input->>'invoice_id','')::uuid for update;
  if not found then raise exception 'Nota tidak ditemukan' using errcode='22023'; end if;
  if v_invoice.kind <> 'SALE' then
    raise exception 'Retur ini hanya untuk penjualan barang' using errcode='22023';
  end if;

  select id into v_original_payment_id from private.payments
    where invoice_id = v_invoice.id and purpose = 'SALE_RECEIPT' and direction = 'IN'
    order by occurred_at asc limit 1;

  -- Hitung total refund dulu (validasi batas)
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    select * into v_item from private.invoice_items
      where id = (v_line->>'invoice_item_id')::uuid and invoice_id = v_invoice.id;
    if not found then raise exception 'Baris nota tidak ditemukan' using errcode='22023'; end if;

    v_return_qty := (v_line->>'qty_base')::numeric;
    if v_return_qty <= 0 then raise exception 'Kuantitas retur harus positif' using errcode='22023'; end if;

    select coalesce(sum(qty_return_base), 0) into v_already
    from private.credit_note_items cni
    join private.credit_notes cn on cn.id = cni.credit_note_id
    where cn.invoice_id = v_invoice.id and cni.invoice_item_id = v_item.id;

    if v_already + v_return_qty > v_item.qty_base then
      raise exception 'REFUND_LIMIT_EXCEEDED: kuantitas retur melebihi sisa' using errcode='22023';
    end if;

    -- Refund = H(baru) - H(lama)
    v_item_net := v_item.net_total;
    v_item_qty := v_item.qty_base;
    v_refund_amount :=
      round(v_item_net * (v_already + v_return_qty) / v_item_qty, 0)
      - round(v_item_net * v_already / v_item_qty, 0);

    v_total := v_total + v_refund_amount;
  end loop;

  if v_total = 0 then
    raise exception 'Tidak ada nilai refund' using errcode='22023';
  end if;

  -- Validasi batas refund terhadap penerimaan asal
  select coalesce(sum(amount), 0) into v_net_received from private.payments
    where invoice_id = v_invoice.id and purpose = 'SALE_RECEIPT' and direction = 'IN';
  select coalesce(sum(amount), 0) into v_already_refunded from private.payments
    where invoice_id = v_invoice.id and purpose = 'CUSTOMER_REFUND' and direction = 'OUT';
  if v_already_refunded + v_total > v_net_received then
    raise exception 'REFUND_LIMIT_EXCEEDED: refund melebihi penerimaan asal' using errcode='22023';
  end if;

  -- Buat credit note
  v_credit_number := private.next_credit_number();
  insert into private.credit_notes(number, invoice_id, kind, reason, total, actor_id, operation_id)
  values (v_credit_number, v_invoice.id, 'RETURN', p_input->>'reason', v_total,
    v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_credit_id;

  -- Loop items: credit note items, stok kembali, cost reversal
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_line_no := v_line_no + 1;
    select * into v_item from private.invoice_items
      where id = (v_line->>'invoice_item_id')::uuid;

    v_return_qty := (v_line->>'qty_base')::numeric;
    v_disposition := coalesce(v_line->>'disposition', 'SALEABLE');
    if v_disposition not in ('SALEABLE','DAMAGED','NONE') then
      raise exception 'Kondisi barang tidak sah' using errcode='22023';
    end if;

    select coalesce(sum(qty_return_base), 0) into v_already
    from private.credit_note_items cni
    join private.credit_notes cn on cn.id = cni.credit_note_id
    where cn.invoice_id = v_invoice.id and cni.invoice_item_id = v_item.id
      and cn.id <> v_credit_id;

    v_item_net := v_item.net_total;
    v_item_qty := v_item.qty_base;
    v_refund_amount :=
      round(v_item_net * (v_already + v_return_qty) / v_item_qty, 0)
      - round(v_item_net * v_already / v_item_qty, 0);

    -- Cost reversal dari alokasi asal
    v_cost_reversal := 0;
    select * into v_ca from private.cost_allocations
      where invoice_item_id = v_item.id for update;
    if found then
      if v_return_qty >= v_ca.qty_base then
        v_cost_reversal := v_ca.cost_amount;
      else
        v_cost_reversal := round(v_ca.cost_amount * v_return_qty / v_ca.qty_base, 6);
      end if;
      update private.cost_allocations
        set reversed_qty = reversed_qty + v_return_qty,
            reversed_cost = reversed_cost + v_cost_reversal
        where id = v_ca.id;

      -- Kembalikan stok ke posisi target
      if v_disposition <> 'NONE' then
        insert into private.stock_positions(lot_id, location, condition, qty_base)
        values (v_ca.lot_id, 'SHOP',
          case when v_disposition = 'DAMAGED' then 'DAMAGED' else 'SALEABLE' end,
          v_return_qty)
        returning id into v_target_pos;

        update private.inventory_lots
          set remaining_qty = remaining_qty + v_return_qty,
              remaining_cost = remaining_cost + v_cost_reversal,
              version = version + 1
          where id = v_ca.lot_id;

        -- Ledger: catat movement retur
        insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta,
          kind, invoice_item_id, actor_id, operation_id)
        values (v_credit_id, v_ca.lot_id, v_target_pos, v_return_qty, v_cost_reversal,
          'RETURN_IN', v_item.id, v_actor, (p_input->>'operation_id')::uuid);
      else
        v_target_pos := null;
      end if;
    else
      v_target_pos := null;
    end if;

    insert into private.credit_note_items(credit_note_id, invoice_item_id, qty_return_base,
      amount, cost_reversal_amount, disposition, line_no)
    values (v_credit_id, v_item.id, v_return_qty, v_refund_amount,
      v_cost_reversal, v_disposition, v_line_no)
    returning id into v_credit_item_id;

    if v_target_pos is not null and v_ca.id is not null then
      insert into private.return_cost_allocations(credit_item_id, original_cost_allocation_id,
        qty_base, cost_amount, target_position_id)
      values (v_credit_item_id, v_ca.id, v_return_qty, v_cost_reversal, v_target_pos);
    end if;
  end loop;

  -- Refund ke pelanggan
  v_method := p_input->>'refund_method';
  if v_method = 'CASH' then
    select id into v_session_id from private.cash_sessions
      where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'
      order by opened_at desc limit 1 for update;
    if not found then raise exception 'CASH_SESSION_CLOSED' using errcode='40001'; end if;
    if private.cash_session_expected(v_session_id) < v_total then
      raise exception 'INSUFFICIENT_STOCK: saldo kas tidak cukup untuk refund' using errcode='22023';
    end if;
  end if;

  insert into private.payments(direction, purpose, invoice_id, method, amount,
    cash_session_id, original_payment_id, actor_id, operation_id)
  values ('OUT', 'CUSTOMER_REFUND', v_invoice.id, coalesce(v_method, 'CASH'), v_total,
    v_session_id, v_original_payment_id, v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_refund_payment_id;

  if v_original_payment_id is not null then
    insert into private.refund_allocations(refund_payment_id, original_payment_id, amount, credit_note_id)
    values (v_refund_payment_id, v_original_payment_id, v_total, v_credit_id);
  end if;

  if v_method = 'CASH' and v_session_id is not null then
    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id)
    values (v_session_id, 'OUT', 'REFUND', v_total,
      v_refund_payment_id, v_actor, (p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RETURN_SALE', 'CREDIT_NOTE', v_credit_id, p_input->>'reason');

  v_result := jsonb_build_object('ok', true, 'entity_id', v_credit_id,
    'document_number', v_credit_number, 'refund_total', v_total::text,
    'refund_payment_id', v_refund_payment_id, 'operation_id', p_input->>'operation_id');
  return private.finish_operation('return_sale_v1', p_input, v_result);
end $$;
revoke all on function public.return_sale_v1(jsonb) from public,anon,authenticated;
grant execute on function public.return_sale_v1(jsonb) to authenticated;

-- === correct_payment_v1 ===
create or replace function public.correct_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_original private.payments%rowtype;
  v_new_method text;
  v_session_id uuid;
  v_reversal_id uuid;
  v_replacement_id uuid;
  v_expected numeric(20,0);
  v_result jsonb;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner yang dapat mengoreksi pembayaran' using errcode='42501';
  end if;
  v_old := private.operation_result('correct_payment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_original from private.payments
    where id = nullif(p_input->>'original_payment_id','')::uuid for update;
  if not found then raise exception 'Pembayaran asal tidak ditemukan' using errcode='22023'; end if;
  if v_original.direction <> 'IN' or v_original.purpose not in ('SALE_RECEIPT','SERVICE_RECEIPT') then
    raise exception 'Koreksi hanya untuk penerimaan pelanggan' using errcode='22023';
  end if;
  if exists (select 1 from private.payments where original_payment_id = v_original.id
    and purpose in ('PAYMENT_REVERSAL','PAYMENT_REPLACEMENT')) then
    raise exception 'ALREADY_SETTLED: pembayaran sudah pernah dikoreksi' using errcode='40001';
  end if;
  if exists (select 1 from private.refund_allocations where original_payment_id = v_original.id) then
    raise exception 'REFUND_LIMIT_EXCEEDED: pembayaran sudah pernah direfund' using errcode='22023';
  end if;

  v_new_method := p_input->>'method';
  if v_new_method not in ('CASH','TRANSFER','QRIS') then
    raise exception 'Metode tidak sah' using errcode='22023';
  end if;
  if v_new_method = v_original.method then
    raise exception 'Metode baru harus berbeda dari metode asal' using errcode='22023';
  end if;

  -- Reversal keluar
  if v_original.method = 'CASH' and v_original.cash_session_id is not null then
    v_expected := private.cash_session_expected(v_original.cash_session_id);
    if v_expected < v_original.amount then
      raise exception 'INSUFFICIENT_STOCK: saldo kas tidak cukup untuk membalik' using errcode='22023';
    end if;
    insert into private.payments(direction, purpose, invoice_id, service_ticket_id,
      method, amount, original_payment_id, actor_id, operation_id)
    values ('OUT', 'PAYMENT_REVERSAL', v_original.invoice_id, v_original.service_ticket_id,
      v_original.method, v_original.amount, v_original.id, v_actor,
      (p_input->>'operation_id')::uuid)
    returning id into v_reversal_id;

    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id, reason)
    values (v_original.cash_session_id, 'OUT', 'CORRECTION', v_original.amount,
      v_reversal_id, v_actor, (p_input->>'operation_id')::uuid, p_input->>'reason');
  else
    insert into private.payments(direction, purpose, invoice_id, service_ticket_id,
      method, amount, original_payment_id, actor_id, operation_id)
    values ('OUT', 'PAYMENT_REVERSAL', v_original.invoice_id, v_original.service_ticket_id,
      v_original.method, v_original.amount, v_original.id, v_actor,
      (p_input->>'operation_id')::uuid)
    returning id into v_reversal_id;
  end if;

  -- Replacement masuk dengan metode baru
  if v_new_method = 'CASH' then
    select id into v_session_id from private.cash_sessions
      where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'
      order by opened_at desc limit 1 for update;
    if not found then raise exception 'CASH_SESSION_CLOSED' using errcode='40001'; end if;
  end if;

  insert into private.payments(direction, purpose, invoice_id, service_ticket_id,
    method, amount, cash_session_id, original_payment_id, actor_id, operation_id)
  values ('IN', 'PAYMENT_REPLACEMENT', v_original.invoice_id, v_original.service_ticket_id,
    v_new_method, v_original.amount, v_session_id, v_original.id, v_actor,
    (p_input->>'operation_id')::uuid)
  returning id into v_replacement_id;

  if v_new_method = 'CASH' and v_session_id is not null then
    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id, reason)
    values (v_session_id, 'IN', 'CORRECTION', v_original.amount,
      v_replacement_id, v_actor, (p_input->>'operation_id')::uuid, p_input->>'reason');
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CORRECT_PAYMENT', 'PAYMENT', v_original.id, p_input->>'reason');

  v_result := jsonb_build_object('ok', true, 'original_payment_id', v_original.id,
    'reversal_payment_id', v_reversal_id, 'replacement_payment_id', v_replacement_id,
    'amount', v_original.amount::text, 'new_method', v_new_method,
    'operation_id', p_input->>'operation_id');
  return private.finish_operation('correct_payment_v1', p_input, v_result);
end $$;
revoke all on function public.correct_payment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.correct_payment_v1(jsonb) to authenticated;

-- === get_invoice_v1 ===
create or replace function public.get_invoice_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_invoice private.invoices%rowtype;
  v_result jsonb;
begin
  v_role := private.current_role();
  select * into v_invoice from private.invoices
    where (p_input ? 'invoice_id' and id = (p_input->>'invoice_id')::uuid)
       or (p_input ? 'number' and number = p_input->>'number');
  if not found then raise exception 'NOT_FOUND' using errcode='22023'; end if;

  select jsonb_build_object(
    'id', i.id, 'number', i.number, 'kind', i.kind,
    'posted_at', i.posted_at, 'subtotal_net_lines', i.subtotal_net_lines::text,
    'discount_total', i.discount_total::text, 'total', i.total::text,
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', ii.id, 'line_no', ii.line_no, 'kind', ii.kind,
      'description', ii.description_snapshot,
      'qty_sell', ii.qty_sell::text, 'factor', ii.factor_snapshot::text,
      'qty_base', ii.qty_base::text, 'unit_price', ii.unit_price_snapshot::text,
      'discount_mode', ii.item_discount_mode, 'discount_value', ii.item_discount_value::text,
      'gross', ii.gross_exact::text, 'base_net', ii.base_net::text,
      'invoice_discount_alloc', ii.invoice_discount_alloc::text,
      'net_total', ii.net_total::text
    ) order by ii.line_no), '[]'::jsonb) from private.invoice_items ii where ii.invoice_id = i.id),
    'payments', case when v_role in ('OWNER','MAINTAINER') then
      (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'direction', p.direction, 'purpose', p.purpose,
        'method', p.method, 'amount', p.amount::text,
        'tendered', p.tendered::text, 'change', p.change::text,
        'occurred_at', p.occurred_at
      ) order by p.occurred_at), '[]'::jsonb)
      from private.payments p where p.invoice_id = i.id) else null end,
    'credits', (select coalesce(jsonb_agg(jsonb_build_object(
       'id', cn.id, 'number', cn.number, 'kind', cn.kind,
       'total', cn.total::text, 'posted_at', cn.posted_at
     ) order by cn.posted_at), '[]'::jsonb)
     from private.credit_notes cn where cn.invoice_id = i.id)
  ) into v_result
  from private.invoices i where i.id = v_invoice.id;

  return v_result;
end $$;
revoke all on function public.get_invoice_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_invoice_v1(jsonb) to authenticated;

-- === list_invoices_v1 ===
create or replace function public.list_invoices_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_limit integer := least(coalesce((p_input->>'limit')::integer, 25), 100);
  v_offset integer := coalesce((p_input->>'offset')::integer, 0);
  v_start timestamptz;
  v_end timestamptz;
  v_result jsonb;
begin
  v_role := private.current_role();
  if p_input ? 'start_date' then
    v_start := (p_input->>'start_date')::date::timestamptz at time zone 'Asia/Jakarta';
  end if;
  if p_input ? 'end_date' then
    v_end := ((p_input->>'end_date')::date + 1)::timestamptz at time zone 'Asia/Jakarta';
  end if;

  select coalesce(jsonb_agg(row_data order by posted_at desc), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'id', i.id, 'number', i.number, 'kind', i.kind,
      'posted_at', i.posted_at, 'total', i.total::text,
      'subtotal_net_lines', i.subtotal_net_lines::text,
      'discount_total', i.discount_total::text,
      'payment_status', (
        select case
          when coalesce(sum(case when p.direction='IN' then p.amount else -p.amount end), 0) >= i.total
            then 'PAID'
          when coalesce(sum(case when p.direction='IN' then p.amount else -p.amount end), 0) > 0
            then 'PARTIAL'
          else 'UNPAID' end
        from private.payments p where p.invoice_id = i.id
          and p.purpose in ('SALE_RECEIPT','SERVICE_RECEIPT','CUSTOMER_REFUND')
      )
    ) as row_data, i.posted_at
    from private.invoices i
    where (v_start is null or i.posted_at >= v_start)
      and (v_end is null or i.posted_at < v_end)
    order by i.posted_at desc
    limit v_limit offset v_offset
  ) sub;

  return v_result;
end $$;
revoke all on function public.list_invoices_v1(jsonb) from public,anon,authenticated;
grant execute on function public.list_invoices_v1(jsonb) to authenticated;

-- === get_cash_session_v1 ===
create or replace function public.get_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_session private.cash_sessions%rowtype;
  v_result jsonb;
begin
  v_role := private.current_role();
  select * into v_session from private.cash_sessions
    where id = nullif(p_input->>'session_id','')::uuid;
  if not found then
    select * into v_session from private.cash_sessions
      where cashbox_id = coalesce(p_input->>'cashbox_code','SHOP_DRAWER') and status = 'OPEN'
      order by opened_at desc limit 1;
    if not found then return jsonb_build_object('open', false); end if;
  end if;

  select jsonb_build_object(
    'open', v_session.status = 'OPEN',
    'id', v_session.id, 'cashbox_code', v_session.cashbox_id,
    'opened_at', v_session.opened_at, 'business_date', v_session.business_date,
    'opening_amount', v_session.opening_amount::text,
    'status', v_session.status, 'version', v_session.version,
    'expected', private.cash_session_expected(v_session.id)::text,
    'counted_amount', v_session.counted_amount::text,
    'variance', v_session.variance::text,
    'movements', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'direction', m.direction, 'kind', m.kind,
      'amount', m.amount::text, 'reason', m.reason, 'occurred_at', m.occurred_at
    ) order by m.occurred_at desc), '[]'::jsonb)
    from private.cash_movements m where m.session_id = v_session.id)
  ) into v_result;
  return v_result;
end $$;
revoke all on function public.get_cash_session_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_cash_session_v1(jsonb) to authenticated;

-- === get_dashboard_v1 ===
create or replace function public.get_dashboard_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_start timestamptz := v_today::timestamptz at time zone 'Asia/Jakarta';
  v_end timestamptz := (v_today + 1)::timestamptz at time zone 'Asia/Jakarta';
begin
  v_role := private.current_role();
  return jsonb_build_object(
    'refreshed_at', now(),
    'server_date', v_today,
    'sales_total', (select coalesce(sum(total), 0)::text from private.invoices
      where kind='SALE' and posted_at >= v_start and posted_at < v_end),
    'sales_count', (select count(*) from private.invoices
      where kind='SALE' and posted_at >= v_start and posted_at < v_end),
    'refund_total', (select coalesce(sum(amount), 0)::text from private.payments
      where direction='OUT' and purpose='CUSTOMER_REFUND'
      and occurred_at >= v_start and occurred_at < v_end),
    'receipts_cash', (select coalesce(sum(amount), 0)::text from private.payments
      where direction='IN' and method='CASH'
      and occurred_at >= v_start and occurred_at < v_end),
    'receipts_transfer', (select coalesce(sum(amount), 0)::text from private.payments
      where direction='IN' and method in ('TRANSFER','QRIS')
      and occurred_at >= v_start and occurred_at < v_end),
    'cash_session_open', exists(select 1 from private.cash_sessions
      where cashbox_id='SHOP_DRAWER' and status='OPEN'),
    'low_stock', (select count(*) from private.products p where p.active and (
      select coalesce(sum(s.qty_base),0) from private.stock_positions s
      join private.inventory_lots l on l.id=s.lot_id
      where l.product_id=p.id and s.location='SHOP' and s.condition='SALEABLE'
    ) < p.min_stock)
  );
end $$;
revoke all on function public.get_dashboard_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_dashboard_v1(jsonb) to authenticated;

-- === get_report_v1 ===
create or replace function public.get_report_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_start timestamptz;
  v_end timestamptz;
begin
  v_role := private.current_role();
  v_start := (p_input->>'start_date')::date::timestamptz at time zone 'Asia/Jakarta';
  v_end := ((p_input->>'end_date')::date + 1)::timestamptz at time zone 'Asia/Jakarta';
  if ((p_input->>'end_date')::date - (p_input->>'start_date')::date) > 31 then
    raise exception 'Rentang laporan maksimal 31 hari' using errcode='22023';
  end if;

  return jsonb_build_object(
    'start', p_input->>'start_date', 'end', p_input->>'end_date',
    'sales_net', (select coalesce(sum(total),0)::text from private.invoices
      where kind='SALE' and posted_at>=v_start and posted_at<v_end),
    'service_net', (select coalesce(sum(total),0)::text from private.invoices
      where kind='SERVICE' and posted_at>=v_start and posted_at<v_end),
    'credit_total', (select coalesce(sum(total),0)::text from private.credit_notes
      where posted_at>=v_start and posted_at<v_end),
    'receipts', (select coalesce(sum(amount),0)::text from private.payments
      where direction='IN' and purpose in ('SALE_RECEIPT','SERVICE_RECEIPT')
      and occurred_at>=v_start and occurred_at<v_end),
    'refunds', (select coalesce(sum(amount),0)::text from private.payments
      where direction='OUT' and purpose='CUSTOMER_REFUND'
      and occurred_at>=v_start and occurred_at<v_end),
    'cogs', case when v_role in ('OWNER','MAINTAINER') then
      (select coalesce(sum(ca.cost_amount - ca.reversed_cost),0)::text
       from private.cost_allocations ca
       join private.invoice_items ii on ii.id = ca.invoice_item_id
       join private.invoices i on i.id = ii.invoice_id
       where i.posted_at>=v_start and i.posted_at<v_end)
      else null end,
    'schema_version', 1
  );
end $$;
revoke all on function public.get_report_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_report_v1(jsonb) to authenticated;
