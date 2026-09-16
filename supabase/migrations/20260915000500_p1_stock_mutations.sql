create or replace function public.transfer_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb; v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_dest private.stock_positions%rowtype; v_doc private.stock_documents%rowtype;
  v_item private.stock_document_items%rowtype; v_qty numeric; v_location text; v_condition text; v_label text; v_result jsonb;
begin
  v_actor:=private.require_owner(); v_old:=private.operation_result('transfer_stock_v1',p_input);
  if v_old is not null then return v_old; end if;
  select l.* into v_lot from private.inventory_lots l join private.stock_positions s on s.lot_id=l.id
    where s.id=(p_input->>'position_id')::uuid;
  if not found then raise exception 'Posisi tidak ditemukan' using errcode='22023'; end if;
  select * into v_product from private.products where id=v_lot.product_id for update;
  select * into v_lot from private.inventory_lots where id=v_lot.id for update;
  select * into v_source from private.stock_positions where id=(p_input->>'position_id')::uuid for update;
  if v_source.version<>(p_input->>'expected_version')::integer then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  v_qty:=private.decimal_input(p_input->'qty_base',3,999999999.999);
  if v_qty>v_source.qty_base or mod(v_qty,v_product.quantity_step)<>0 then raise exception 'INSUFFICIENT_STOCK' using errcode='22023'; end if;
  v_location:=p_input->>'destination_location'; v_condition:=coalesce(p_input->>'destination_condition',v_source.condition);
  if v_location not in ('SHOP','FIELD_FATHER') or v_condition not in ('SALEABLE','DAMAGED') or
     (v_location=v_source.location and v_condition=v_source.condition) then
    raise exception 'Tujuan transfer tidak sah' using errcode='22023'; end if;
  v_label:=nullif(trim(coalesce(p_input->>'destination_label','')),'');
  if v_product.track_segments and v_label is null then raise exception 'Posisi roll tujuan memerlukan label baru' using errcode='22023'; end if;
  insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
    values(private.next_stock_number('TRANSFER'),'TRANSFER',v_actor,p_input->>'reason',(p_input->>'operation_id')::uuid)
    returning * into v_doc;
  insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,qty_input,factor_snapshot,
    qty_base,source_location,destination_location,condition,note)
    values(v_doc.id,1,v_product.id,v_product.base_unit,v_qty,1,v_qty,v_source.location,v_location,v_condition,p_input->>'note')
    returning * into v_item;
  update private.stock_positions set qty_base=qty_base-v_qty,sealed=false,version=version+1
    where id=v_source.id;
  insert into private.stock_positions(lot_id,location,condition,qty_base,label,segment_capacity,sealed)
    values(v_lot.id,v_location,v_condition,v_qty,v_label,
      case when v_product.track_segments then
        case when v_qty=v_source.qty_base then v_source.segment_capacity else v_qty end else null end,
      v_product.track_segments and v_source.sealed and v_qty=v_source.qty_base)
    returning * into v_dest;
  insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
    stock_document_item_id,actor_id,operation_id)
    values(v_doc.id,v_lot.id,v_source.id,-v_qty,0,'TRANSFER_OUT',v_item.id,v_actor,(p_input->>'operation_id')::uuid),
      (v_doc.id,v_lot.id,v_dest.id,v_qty,0,'TRANSFER_IN',v_item.id,v_actor,(p_input->>'operation_id')::uuid);
  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
    values(v_actor,'TRANSFER_STOCK','STOCK_DOCUMENT',v_doc.id,p_input->>'reason');
  v_result:=jsonb_build_object('ok',true,'entity_id',v_doc.id,'document_number',v_doc.number,
    'source_position_id',v_source.id,'destination_position_id',v_dest.id,'operation_id',p_input->>'operation_id');
  return private.finish_operation('transfer_stock_v1',p_input,v_result);
end $$;
revoke all on function public.transfer_stock_v1(jsonb) from public,anon,authenticated;
grant execute on function public.transfer_stock_v1(jsonb) to authenticated;

create or replace function private.post_stock_exit(p_input jsonb,p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb; v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype; v_item private.stock_document_items%rowtype;
  v_qty numeric; v_cost numeric; v_result jsonb;
begin
  v_actor:=private.require_owner(); v_old:=private.operation_result('post_'||lower(p_kind)||'_v1',p_input);
  if v_old is not null then return v_old; end if;
  if length(trim(coalesce(p_input->>'reason','')))=0 then raise exception 'Alasan wajib' using errcode='22023'; end if;
  select l.* into v_lot from private.inventory_lots l join private.stock_positions s on s.lot_id=l.id
    where s.id=(p_input->>'position_id')::uuid;
  if not found then raise exception 'Posisi tidak ditemukan' using errcode='22023'; end if;
  select * into v_product from private.products where id=v_lot.product_id for update;
  select * into v_lot from private.inventory_lots where id=v_lot.id for update;
  select * into v_source from private.stock_positions where id=(p_input->>'position_id')::uuid for update;
  if v_source.version<>(p_input->>'expected_version')::integer then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  v_qty:=private.decimal_input(p_input->'qty_base',3,999999999.999);
  if v_qty>v_source.qty_base or mod(v_qty,v_product.quantity_step)<>0 then raise exception 'INSUFFICIENT_STOCK' using errcode='22023'; end if;
  v_cost:=private.cost_for_exit(v_lot,v_qty);
  insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
    values(private.next_stock_number(p_kind),p_kind,v_actor,p_input->>'reason',(p_input->>'operation_id')::uuid)
    returning * into v_doc;
  insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,qty_input,factor_snapshot,
    qty_base,acquisition_cost,source_location,condition)
    values(v_doc.id,1,v_product.id,v_product.base_unit,v_qty,1,v_qty,v_cost,v_source.location,v_source.condition)
    returning * into v_item;
  update private.stock_positions set qty_base=qty_base-v_qty,sealed=false,version=version+1 where id=v_source.id;
  update private.inventory_lots set remaining_qty=remaining_qty-v_qty,remaining_cost=remaining_cost-v_cost,
    version=version+1 where id=v_lot.id;
  insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
    stock_document_item_id,actor_id,operation_id)
    values(v_doc.id,v_lot.id,v_source.id,-v_qty,-v_cost,
      case when p_kind='DISPOSAL' then 'DISPOSAL' else 'ADJUST_OUT' end,v_item.id,v_actor,(p_input->>'operation_id')::uuid);
  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
    values(v_actor,'POST_'||p_kind,'STOCK_DOCUMENT',v_doc.id,p_input->>'reason');
  v_result:=jsonb_build_object('ok',true,'entity_id',v_doc.id,'document_number',v_doc.number,
    'cost_removed',v_cost::text,'operation_id',p_input->>'operation_id');
  return private.finish_operation('post_'||lower(p_kind)||'_v1',p_input,v_result);
end $$;
revoke all on function private.post_stock_exit(jsonb,text) from public,anon,authenticated;

create or replace function public.dispose_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return private.post_stock_exit(p_input,'DISPOSAL'); end $$;
revoke all on function public.dispose_stock_v1(jsonb) from public,anon,authenticated;
grant execute on function public.dispose_stock_v1(jsonb) to authenticated;
