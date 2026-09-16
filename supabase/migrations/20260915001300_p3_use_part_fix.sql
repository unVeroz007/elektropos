-- P3 fix: use_service_part_v1 harus pakai service_part_event_id di cost_allocations

create or replace function public.use_service_part_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_product private.products%rowtype;
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

  if not exists (select 1 from private.service_estimates where ticket_id = v_ticket.id and status = 'APPROVED') then
    raise exception 'Belum ada estimasi yang disetujui' using errcode = '22023';
  end if;

  select l.* into v_lot from private.inventory_lots l
    join private.stock_positions s on s.lot_id = l.id
    where s.id = (p_input->>'position_id')::uuid;
  if not found then raise exception 'Posisi part tidak ditemukan' using errcode = '22023'; end if;

  select * into v_product from private.products where id = v_lot.product_id;

  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);
  select * into v_pos from private.stock_positions
    where id = (p_input->>'position_id')::uuid for update;
  if v_pos.qty_base < v_qty then
    raise exception 'INSUFFICIENT_STOCK' using errcode = '22023';
  end if;

  v_cost := private.cost_for_exit_lot(v_lot.id, v_qty);
  v_price := coalesce(private.decimal_input(p_input->'charge_unit_price', 6, 999999999999.999999, false), 0);

  update private.stock_positions set qty_base = qty_base - v_qty,
    sealed = false, version = version + 1 where id = v_pos.id;
  update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
    remaining_cost = remaining_cost - v_cost, version = version + 1
    where id = v_lot.id;

  insert into private.service_part_events(
    ticket_id, product_id, kind, qty_base, charge_unit_price, actor_id)
  values (v_ticket.id, v_product.id, 'USE', v_qty, v_price, v_actor)
  returning id into v_event_id;

  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta,
    kind, service_part_event_id, actor_id, operation_id)
  values (v_event_id, v_lot.id, v_pos.id, -v_qty, -v_cost,
    'SALE_OUT', v_event_id, v_actor, (p_input->>'operation_id')::uuid);

  insert into private.cost_allocations(lot_id, origin_position_id, service_part_event_id,
    qty_base, cost_amount, occurred_at)
  values (v_lot.id, v_pos.id, v_event_id, v_qty, v_cost, now());

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'USE_PART', 'SERVICE_PART_EVENT', v_event_id, p_input->>'reason');

  return private.finish_operation('use_service_part_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_event_id, 'qty_base', v_qty::text,
    'cost', v_cost::text, 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.use_service_part_v1(jsonb) from public,anon,authenticated;
grant execute on function public.use_service_part_v1(jsonb) to authenticated;
