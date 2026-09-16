create or replace function private.decimal_input(p_value jsonb, p_scale integer, p_max numeric, p_positive boolean default true)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_text text; v_value numeric;
begin
  if jsonb_typeof(p_value) <> 'string' then raise exception 'Angka harus string desimal' using errcode='22023'; end if;
  v_text := p_value #>> '{}';
  if v_text !~ '^(0|[1-9][0-9]*)(\.[0-9]+)?$' or
     length(coalesce(split_part(v_text, '.', 2), '')) > p_scale then
    raise exception 'Format/presisi angka tidak sah' using errcode='22023';
  end if;
  v_value := v_text::numeric;
  if v_value > p_max or (p_positive and v_value <= 0) then
    raise exception 'Angka di luar batas' using errcode='22023';
  end if;
  return v_value;
end $$;
revoke all on function private.decimal_input(jsonb,integer,numeric,boolean) from public,anon,authenticated;

create or replace function private.require_owner()
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if private.current_role() <> 'OWNER' then raise exception 'Hanya owner yang boleh mengubah data usaha' using errcode='42501'; end if;
  return auth.uid();
end $$;
revoke all on function private.require_owner() from public,anon,authenticated;

create or replace function private.operation_result(p_command text, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old private.operations%rowtype; v_key uuid;
begin
  if jsonb_typeof(p_input) <> 'object' or (p_input->>'operation_id') is null then
    raise exception 'operation_id wajib' using errcode='22023';
  end if;
  v_key := (p_input->>'operation_id')::uuid;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || p_command || ':' || v_key::text, 0));
  select * into v_old from private.operations where actor_id=auth.uid() and command=p_command and operation_id=v_key;
  if found then
    if v_old.payload <> p_input then raise exception 'IDEMPOTENCY_CONFLICT' using errcode='22023'; end if;
    return v_old.result;
  end if;
  return null;
end $$;
revoke all on function private.operation_result(text,jsonb) from public,anon,authenticated;

create or replace function private.finish_operation(p_command text, p_input jsonb, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  insert into private.operations(actor_id,command,operation_id,payload,result)
  values(auth.uid(),p_command,(p_input->>'operation_id')::uuid,p_input,p_result);
  return p_result;
end $$;
revoke all on function private.finish_operation(text,jsonb,jsonb) from public,anon,authenticated;

create or replace function public.upsert_product_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb; v_product private.products%rowtype; v_unit private.product_units%rowtype;
  v_factor numeric; v_step numeric; v_price numeric; v_qty_step numeric; v_result jsonb; v_barcode text;
begin
  v_actor := private.require_owner();
  v_old := private.operation_result('upsert_product_v1',p_input); if v_old is not null then return v_old; end if;
  if (select count(*) from jsonb_object_keys(p_input)) <> (select count(*) from jsonb_object_keys(p_input) as k where k in
    ('operation_id','product_id','expected_version','sku','name','specification','base_unit','quantity_step','track_segments','unit_label','factor_base','sale_step','sell_price','barcode','shelf','reason')) then
    raise exception 'Field produk tidak dikenal' using errcode='22023';
  end if;
  v_qty_step := private.decimal_input(p_input->'quantity_step',3,999999999.999);
  v_factor := private.decimal_input(p_input->'factor_base',3,1000000);
  v_step := private.decimal_input(p_input->'sale_step',3,999999999.999);
  v_price := private.decimal_input(p_input->'sell_price',6,999999999999.999999);
  if round(v_step*v_factor,3) <> v_step*v_factor or mod(v_step*v_factor,v_qty_step) <> 0 then
    raise exception 'Konversi tidak memenuhi langkah stok' using errcode='22023';
  end if;
  if length(trim(coalesce(p_input->>'sku',''))) not between 1 and 60 or
     length(trim(coalesce(p_input->>'name',''))) not between 1 and 150 or
     length(trim(coalesce(p_input->>'base_unit',''))) not between 1 and 30 then
    raise exception 'Identitas produk wajib/lampaui batas' using errcode='22023';
  end if;
  if p_input ? 'product_id' then
    select * into v_product from private.products where id=(p_input->>'product_id')::uuid for update;
    if not found then raise exception 'Produk tidak ditemukan' using errcode='22023'; end if;
    if v_product.version <> (p_input->>'expected_version')::integer then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
    if v_product.base_unit <> p_input->>'base_unit' or v_product.quantity_step <> v_qty_step or
       v_product.track_segments <> coalesce((p_input->>'track_segments')::boolean,false) then
      raise exception 'Satuan dasar/langkah/tracking tidak boleh diubah pada produk yang sudah dipakai' using errcode='22023';
    end if;
    update private.products set sku=trim(p_input->>'sku'),name=trim(p_input->>'name'),
      specification=coalesce(p_input->>'specification',''), shelf=nullif(trim(coalesce(p_input->>'shelf','')),''), version=version+1
      where id=v_product.id returning * into v_product;
    update private.product_units set active=false,is_default=false where product_id=v_product.id and is_default returning * into v_unit;
    if found then
      insert into private.product_price_history(unit_id,before_price,after_price,reason,actor_id)
      values(v_unit.id,v_unit.sell_price,v_price,p_input->>'reason',v_actor);
    end if;
  else
    insert into private.products(sku,name,specification,base_unit,quantity_step,track_segments,shelf)
    values(trim(p_input->>'sku'),trim(p_input->>'name'),coalesce(p_input->>'specification',''),
      trim(p_input->>'base_unit'),v_qty_step,coalesce((p_input->>'track_segments')::boolean,false),
      nullif(trim(coalesce(p_input->>'shelf','')),'')) returning * into v_product;
  end if;
  insert into private.product_units(product_id,label,factor_base,sale_step,sell_price,is_default)
  values(v_product.id,trim(p_input->>'unit_label'),v_factor,v_step,v_price,true) returning * into v_unit;
  v_barcode := nullif(trim(coalesce(p_input->>'barcode','')),'');
  if v_barcode is not null then
    insert into private.product_barcodes(product_id,product_unit_id,code)
    values(v_product.id,v_unit.id,v_barcode);
  end if;
  insert into private.audit_events(actor_id,action,entity_type,entity_id,reason)
  values(v_actor,'UPSERT_PRODUCT','PRODUCT',v_product.id,p_input->>'reason');
  v_result := jsonb_build_object('ok',true,'entity_id',v_product.id,'version',v_product.version,
    'operation_id',p_input->>'operation_id','server_time',now(),'schema_version',1);
  return private.finish_operation('upsert_product_v1',p_input,v_result);
end $$;
revoke all on function public.upsert_product_v1(jsonb) from public,anon,authenticated;
grant execute on function public.upsert_product_v1(jsonb) to authenticated;

create or replace function public.archive_product_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_product private.products%rowtype; v_old jsonb; v_result jsonb;
begin
  v_actor:=private.require_owner(); v_old:=private.operation_result('archive_product_v1',p_input);
  if v_old is not null then return v_old; end if;
  select * into v_product from private.products where id=(p_input->>'product_id')::uuid for update;
  if not found then raise exception 'Produk tidak ditemukan' using errcode='22023'; end if;
  if v_product.version <> (p_input->>'expected_version')::integer then raise exception 'VERSION_CONFLICT' using errcode='40001'; end if;
  update private.products set active=false,version=version+1 where id=v_product.id returning * into v_product;
  insert into private.audit_events(actor_id,action,entity_type,entity_id) values(v_actor,'ARCHIVE_PRODUCT','PRODUCT',v_product.id);
  v_result:=jsonb_build_object('ok',true,'entity_id',v_product.id,'version',v_product.version,'operation_id',p_input->>'operation_id');
  return private.finish_operation('archive_product_v1',p_input,v_result);
end $$;
revoke all on function public.archive_product_v1(jsonb) from public,anon,authenticated;
grant execute on function public.archive_product_v1(jsonb) to authenticated;

create or replace function public.search_products_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_query text:=lower(trim(coalesce(p_input->>'query',''))); v_limit integer:=coalesce((p_input->>'limit')::integer,25); v_result jsonb;
begin
  perform private.current_role();
  if length(v_query)>120 or v_limit not between 1 and 100 then raise exception 'Batas pencarian tidak sah' using errcode='22023'; end if;
  select coalesce(jsonb_agg(x.payload order by x.name,x.id),'[]'::jsonb) into v_result from (
    select p.id,p.name,jsonb_build_object('id',p.id,'sku',p.sku,'name',p.name,'specification',p.specification,
      'base_unit',p.base_unit,'shelf',p.shelf,'track_segments',p.track_segments,
      'units',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'label',u.label,'factor_base',u.factor_base::text,
        'sale_step',u.sale_step::text,'sell_price',u.sell_price::text,'version',u.version) order by u.is_default desc,u.label),'[]'::jsonb)
        from private.product_units u where u.product_id=p.id and u.active),
      'stock_shop',(select coalesce(sum(s.qty_base),0)::text from private.stock_positions s join private.inventory_lots l on l.id=s.lot_id
        where l.product_id=p.id and s.location='SHOP' and s.condition='SALEABLE'),
      'stock_field',(select coalesce(sum(s.qty_base),0)::text from private.stock_positions s join private.inventory_lots l on l.id=s.lot_id
        where l.product_id=p.id and s.location='FIELD_FATHER' and s.condition='SALEABLE')) payload
    from private.products p where p.active and
      (v_query='' or lower(p.name) like v_query||'%' or lower(p.sku)=v_query or
        exists(select 1 from private.product_barcodes b where b.product_id=p.id and lower(b.code)=v_query) or
        exists(select 1 from unnest(p.aliases) a where lower(a) like v_query||'%'))
    order by p.name,p.id limit v_limit
  ) x;
  return v_result;
end $$;
revoke all on function public.search_products_v1(jsonb) from public,anon,authenticated;
grant execute on function public.search_products_v1(jsonb) to authenticated;

create or replace function public.get_product_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_role text; v_result jsonb;
begin
  v_role:=private.current_role();
  select jsonb_build_object('id',p.id,'sku',p.sku,'name',p.name,'specification',p.specification,
    'base_unit',p.base_unit,'version',p.version,'active',p.active,
    'units',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'label',u.label,'factor_base',u.factor_base::text,
      'sale_step',u.sale_step::text,'sell_price',u.sell_price::text,'version',u.version,'active',u.active)),'[]'::jsonb)
      from private.product_units u where u.product_id=p.id),
    'barcodes',(select coalesce(jsonb_agg(b.code),'[]'::jsonb) from private.product_barcodes b where b.product_id=p.id),
    'positions',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'label',s.label,'location',s.location,
       'condition',s.condition,'qty_base',s.qty_base::text,'segment_capacity',s.segment_capacity::text,'sealed',s.sealed,'version',s.version)
       order by s.label,s.id),'[]'::jsonb) from private.stock_positions s join private.inventory_lots l on l.id=s.lot_id
       where l.product_id=p.id and s.qty_base>0),
    'lots',case when v_role in ('OWNER','MAINTAINER') then
      (select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'remaining_qty',l.remaining_qty::text,
       'remaining_cost',l.remaining_cost::text)),'[]'::jsonb) from private.inventory_lots l where l.product_id=p.id)
      else null end) into v_result from private.products p where p.id=(p_input->>'product_id')::uuid;
  if v_result is null then raise exception 'Produk tidak ditemukan' using errcode='22023'; end if;
  if v_role='STAFF' then return v_result - 'lots'; end if;
  return v_result;
end $$;
revoke all on function public.get_product_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_product_v1(jsonb) to authenticated;
