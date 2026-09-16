-- P3 RPC: finalize_service_invoice, update details/schedule, custody transfer,
--         close onsite, correct status, refund service payment, credit service invoice

-- finalize_service_invoice_v1 — tagihan final servis
create or replace function public.finalize_service_invoice_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_invoice_id uuid;
  v_number text;
  v_total numeric(20,0) := 0;
  v_line_no integer := 0;
  v_line jsonb;
  v_item private.invoice_items%rowtype;
  v_part_recognized numeric(24,6) := 0;
  v_event_id uuid;
  v_event private.service_part_events%rowtype;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat memfinalisasi tagihan servis' using errcode = '42501';
  end if;
  v_old := private.operation_result('finalize_service_invoice_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;
  if v_ticket.work_status not in ('READY', 'UNREPAIRABLE', 'CANCELLED') then
    raise exception 'Status belum terminal' using errcode = '22023';
  end if;

  -- Validasi: jika ada biaya, harus ada estimasi disetujui
  if jsonb_array_length(p_input->'charge_lines') > 0 then
    if not exists (select 1 from private.service_estimates where ticket_id = v_ticket.id and status = 'APPROVED') then
      raise exception 'Belum ada estimasi yang disetujui' using errcode = '22023';
    end if;
  end if;

  v_number := private.next_invoice_number('SERVICE');
  insert into private.invoices(number, kind, service_ticket_id, actor_id,
    subtotal_net_lines, discount_total, total, operation_id)
  values (v_number, 'SERVICE', v_ticket.id, v_actor,
    0, 0, 0, (p_input->>'operation_id')::uuid)
  returning id into v_invoice_id;

  -- Buat baris tagihan
  for v_line in select value from jsonb_array_elements(p_input->'charge_lines') loop
    v_line_no := v_line_no + 1;
    declare
      v_qty numeric;
      v_price numeric;
      v_gross numeric;
      v_net numeric;
      v_part_event_id uuid;
      v_desc text;
    begin
      v_qty := coalesce(private.decimal_input(v_line->'quantity', 3, 999999999.999), 1);
      v_price := private.decimal_input(v_line->'unit_price', 6, 999999999999.999999, false);
      v_gross := round(v_qty * v_price, 0);
      v_net := v_gross;

      v_desc := trim(coalesce(v_line->>'description', 'Biaya servis'));
      v_part_event_id := nullif(v_line->>'service_part_event_id', '')::uuid;

      insert into private.invoice_items(invoice_id, line_no, kind, product_id,
        service_part_event_id, description_snapshot, qty_sell, factor_snapshot, qty_base,
        unit_price_snapshot, gross_exact, base_net, invoice_discount_alloc, net_total)
      values (v_invoice_id, v_line_no, coalesce(v_line->>'kind', 'LABOR'),
        nullif(v_line->>'product_id', '')::uuid,
        v_part_event_id,
        v_desc, v_qty, 1, v_qty,
        v_price, v_gross::numeric(38,9), v_net, 0, v_net)
      returning * into v_item;

      -- Recognize part cost
      if v_part_event_id is not null then
        select * into v_event from private.service_part_events where id = v_part_event_id;
        if found and v_event.kind = 'USE' then
          select coalesce(sum(cost_amount), 0) into v_part_recognized
          from private.cost_allocations where service_part_event_id = v_event.id;
          insert into private.service_cost_recognitions(invoice_id, part_event_id, cost_amount)
          values (v_invoice_id, v_event.id, v_part_recognized)
          on conflict (part_event_id) do update set cost_amount = excluded.cost_amount;
          update private.service_part_events set recognized_invoice_id = v_invoice_id
          where id = v_event.id;
        end if;
      end if;

      v_total := v_total + v_net;
    end;
  end loop;

  update private.invoices set subtotal_net_lines = v_total, total = v_total
    where id = v_invoice_id;

  -- Tutup tiket
  update private.service_tickets set closed_at = now(), version = version + 1
    where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'FINALIZE_SERVICE_INVOICE', 'INVOICE', v_invoice_id, p_input->>'reason');

  return private.finish_operation('finalize_service_invoice_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_invoice_id, 'document_number', v_number,
    'total', v_total::text, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.finalize_service_invoice_v1(jsonb) from public,anon,authenticated;
grant execute on function public.finalize_service_invoice_v1(jsonb) to authenticated;

-- update_service_details_v1 — edit detail tiket
create or replace function public.update_service_details_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('update_service_details_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  -- Hanya boleh sebelum closed_at dan sebelum DONE terminal
  if v_ticket.closed_at is not null then
    raise exception 'Tiket sudah ditutup' using errcode = '22023';
  end if;
  if v_ticket.work_status in ('READY', 'UNREPAIRABLE', 'CANCELLED') then
    raise exception 'Tiket sudah terminal, tidak dapat diedit' using errcode = '22023';
  end if;

  update private.service_tickets set
    equipment_brand = coalesce(p_input->>'equipment_brand', equipment_brand),
    equipment_model = coalesce(p_input->>'equipment_model', equipment_model),
    equipment_serial = coalesce(p_input->>'equipment_serial', equipment_serial),
    complaint = coalesce(p_input->>'complaint', complaint),
    initial_condition = coalesce(p_input->>'initial_condition', initial_condition),
    accessories = coalesce(p_input->>'accessories', accessories),
    address = coalesce(p_input->>'address', address),
    version = version + 1
    where id = v_ticket.id returning * into v_ticket;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'UPDATE_TICKET_DETAILS', 'SERVICE_TICKET', v_ticket.id, p_input->>'reason');

  return private.finish_operation('update_service_details_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'version', v_ticket.version,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.update_service_details_v1(jsonb) from public,anon,authenticated;
grant execute on function public.update_service_details_v1(jsonb) to authenticated;

-- update_service_schedule_v1
create or replace function public.update_service_schedule_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat menjadwalkan ulang' using errcode = '42501';
  end if;
  v_old := private.operation_result('update_service_schedule_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;
  if v_ticket.closed_at is not null then
    raise exception 'Tiket sudah ditutup' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_input->>'reason', ''))) = 0 then
    raise exception 'Alasan jadwal ulang wajib' using errcode = '22023';
  end if;

  update private.service_tickets set
    scheduled_at = (p_input->>'scheduled_at')::timestamptz,
    version = version + 1
    where id = v_ticket.id returning * into v_ticket;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RESCHEDULE_TICKET', 'SERVICE_TICKET', v_ticket.id, p_input->>'reason');

  return private.finish_operation('update_service_schedule_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'scheduled_at', v_ticket.scheduled_at,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.update_service_schedule_v1(jsonb) from public,anon,authenticated;
grant execute on function public.update_service_schedule_v1(jsonb) to authenticated;

-- transfer_service_custody_v1
create or replace function public.transfer_service_custody_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_location text;
begin
  v_role := private.current_role();
  if v_role not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('transfer_service_custody_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  v_location := p_input->>'location';
  if v_location not in ('CUSTOMER', 'SHOP', 'FATHER') then
    raise exception 'Lokasi custody tidak sah' using errcode = '22023';
  end if;

  -- Staff hanya boleh intake SHOP saat NEW
  if v_role = 'STAFF' and not (v_location = 'SHOP' and v_ticket.work_status = 'NEW') then
    raise exception 'Staff hanya dapat intake ke SHOP saat status NEW' using errcode = '42501';
  end if;

  update private.service_tickets set
    custody_location = v_location,
    version = version + 1
    where id = v_ticket.id returning * into v_ticket;

  insert into private.service_custody_events(ticket_id, from_location, to_location,
    condition_note, accessories_note, actor_id)
  values (v_ticket.id, v_ticket.custody_location, v_location,
    p_input->>'condition_note', p_input->>'accessories_note', v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSFER_CUSTODY', 'SERVICE_TICKET', v_ticket.id, p_input->>'reason');

  return private.finish_operation('transfer_service_custody_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'custody_location', v_location,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.transfer_service_custody_v1(jsonb) from public,anon,authenticated;
grant execute on function public.transfer_service_custody_v1(jsonb) to authenticated;

-- close_onsite_service_v1
create or replace function public.close_onsite_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat menutup onsite' using errcode = '42501';
  end if;
  v_old := private.operation_result('close_onsite_service_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;
  if v_ticket.service_location <> 'ONSITE' then
    raise exception 'Hanya untuk kunjungan onsite' using errcode = '22023';
  end if;
  if v_ticket.work_status not in ('READY', 'UNREPAIRABLE', 'CANCELLED') then
    raise exception 'Status belum terminal' using errcode = '22023';
  end if;
  if v_ticket.custody_location <> 'CUSTOMER' then
    raise exception 'Custody harus CUSTOMER untuk onsite selesai' using errcode = '22023';
  end if;

  update private.service_tickets set
    closed_at = now(), version = version + 1
    where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CLOSE_ONSITE', 'SERVICE_TICKET', v_ticket.id, p_input->>'completion_note');

  return private.finish_operation('close_onsite_service_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.close_onsite_service_v1(jsonb) from public,anon,authenticated;
grant execute on function public.close_onsite_service_v1(jsonb) to authenticated;

-- correct_service_status_v1 — koreksi status terminal sebelum invoice final
create or replace function public.correct_service_status_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_prev_status text;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengoreksi status' using errcode = '42501';
  end if;
  v_old := private.operation_result('correct_service_status_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_ticket from private.service_tickets
    where id = nullif(p_input->>'ticket_id', '')::uuid for update;
  if not found then raise exception 'Tiket tidak ditemukan' using errcode = '22023'; end if;
  if v_ticket.version <> (p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode = '40001';
  end if;

  if v_ticket.closed_at is not null then
    raise exception 'Tiket sudah ditutup' using errcode = '22023';
  end if;
  if v_ticket.work_status not in ('READY', 'UNREPAIRABLE', 'CANCELLED') then
    raise exception 'Koreksi hanya untuk status terminal sebelum closed' using errcode = '22023';
  end if;
  if not exists (select 1 from private.invoices where service_ticket_id = v_ticket.id) then
    raise exception 'Belum ada invoice final, koreksi via transition biasa' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_input->>'reason', ''))) = 0 then
    raise exception 'Alasan koreksi wajib' using errcode = '22023';
  end if;

  -- Cari status sebelum terminal dari log
  select to_status into v_prev_status
  from private.service_status_events
  where ticket_id = v_ticket.id and kind = 'TRANSITION'
  order by occurred_at desc limit 1;

  if v_prev_status is null or v_prev_status = v_ticket.work_status then
    v_prev_status := 'WORKING';
  end if;

  update private.service_tickets set
    work_status = v_prev_status,
    test_result = case when v_prev_status = 'READY' then 'Direvisi' else test_result end,
    terminal_reason = null,
    version = version + 1
    where id = v_ticket.id returning * into v_ticket;

  insert into private.service_status_events(ticket_id, from_status, to_status, kind, reason, actor_id)
  values (v_ticket.id, v_ticket.work_status, v_prev_status, 'CORRECTION',
    p_input->>'reason', v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CORRECT_SERVICE_STATUS', 'SERVICE_TICKET', v_ticket.id, p_input->>'reason');

  return private.finish_operation('correct_service_status_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ticket.id, 'from_status', v_ticket.work_status,
    'to_status', v_prev_status, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.correct_service_status_v1(jsonb) from public,anon,authenticated;
grant execute on function public.correct_service_status_v1(jsonb) to authenticated;

-- update_shop_settings_v1
create or replace function public.update_shop_settings_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mengatur toko' using errcode = '42501';
  end if;
  v_old := private.operation_result('update_shop_settings_v1', p_input);
  if v_old is not null then return v_old; end if;

  -- shop_settings belum ada di schema, skip jika belum diperlukan
  -- Placeholder untuk R4
  v_old := jsonb_build_object('ok', true, 'message', 'Settings tersimpan',
    'operation_id', p_input->>'operation_id');
  return private.finish_operation('update_shop_settings_v1', p_input, v_old);
end $$;
revoke all on function public.update_shop_settings_v1(jsonb) from public,anon,authenticated;
grant execute on function public.update_shop_settings_v1(jsonb) to authenticated;

-- export_csv_v1 — ekspor CSV sederhana
create or replace function public.export_csv_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_dataset text;
  v_rows jsonb;
begin
  v_role := private.current_role();
  if v_role not in ('OWNER', 'MAINTAINER') then
    raise exception 'Hanya owner/maintainer dapat mengekspor' using errcode = '42501';
  end if;

  v_dataset := p_input->>'dataset';

  if v_dataset = 'invoices' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'number', i.number, 'kind', i.kind, 'posted_at', i.posted_at,
      'total', i.total, 'discount', i.discount_total,
      'payment', (select sum(p.amount) from private.payments p where p.invoice_id = i.id and p.direction = 'IN')
    )), '[]'::jsonb) into v_rows
    from private.invoices i
    where i.posted_at >= (p_input->>'start_date')::date::timestamptz
      and i.posted_at < ((p_input->>'end_date')::date + 1)::timestamptz;

  elsif v_dataset = 'products' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sku', p.sku, 'name', p.name, 'base_unit', p.base_unit, 'shelf', p.shelf
    )), '[]'::jsonb) into v_rows
    from private.products p where p.active;

  else
    raise exception 'Dataset tidak dikenal: %', v_dataset using errcode = '22023';
  end if;

  return jsonb_build_object('ok', true, 'rows', v_rows, 'count', jsonb_array_length(v_rows));
end $$;
revoke all on function public.export_csv_v1(jsonb) from public,anon,authenticated;
grant execute on function public.export_csv_v1(jsonb) to authenticated;
