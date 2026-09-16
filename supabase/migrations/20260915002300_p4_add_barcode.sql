-- Tambah barcode ke produk yang sudah ada (owner)
create or replace function public.add_product_barcode_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_code text;
  v_product_id uuid;
  v_unit_id uuid;
  v_unit_product uuid;
begin
  if private.current_role() <> 'OWNER' then
    raise exception 'Hanya owner dapat mendaftarkan barcode' using errcode = '42501';
  end if;
  v_old := private.operation_result('add_product_barcode_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_code := trim(coalesce(p_input->>'code', ''));
  if length(v_code) not between 1 and 100 then
    raise exception 'Kode barcode harus 1-100 karakter' using errcode = '22023';
  end if;

  v_product_id := nullif(p_input->>'product_id', '')::uuid;
  if v_product_id is null then
    raise exception 'Produk wajib dipilih' using errcode = '22023';
  end if;

  if not exists (select 1 from private.products where id = v_product_id and active) then
    raise exception 'Produk tidak ditemukan atau diarsip' using errcode = '22023';
  end if;

  -- Barcode sudah dipakai produk lain
  if exists (select 1 from private.product_barcodes where code = v_code) then
    raise exception 'Barcode sudah terdaftar pada produk lain' using errcode = '23505';
  end if;

  -- Unit opsional; bila diisi harus milik produk yang sama
  v_unit_id := nullif(p_input->>'product_unit_id', '')::uuid;
  if v_unit_id is not null then
    select product_id into v_unit_product from private.product_units where id = v_unit_id;
    if v_unit_product is null then
      raise exception 'Satuan tidak ditemukan' using errcode = '22023';
    end if;
    if v_unit_product <> v_product_id then
      raise exception 'Satuan bukan milik produk yang dipilih' using errcode = '22023';
    end if;
  end if;

  insert into private.product_barcodes(product_id, product_unit_id, code)
  values (v_product_id, v_unit_id, v_code);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'ADD_PRODUCT_BARCODE', 'PRODUCT', v_product_id, v_code);

  return private.finish_operation('add_product_barcode_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_product_id, 'code', v_code,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.add_product_barcode_v1(jsonb) from public,anon,authenticated;
grant execute on function public.add_product_barcode_v1(jsonb) to authenticated;
