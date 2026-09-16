-- Migrasi 006: adjust_stock_v1 dan post_stock_count_v1

-- adjust_stock_v1: koreksi stok positif/negatif dengan alasan.
-- Positif membutuhkan modal; negatif mengurangi modal sesuai alokasi lot.

create or replace function public.adjust_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb;
  v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype;
  v_item private.stock_document_items%rowtype; v_dest private.stock_positions%rowtype;
  v_qty numeric; v_cost numeric; v_result jsonb; v_new_lot private.inventory_lots%rowtype;
begin
  v_actor := private.require_owner();
  v_old := private.operation_result('adjust_stock_v1', p_input);
  if v_old is not null then return v_old; end if;

  select l.* into v_lot from private.inventory_lots l join private.stock_positions s on s.lot_id=l.id
    where s.id=(p_input->>'position_id')::uuid;
  if not found then raise exception 'Posisi tidak ditemukan' using errcode='22023'; end if;

  select * into v_product from private.products where id=v_lot.product_id for update;
  select * into v_lot from private.inventory_lots where id=v_lot.id for update;
  select * into v_source from private.stock_positions where id=(p_input->>'position_id')::uuid for update;
  if v_source.version<>(p_input->>'expected_version')::integer then
    raise exception 'VERSION_CONFLICT' using errcode='40001';
  end if;

  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);

  if v_qty > 0 then
    -- Penyesuaian positif: butuh modal, buat lot baru
    if mod(v_qty, v_product.quantity_step) <> 0 then
      raise exception 'Kuantitas tidak memenuhi langkah stok' using errcode='22023';
    end if;
    v_cost := coalesce(private.decimal_input(p_input->'acquisition_cost', 6, 9999999999999999, false), 0);
    if v_cost = 0 and length(trim(coalesce(p_input->>'reason',''))) = 0 then
      raise exception 'Modal nol memerlukan alasan' using errcode='22023';
    end if;

    insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
      values(private.next_stock_number('ADJUSTMENT'), 'ADJUSTMENT', v_actor,
        p_input->>'reason', (p_input->>'operation_id')::uuid)
      returning * into v_doc;
    insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,
      qty_input,factor_snapshot,qty_base,acquisition_cost,source_location,destination_location,condition,note)
      values(v_doc.id,1,v_product.id,v_product.base_unit,v_qty,1,v_qty,v_cost,
        v_source.location,v_source.location,v_source.condition,'Penyesuaian positif')
      returning * into v_item;
    -- Lot baru untuk penyesuaian positif
    insert into private.inventory_lots(product_id,origin_item_id,posted_at,original_qty,
      original_cost,remaining_qty,remaining_cost)
      values(v_product.id,v_item.id,now(),v_qty,v_cost,v_qty,v_cost)
      returning * into v_new_lot;
    insert into private.stock_positions(lot_id,location,condition,qty_base)
      values(v_new_lot.id,v_source.location,v_source.condition,v_qty)
      returning * into v_dest;
    insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
      stock_document_item_id,actor_id,operation_id)
      values(v_doc.id,v_new_lot.id,v_dest.id,v_qty,v_cost,'ADJUST_IN',
        v_item.id,v_actor,(p_input->>'operation_id')::uuid);

  else
    -- Penyesuaian negatif: kurangi dari posisi/lot yang ada
    if abs(v_qty) > v_source.qty_base then
      raise exception 'INSUFFICIENT_STOCK' using errcode='22023';
    end if;
    if mod(abs(v_qty), v_product.quantity_step) <> 0 then
      raise exception 'Kuantitas tidak memenuhi langkah stok' using errcode='22023';
    end if;
    v_cost := private.cost_for_exit(v_lot, abs(v_qty));

    insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
      values(private.next_stock_number('ADJUSTMENT'), 'ADJUSTMENT', v_actor,
        p_input->>'reason', (p_input->>'operation_id')::uuid)
      returning * into v_doc;
    insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,
      qty_input,factor_snapshot,qty_base,acquisition_cost,source_location,condition,note)
      values(v_doc.id,1,v_product.id,v_product.base_unit,abs(v_qty),1,abs(v_qty),
        v_cost,v_source.location,v_source.condition,'Penyesuaian negatif')
      returning * into v_item;
    update private.stock_positions set qty_base=qty_base-v_qty,sealed=false,version=version+1
      where id=v_source.id;
    update private.inventory_lots set remaining_qty=remaining_qty+v_qty,
      remaining_cost=remaining_cost-v_cost, version=version+1 where id=v_lot.id;
    insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
      stock_document_item_id,actor_id,operation_id)
      values(v_doc.id,v_lot.id,v_source.id,v_qty,-v_cost,'ADJUST_OUT',
        v_item.id,v_actor,(p_input->>'operation_id')::uuid);
  end if;

  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
    values(v_actor,'ADJUST_STOCK','STOCK_DOCUMENT',v_doc.id,p_input->>'reason');

  v_result := jsonb_build_object('ok',true,'entity_id',v_doc.id,
    'document_number',v_doc.number,'operation_id',p_input->>'operation_id');
  return private.finish_operation('adjust_stock_v1', p_input, v_result);
end $$;
revoke all on function public.adjust_stock_v1(jsonb) from public,anon,authenticated;
grant execute on function public.adjust_stock_v1(jsonb) to authenticated;


-- post_stock_count_v1: opname atomik atau conflict jika version berubah.

create or replace function public.post_stock_count_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb;
  v_count private.stock_counts%rowtype; v_item private.stock_count_items%rowtype;
  v_pos private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype;
  v_di private.stock_document_items%rowtype; v_adj private.stock_positions%rowtype;
  v_entry jsonb; v_diff numeric; v_cost numeric; v_result jsonb;
begin
  v_actor := private.require_owner();
  v_old := private.operation_result('post_stock_count_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_count from private.stock_counts
    where id=(p_input->>'count_id')::uuid for update;
  if not found then raise exception 'Hitungan tidak ditemukan' using errcode='22023'; end if;
  if v_count.status = 'POSTED' then
    raise exception 'ALREADY_SETTLED' using errcode='40001';
  end if;

  -- Proses setiap item hitung
  for v_entry in select value from jsonb_array_elements(p_input->'items') loop
    select * into v_pos from private.stock_positions
      where id=(v_entry->>'position_id')::uuid for update;
    if not found then raise exception 'Posisi opname tidak ditemukan' using errcode='22023'; end if;
    if v_pos.version<>(v_entry->>'expected_version')::integer then
      raise exception 'VERSION_CONFLICT: posisi berubah saat menghitung' using errcode='40001';
    end if;

    v_diff := (v_entry->>'counted_qty')::numeric - v_pos.qty_base;
    if abs(v_diff) < 0.0005 then continue; end if; -- toleransi floating kecil, skip jika sama

    select * into v_lot from private.inventory_lots where id=v_pos.lot_id for update;
    select * into v_product from private.products where id=v_lot.product_id for update;

    if v_diff > 0 then
      -- Stok lebih banyak: penyesuaian positif tanpa modal (stok ditemukan)
      insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
        values(private.next_stock_number('COUNT'),'COUNT',v_actor,
          'Hasil opname '||v_count.id::text,(p_input->>'operation_id')::uuid)
        returning * into v_doc;
      insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,
        qty_input,factor_snapshot,qty_base,source_location,destination_location,condition,note)
        values(v_doc.id,1,v_product.id,v_product.base_unit,v_diff,1,v_diff,
          v_pos.location,v_pos.location,v_pos.condition,'Opname tambahan')
        returning * into v_di;
      insert into private.inventory_lots(product_id,origin_item_id,posted_at,
        original_qty,original_cost,remaining_qty,remaining_cost)
        values(v_product.id,v_di.id,now(),v_diff,0,v_diff,0)
        returning * into v_lot; -- reassign v_lot to new one
      insert into private.stock_positions(lot_id,location,condition,qty_base)
        values(v_lot.id,v_pos.location,v_pos.condition,v_diff)
        returning * into v_adj;
      insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
        stock_document_item_id,actor_id,operation_id)
        values(v_doc.id,v_lot.id,v_adj.id,v_diff,0,'COUNT_IN',
          v_di.id,v_actor,(p_input->>'operation_id')::uuid);
    else
      -- Stok kurang: penyesuaian negatif dengan modal
      v_cost := private.cost_for_exit(v_lot, abs(v_diff));
      insert into private.stock_documents(number,kind,actor_id,reason,operation_id)
        values(private.next_stock_number('COUNT'),'COUNT',v_actor,
          'Hasil opname '||v_count.id::text,(p_input->>'operation_id')::uuid)
        returning * into v_doc;
      insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,
        qty_input,factor_snapshot,qty_base,acquisition_cost,source_location,condition,note)
        values(v_doc.id,1,v_product.id,v_product.base_unit,abs(v_diff),1,abs(v_diff),
          v_cost,v_pos.location,v_pos.condition,'Opname kurang')
        returning * into v_di;
      update private.stock_positions set qty_base=qty_base+v_diff,sealed=false,version=version+1
        where id=v_pos.id;
      update private.inventory_lots set remaining_qty=remaining_qty+v_diff,
        remaining_cost=remaining_cost-v_cost, version=version+1 where id=v_lot.id;
      insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
        stock_document_item_id,actor_id,operation_id)
        values(v_doc.id,v_lot.id,v_pos.id,v_diff,-v_cost,'COUNT_OUT',
          v_di.id,v_actor,(p_input->>'operation_id')::uuid);
    end if;

    -- Catat item opname
    insert into private.stock_count_items(count_id,position_id,expected_version,
      system_qty,counted_qty,reason)
    values(v_count.id,v_pos.id,v_pos.version,v_pos.qty_base,
      (v_entry->>'counted_qty')::numeric,coalesce(v_entry->>'reason',''));
  end loop;

  -- Tandai count sebagai posted, tautkan dokumen koreksi terakhir
  update private.stock_counts set status='POSTED', posted_document_id=(
    select id from private.stock_documents where operation_id=(p_input->>'operation_id')::uuid
    order by occurred_at desc limit 1)
    where id=v_count.id;

  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
    values(v_actor,'POST_STOCK_COUNT','STOCK_COUNT',v_count.id,p_input->>'reason');

  v_result := jsonb_build_object('ok',true,'entity_id',v_count.id,
    'operation_id',p_input->>'operation_id');
  return private.finish_operation('post_stock_count_v1', p_input, v_result);
end $$;
revoke all on function public.post_stock_count_v1(jsonb) from public,anon,authenticated;
grant execute on function public.post_stock_count_v1(jsonb) to authenticated;
