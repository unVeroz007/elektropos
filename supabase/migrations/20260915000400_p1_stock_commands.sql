create table private.document_sequences (
  kind text not null,
  business_date date not null,
  last_number integer not null check (last_number > 0),
  primary key(kind,business_date)
);
create table private.purchase_payments (
  id uuid primary key default gen_random_uuid(),
  stock_document_id uuid not null unique references private.stock_documents(id),
  method text not null check (method in ('TRANSFER','QRIS')),
  amount numeric(20,0) not null check (amount >= 0),
  confirmed_by uuid not null references auth.users(id),
  occurred_at timestamptz not null default now()
);
alter table private.document_sequences enable row level security;
alter table private.purchase_payments enable row level security;
revoke all on private.document_sequences,private.purchase_payments from public,anon,authenticated;

create or replace function private.next_stock_number(p_kind text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_date date; v_number integer;
begin
  v_date := (now() at time zone 'Asia/Jakarta')::date;
  insert into private.document_sequences(kind,business_date,last_number)
  values(p_kind,v_date,1)
  on conflict (kind,business_date) do update set last_number=private.document_sequences.last_number+1
  returning last_number into v_number;
  return p_kind || '-' || to_char(v_date,'YYYYMMDD') || '-' || lpad(v_number::text,6,'0');
end $$;
revoke all on function private.next_stock_number(text) from public,anon,authenticated;

create or replace function private.post_inbound(p_input jsonb,p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb; v_doc private.stock_documents%rowtype; v_item private.stock_document_items%rowtype;
  v_unit private.product_units%rowtype; v_product private.products%rowtype; v_lot private.inventory_lots%rowtype;
  v_position private.stock_positions%rowtype; v_line jsonb; v_phys jsonb; v_qty numeric; v_base numeric;
  v_cost numeric; v_total numeric:=0; v_pos_qty numeric; v_pos_sum numeric; v_index integer:=0;
  v_result jsonb; v_method text; v_capacity numeric; v_sealed boolean; v_label text;
begin
  v_actor:=private.require_owner(); v_old:=private.operation_result('post_'||lower(p_kind)||'_stock_v1',p_input);
  if v_old is not null then return v_old; end if;
  if jsonb_typeof(p_input->'items')<>'array' or jsonb_array_length(p_input->'items') not between 1 and 100 then
    raise exception 'Daftar barang wajib (1-100 baris)' using errcode='22023'; end if;
  -- Lock seluruh produk pada urutan id sebelum nomor dokumen/mutasi.
  perform 1 from private.products p where p.id in
    (select u.product_id from private.product_units u where u.id in
      (select (x->>'product_unit_id')::uuid from jsonb_array_elements(p_input->'items') x))
    order by p.id for update;
  insert into private.stock_documents(number,kind,supplier_id,source_note,source_date,actor_id,reason,operation_id)
  values(private.next_stock_number(p_kind),p_kind,nullif(p_input->>'supplier_id','')::uuid,
    p_input->>'source_note',nullif(p_input->>'source_date','')::date,v_actor,p_input->>'reason',
    (p_input->>'operation_id')::uuid) returning * into v_doc;
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_index:=v_index+1;
    select * into v_unit from private.product_units where id=(v_line->>'product_unit_id')::uuid and active;
    if not found then raise exception 'Satuan jual tidak aktif/tidak ditemukan' using errcode='22023'; end if;
    select * into v_product from private.products where id=v_unit.product_id and active;
    if not found then raise exception 'Produk diarsip' using errcode='22023'; end if;
    v_qty:=private.decimal_input(v_line->'qty',3,999999999.999);
    v_base:=v_qty*v_unit.factor_base;
    if mod(v_qty,v_unit.sale_step)<>0 or round(v_base,3)<>v_base or
       v_base>999999999.999 or mod(v_base,v_product.quantity_step)<>0 then
      raise exception 'Kuantitas/konversi tidak tepat' using errcode='22023'; end if;
    v_cost:=private.decimal_input(v_line->'acquisition_cost',0,9999999999999999,false);
    if v_cost=0 and length(trim(coalesce(v_line->>'free_reason','')))=0 then
      raise exception 'Modal nol memerlukan alasan perolehan gratis' using errcode='22023'; end if;
    v_total:=v_total+v_cost;
    insert into private.stock_document_items(document_id,line_no,product_id,unit_snapshot,qty_input,
      factor_snapshot,qty_base,acquisition_cost,destination_location,condition,note)
    values(v_doc.id,v_index,v_product.id,v_unit.label,v_qty,v_unit.factor_base,v_base,v_cost,
      'SHOP','SALEABLE',v_line->>'note') returning * into v_item;
    insert into private.inventory_lots(product_id,origin_item_id,original_qty,original_cost,remaining_qty,remaining_cost)
    values(v_product.id,v_item.id,v_base,v_cost,v_base,v_cost) returning * into v_lot;
    if v_product.track_segments then
      if jsonb_typeof(v_line->'positions')<>'array' then raise exception 'Roll memerlukan daftar posisi fisik' using errcode='22023'; end if;
      v_pos_sum:=0;
      for v_phys in select value from jsonb_array_elements(v_line->'positions') loop
        v_pos_qty:=private.decimal_input(v_phys->'qty_base',3,999999999.999);
        v_capacity:=private.decimal_input(v_phys->'segment_capacity',3,999999999.999);
        v_label:=nullif(trim(coalesce(v_phys->>'label','')),'');
        v_sealed:=coalesce((v_phys->>'sealed')::boolean,false);
        if v_label is null or v_pos_qty>v_capacity or (v_sealed and v_pos_qty<>v_capacity) or
           mod(v_pos_qty,v_product.quantity_step)<>0 then
          raise exception 'Label/kapasitas posisi roll tidak sah' using errcode='22023'; end if;
        v_pos_sum:=v_pos_sum+v_pos_qty;
        insert into private.stock_positions(lot_id,location,condition,qty_base,label,segment_capacity,sealed)
        values(v_lot.id,'SHOP','SALEABLE',v_pos_qty,v_label,v_capacity,v_sealed) returning * into v_position;
        insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
          stock_document_item_id,actor_id,operation_id)
        values(v_doc.id,v_lot.id,v_position.id,v_pos_qty,0,p_kind,v_item.id,v_actor,(p_input->>'operation_id')::uuid);
      end loop;
      if v_pos_sum<>v_base then raise exception 'Jumlah posisi roll berbeda dari barang masuk' using errcode='22023'; end if;
      -- Modal dicatat sekali pada gerakan pertama lot agar ledger cost merekonsiliasi saldo lot.
      update private.stock_movements set cost_delta=v_cost where id=(
        select id from private.stock_movements where lot_id=v_lot.id order by occurred_at,id limit 1);
    else
      if v_line ? 'positions' then raise exception 'Produk bulk tidak memakai posisi roll' using errcode='22023'; end if;
      insert into private.stock_positions(lot_id,location,condition,qty_base)
      values(v_lot.id,'SHOP','SALEABLE',v_base) returning * into v_position;
      insert into private.stock_movements(group_id,lot_id,position_id,qty_delta,cost_delta,kind,
        stock_document_item_id,actor_id,operation_id)
      values(v_doc.id,v_lot.id,v_position.id,v_base,v_cost,p_kind,v_item.id,v_actor,(p_input->>'operation_id')::uuid);
    end if;
  end loop;
  if p_kind='RECEIPT' then
    v_method:=p_input->'payment'->>'method';
    if v_method not in ('TRANSFER','QRIS') or coalesce((p_input->'payment'->>'confirmed')::boolean,false)<>true or
       private.decimal_input(p_input->'payment'->'amount',0,9999999999999999,false)<>v_total then
      raise exception 'Pembelian harus lunas dan dikonfirmasi (TRANSFER/QRIS pada P1)' using errcode='22023'; end if;
    insert into private.purchase_payments(stock_document_id,method,amount,confirmed_by)
    values(v_doc.id,v_method,v_total,v_actor);
  end if;
  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
  values(v_actor,'POST_'||p_kind,'STOCK_DOCUMENT',v_doc.id,p_input->>'reason');
  v_result:=jsonb_build_object('ok',true,'entity_id',v_doc.id,'document_number',v_doc.number,
    'operation_id',p_input->>'operation_id','server_time',now(),'total_cost',v_total::text);
  return private.finish_operation('post_'||lower(p_kind)||'_stock_v1',p_input,v_result);
end $$;
revoke all on function private.post_inbound(jsonb,text) from public,anon,authenticated;

create or replace function public.post_opening_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return private.post_inbound(p_input,'OPENING'); end $$;
create or replace function public.post_stock_receipt_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return private.post_inbound(p_input,'RECEIPT'); end $$;
revoke all on function public.post_opening_stock_v1(jsonb),public.post_stock_receipt_v1(jsonb) from public,anon,authenticated;
grant execute on function public.post_opening_stock_v1(jsonb),public.post_stock_receipt_v1(jsonb) to authenticated;

create or replace function private.cost_for_exit(p_lot private.inventory_lots,p_qty numeric)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_n numeric; v_d numeric; v_floor numeric; v_remainder numeric;
begin
  if p_qty=p_lot.remaining_qty then return p_lot.remaining_cost; end if;
  v_n := (p_lot.remaining_cost*1000000)::numeric * (p_qty*1000)::numeric;
  v_d := p_lot.remaining_qty*1000;
  v_floor := trunc(v_n/v_d);
  v_remainder := mod(v_n,v_d);
  return (v_floor + case when 2*v_remainder>=v_d then 1 else 0 end)/1000000;
end $$;
revoke all on function private.cost_for_exit(private.inventory_lots,numeric) from public,anon,authenticated;
