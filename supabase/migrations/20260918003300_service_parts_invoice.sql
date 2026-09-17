-- Perbaikan audit domain SERVIS (3/5): part, tagihan final, credit note.
-- Temuan: K08 (batas persetujuan, tiket tidak ditutup saat final), S05 (reverse part
-- mengembalikan stok+modal), T06 (part/tagihan wajib persetujuan).

-- use_service_part_v1 — OWNER ------------------------------------------------------
create or replace function public.use_service_part_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'use_service_part_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_pos private.stock_positions%rowtype;
  v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype;
  v_pos_id uuid;
  v_qty numeric;
  v_price numeric;
  v_cost numeric;
  v_event_id uuid;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'position_id',
    'qty', 'charge_unit_price', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; part tidak dapat ditambah' using errcode = '22023';
  end if;
  if v_ticket.work_status <> 'WORKING' then
    raise exception 'INVALID_TRANSITION: Part hanya dapat dipakai saat status Dikerjakan (WORKING)' using errcode = '22023';
  end if;
  perform private.srv_require_active_approval(v_ticket.id);

  v_pos_id := private.srv_uuid(p_input, 'position_id');
  v_qty := private.decimal_input(p_input->'qty', 3, 999999999.999);
  v_price := private.decimal_input_opt(p_input->'charge_unit_price', 6, 999999999999.999999, false);

  -- Urutan kunci global: tiket -> produk -> lot -> posisi.
  select l.* into v_lot from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where s.id = v_pos_id;
  if not found then
    raise exception 'NOT_FOUND: Posisi stok part tidak ditemukan' using errcode = 'P0002';
  end if;
  select * into v_product from private.products where id = v_lot.product_id for update;
  select * into v_lot from private.inventory_lots where id = v_lot.id for update;
  select * into v_pos from private.stock_positions where id = v_pos_id for update;

  if v_pos.condition <> 'SALEABLE' or v_pos.location not in ('SHOP', 'FIELD_FATHER') then
    raise exception 'INVALID_INPUT: Part harus diambil dari stok layak pakai (toko atau dibawa ayah)' using errcode = '22023';
  end if;
  if mod(v_qty, v_product.quantity_step) <> 0 then
    raise exception 'INVALID_QUANTITY: Jumlah part harus kelipatan % %', v_product.quantity_step::text, v_product.base_unit
      using errcode = '22023';
  end if;
  if v_pos.qty_base < v_qty then
    if v_product.track_segments then
      raise exception 'SEGMENT_TOO_SHORT: Sisa potongan/roll yang dipilih tidak cukup' using errcode = '22023';
    end if;
    raise exception 'INSUFFICIENT_STOCK: Stok pada posisi yang dipilih tidak cukup' using errcode = '22023';
  end if;

  v_cost := private.cost_for_exit(v_lot, v_qty);

  insert into private.service_part_events(ticket_id, product_id, kind, qty_base, charge_unit_price, reason, actor_id)
  values (v_ticket.id, v_product.id, 'USE', v_qty, v_price, private.srv_text(p_input, 'reason', 500), v_actor)
  returning id into v_event_id;

  update private.stock_positions set qty_base = qty_base - v_qty, sealed = false, version = version + 1
    where id = v_pos.id;
  update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
    remaining_cost = remaining_cost - v_cost, version = version + 1
    where id = v_lot.id;
  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
    service_part_event_id, actor_id, operation_id)
  values (v_event_id, v_lot.id, v_pos.id, -v_qty, -v_cost, 'SALE_OUT', v_event_id, v_actor,
    (p_input->>'operation_id')::uuid);
  insert into private.cost_allocations(lot_id, origin_position_id, service_part_event_id, qty_base, cost_amount)
  values (v_lot.id, v_pos.id, v_event_id, v_qty, v_cost);
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'USE_PART', 'SERVICE_PART_EVENT', v_event_id, private.srv_text(p_input, 'reason', 500));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_event_id, 'part_event_id', v_event_id, 'product_id', v_product.id,
    'qty', v_qty::text, 'cost', v_cost::text, 'position_qty_after', (v_pos.qty_base - v_qty)::text,
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- reverse_service_part_v1 — OWNER; hanya sebelum tagihan final --------------------------
create or replace function public.reverse_service_part_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'reverse_service_part_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_use private.service_part_events%rowtype;
  v_product private.products%rowtype;
  v_ca private.cost_allocations%rowtype;
  v_origin private.stock_positions%rowtype;
  v_target_id uuid;
  v_location text;
  v_condition text;
  v_reason text;
  v_qty numeric;
  v_left numeric;
  v_take numeric;
  v_new_rev numeric;
  v_cost numeric;
  v_cost_total numeric := 0;
  v_rev_id uuid;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'use_event_id',
    'qty', 'target_location', 'target_condition', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; pengembalian part harus lewat koreksi tagihan' using errcode = '22023';
  end if;

  select * into v_use from private.service_part_events
    where id = private.srv_uuid(p_input, 'use_event_id') and ticket_id = v_ticket.id for update;
  if not found or v_use.kind <> 'USE' then
    raise exception 'NOT_FOUND: Pemakaian part tidak ditemukan pada tiket ini' using errcode = 'P0002';
  end if;
  select * into v_product from private.products where id = v_use.product_id for update;

  v_qty := private.decimal_input(p_input->'qty', 3, 999999999.999);
  v_reason := private.srv_text(p_input, 'reason', 500, true);
  v_location := coalesce(private.srv_text(p_input, 'target_location', 20), 'SHOP');
  v_condition := coalesce(private.srv_text(p_input, 'target_condition', 20), 'SALEABLE');
  if v_location not in ('SHOP', 'FIELD_FATHER') or v_condition not in ('SALEABLE', 'DAMAGED') then
    raise exception 'INVALID_INPUT: Lokasi harus SHOP/FIELD_FATHER dan kondisi SALEABLE/DAMAGED' using errcode = '22023';
  end if;
  if mod(v_qty, v_product.quantity_step) <> 0 then
    raise exception 'INVALID_QUANTITY: Jumlah harus kelipatan % %', v_product.quantity_step::text, v_product.base_unit
      using errcode = '22023';
  end if;
  if v_qty > private.srv_use_net_qty(v_use.id) then
    raise exception 'REFUND_LIMIT_EXCEEDED: Jumlah dikembalikan melebihi sisa part yang dipakai' using errcode = '22023';
  end if;

  insert into private.service_part_events(ticket_id, product_id, kind, qty_base, charge_unit_price,
    reverses_event_id, reason, actor_id)
  values (v_ticket.id, v_use.product_id, 'REVERSE', v_qty, v_use.charge_unit_price, v_use.id, v_reason, v_actor)
  returning id into v_rev_id;

  -- Pulihkan dari alokasi asal secara berurutan; modal kumulatif per alokasi (BR-08).
  v_left := v_qty;
  for v_ca in select * from private.cost_allocations
      where service_part_event_id = v_use.id and qty_base > reversed_qty
      order by lot_id, id for update loop
    exit when v_left = 0;
    v_take := least(v_left, v_ca.qty_base - v_ca.reversed_qty);
    v_new_rev := v_ca.reversed_qty + v_take;
    v_cost := private.srv_prop_cost(v_ca.cost_amount, v_new_rev, v_ca.qty_base) - v_ca.reversed_cost;

    perform 1 from private.inventory_lots where id = v_ca.lot_id for update;
    select * into v_origin from private.stock_positions where id = v_ca.origin_position_id for update;

    -- Bulk kembali ke posisi asal bila lokasi/kondisi sama; roll selalu posisi baru (BR-03).
    if not v_product.track_segments and v_origin.location = v_location and v_origin.condition = v_condition then
      v_target_id := v_origin.id;
      update private.stock_positions set qty_base = qty_base + v_take, version = version + 1 where id = v_target_id;
    else
      insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
      values (v_ca.lot_id, v_location, v_condition, v_take,
        case when v_product.track_segments
          then coalesce(v_origin.label, 'POS') || '-K' || substr(replace(v_rev_id::text, '-', ''), 1, 6) end,
        case when v_product.track_segments then v_take end, false)
      returning id into v_target_id;
    end if;

    update private.inventory_lots set remaining_qty = remaining_qty + v_take,
      remaining_cost = remaining_cost + v_cost, version = version + 1
      where id = v_ca.lot_id;
    update private.cost_allocations set reversed_qty = v_new_rev, reversed_cost = reversed_cost + v_cost
      where id = v_ca.id;
    insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
      service_part_event_id, actor_id, operation_id)
    values (v_rev_id, v_ca.lot_id, v_target_id, v_take, v_cost, 'RETURN_IN', v_rev_id, v_actor,
      (p_input->>'operation_id')::uuid);
    insert into private.part_reversal_allocations(reversal_event_id, original_cost_allocation_id,
      qty_base, cost_amount, target_position_id)
    values (v_rev_id, v_ca.id, v_take, v_cost, v_target_id);

    v_cost_total := v_cost_total + v_cost;
    v_left := v_left - v_take;
  end loop;
  if v_left <> 0 then
    raise exception 'INVALID_INPUT: Alokasi modal pemakaian part tidak lengkap' using errcode = '22023';
  end if;
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REVERSE_PART', 'SERVICE_PART_EVENT', v_rev_id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_rev_id, 'part_event_id', v_rev_id, 'use_event_id', v_use.id,
    'qty', v_qty::text, 'cost_restored', v_cost_total::text,
    'target_location', v_location, 'target_condition', v_condition, 'target_position_id', v_target_id,
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- finalize_service_invoice_v1 — OWNER ------------------------------------------------
create or replace function public.finalize_service_invoice_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'finalize_service_invoice_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_approval private.service_estimates%rowtype;
  v_revision integer;
  v_waiver text;
  v_lines jsonb;
  v_line jsonb;
  v_kind text;
  v_desc text;
  v_qty numeric;
  v_price numeric;
  v_net numeric;
  v_total numeric := 0;
  v_event private.service_part_events%rowtype;
  v_event_id uuid;
  v_net_qty numeric;
  v_linked uuid[] := '{}';
  v_line_no integer := 0;
  v_invoice_id uuid;
  v_number text;
  v_cogs numeric := 0;
  v_cost numeric;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version',
    'approved_estimate_revision', 'waiver_reason', 'charge_lines']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if not private.srv_is_terminal(v_ticket.work_status) then
    raise exception 'INVALID_TRANSITION: Tagihan final hanya untuk tiket berstatus akhir (selesai/tidak bisa diperbaiki/batal)' using errcode = '22023';
  end if;
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tiket ini sudah punya tagihan final' using errcode = '22023';
  end if;

  v_revision := private.srv_int(p_input, 'approved_estimate_revision', false, 1, 100000);
  v_waiver := private.srv_text(p_input, 'waiver_reason', 500);
  v_lines := coalesce(p_input->'charge_lines', '[]'::jsonb);
  if jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) > 50 then
    raise exception 'INVALID_INPUT: charge_lines harus daftar (maksimal 50 baris)' using errcode = '22023';
  end if;

  v_number := private.next_invoice_number('SERVICE');
  insert into private.invoices(number, kind, service_ticket_id, customer_id, actor_id,
    subtotal_net_lines, discount_total, total, operation_id)
  values (v_number, 'SERVICE', v_ticket.id, v_ticket.customer_id, v_actor, 0, 0, 0,
    (p_input->>'operation_id')::uuid)
  returning id into v_invoice_id;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_line_no := v_line_no + 1;
    perform private.srv_keys(v_line, array['kind', 'description', 'quantity', 'unit_price', 'service_part_event_id']);
    v_kind := private.srv_text(v_line, 'kind', 20, true);
    if v_kind not in ('LABOR', 'PART', 'VISIT', 'DIAGNOSIS') then
      raise exception 'INVALID_INPUT: Jenis baris tagihan harus LABOR, PART, VISIT atau DIAGNOSIS' using errcode = '22023';
    end if;
    v_price := private.decimal_input(v_line->'unit_price', 6, 999999999999.999999, false);
    v_event_id := private.srv_uuid(v_line, 'service_part_event_id', v_kind = 'PART');
    v_event := null;

    if v_kind = 'PART' then
      select * into v_event from private.service_part_events
        where id = v_event_id and ticket_id = v_ticket.id and kind = 'USE';
      if not found then
        raise exception 'INVALID_INPUT: Baris part harus menunjuk pemakaian part milik tiket ini' using errcode = '22023';
      end if;
      if v_event_id = any (v_linked) then
        raise exception 'INVALID_INPUT: Satu pemakaian part hanya boleh satu baris tagihan' using errcode = '22023';
      end if;
      v_net_qty := private.srv_use_net_qty(v_event_id);
      if v_net_qty <= 0 then
        raise exception 'INVALID_INPUT: Part yang sudah dikembalikan penuh tidak ditagih' using errcode = '22023';
      end if;
      v_qty := coalesce(private.decimal_input_opt(v_line->'quantity', 3, 999999999.999), v_net_qty);
      if v_qty <> v_net_qty then
        raise exception 'INVALID_INPUT: Jumlah baris part harus sama dengan pemakaian bersih (%)', v_net_qty::text using errcode = '22023';
      end if;
      v_linked := v_linked || v_event_id;
      v_desc := coalesce(private.srv_text(v_line, 'description', 200),
        (select p.name from private.products p where p.id = v_event.product_id));
    else
      if v_event_id is not null then
        raise exception 'INVALID_INPUT: Hanya baris PART yang boleh menunjuk pemakaian part' using errcode = '22023';
      end if;
      v_qty := private.decimal_input(v_line->'quantity', 3, 999999999.999);
      v_desc := private.srv_text(v_line, 'description', 200, true);
    end if;

    v_net := round(v_qty * v_price, 0);
    if v_net > 9999999999999999 then
      raise exception 'INVALID_NUMBER: Nilai baris tagihan melebihi batas' using errcode = '22023';
    end if;
    insert into private.invoice_items(invoice_id, line_no, kind, product_id, service_part_event_id,
      description_snapshot, qty_sell, factor_snapshot, qty_base, unit_price_snapshot, gross_exact,
      base_net, invoice_discount_alloc, net_total)
    values (v_invoice_id, v_line_no, v_kind, v_event.product_id, v_event_id, v_desc, v_qty, 1,
      case when v_kind = 'PART' then v_qty end, v_price, v_qty * v_price, v_net, 0, v_net);
    v_total := v_total + v_net;
  end loop;

  -- Setiap USE bersih wajib punya tepat satu baris PART (nilai boleh 0).
  if exists (select 1 from private.service_part_events e
      where e.ticket_id = v_ticket.id and e.kind = 'USE'
        and private.srv_use_net_qty(e.id) > 0 and not (e.id = any (v_linked))) then
    raise exception 'PART_LINE_REQUIRED: Semua part yang dipakai wajib dicantumkan di tagihan (boleh Rp0)' using errcode = '22023';
  end if;

  -- Batas persetujuan BR-09.
  select * into v_approval from private.service_estimates
    where ticket_id = v_ticket.id and status = 'APPROVED' order by revision desc limit 1;
  if v_revision is not null then
    if v_approval.id is null or v_approval.revision <> v_revision then
      raise exception 'APPROVAL_REQUIRED: Revisi persetujuan yang dipilih bukan persetujuan aktif' using errcode = '22023';
    end if;
    if v_total > v_approval.approved_limit then
      raise exception 'APPROVAL_REQUIRED: Total tagihan melebihi batas yang disetujui pelanggan. Catat revisi estimasi dan persetujuan baru.'
        using errcode = '22023';
    end if;
  elsif v_total = 0 and v_waiver is not null and v_ticket.work_status in ('CANCELLED', 'UNREPAIRABLE') then
    null; -- pengecualian pembebasan biaya penuh oleh owner
  elsif v_total = 0 and v_ticket.work_status in ('CANCELLED', 'UNREPAIRABLE') then
    raise exception 'APPROVAL_REQUIRED: Tagihan nol tanpa persetujuan memerlukan alasan pembebasan biaya' using errcode = '22023';
  else
    raise exception 'APPROVAL_REQUIRED: Pilih revisi persetujuan biaya pelanggan' using errcode = '22023';
  end if;

  update private.invoices set subtotal_net_lines = v_total, total = v_total where id = v_invoice_id;

  -- COGS servis diakui sekali: modal pemakaian bersih (dikurangi reversal).
  for v_event in select * from private.service_part_events
      where ticket_id = v_ticket.id and kind = 'USE' order by occurred_at, id loop
    if private.srv_use_net_qty(v_event.id) > 0 then
      select coalesce(sum(cost_amount - reversed_cost), 0) into v_cost
        from private.cost_allocations where service_part_event_id = v_event.id;
      insert into private.service_cost_recognitions(invoice_id, part_event_id, cost_amount)
      values (v_invoice_id, v_event.id, v_cost);
      update private.service_part_events set recognized_invoice_id = v_invoice_id where id = v_event.id;
      v_cogs := v_cogs + v_cost;
    end if;
  end loop;

  -- Tiket TIDAK ditutup di sini; closed_at hanya lewat serah terima/penutupan.
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'FINALIZE_SERVICE_INVOICE', 'INVOICE', v_invoice_id,
    coalesce('Pembebasan biaya: ' || v_waiver, 'Revisi persetujuan ' || v_revision));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_invoice_id, 'invoice_id', v_invoice_id, 'document_number', v_number,
    'total', v_total::text, 'cost_recognized', v_cogs::text,
    'payment', private.srv_payment_state_json(v_ticket.id),
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- credit_service_invoice_v1 — OWNER ----------------------------------------------------
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

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREDIT_SERVICE_INVOICE', 'CREDIT_NOTE', v_credit_id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_credit_id, 'credit_note_id', v_credit_id, 'document_number', v_number,
    'total', v_total::text, 'payment', private.srv_payment_state_json(v_ticket.id),
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

do $$ declare f text; begin
  foreach f in array array['use_service_part_v1', 'reverse_service_part_v1',
    'finalize_service_invoice_v1', 'credit_service_invoice_v1']
  loop
    execute format('revoke all on function public.%I(jsonb) from public, anon, authenticated', f);
    execute format('grant execute on function public.%I(jsonb) to authenticated', f);
  end loop;
end $$;
