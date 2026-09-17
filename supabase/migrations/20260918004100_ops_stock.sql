-- Perbaikan audit 2026-09: mutasi stok (transfer, penyesuaian, disposal, opname)
-- dan RPC baca posisi/riwayat mutasi. Temuan: T05 (penyesuaian negatif mustahil,
-- opname tanpa RPC pembuat, counted_qty tidak divalidasi), konvensi command
-- idempotensi = nama RPC publik, require_role (akun nonaktif ditolak).

-- Helper input bersama domain operasi --------------------------------------

-- operation_id wajib UUID; mengembalikan nilainya.
create or replace function private.ops_operation_id(p_input jsonb)
returns uuid language plpgsql immutable set search_path = '' as $$
declare v_id uuid;
begin
  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise exception 'INVALID_INPUT: Data permintaan harus berupa objek' using errcode = '22023';
  end if;
  begin
    v_id := (p_input->>'operation_id')::uuid;
  exception when others then
    raise exception 'INVALID_INPUT: operation_id tidak sah' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'INVALID_INPUT: operation_id wajib' using errcode = '22023';
  end if;
  return v_id;
end $$;

-- Tolak field yang tidak dikenal (API-01). Nama field aman untuk ditampilkan.
create or replace function private.ops_allowed_keys(p_input jsonb, p_allowed text[])
returns void language plpgsql immutable set search_path = '' as $$
declare v_unknown text;
begin
  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise exception 'INVALID_INPUT: Data permintaan harus berupa objek' using errcode = '22023';
  end if;
  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_input) k where not (k = any (p_allowed));
  if v_unknown is not null then
    raise exception 'INVALID_INPUT: Field tidak dikenal: %', left(v_unknown, 200) using errcode = '22023';
  end if;
end $$;

create or replace function private.ops_uuid(p_value jsonb, p_label text, p_required boolean default true)
returns uuid language plpgsql immutable set search_path = '' as $$
declare v_id uuid;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null'
     or (jsonb_typeof(p_value) = 'string' and trim(p_value #>> '{}') = '') then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_label using errcode = '22023';
    end if;
    return null;
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    raise exception 'INVALID_INPUT: % tidak sah', p_label using errcode = '22023';
  end if;
  begin
    v_id := (p_value #>> '{}')::uuid;
  exception when others then
    raise exception 'INVALID_INPUT: % tidak sah', p_label using errcode = '22023';
  end;
  return v_id;
end $$;

-- Bilangan bulat non-negatif (versi, lebar, limit): angka JSON atau teks digit.
create or replace function private.ops_int(p_value jsonb, p_label text, p_required boolean default true)
returns integer language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_label using errcode = '22023';
    end if;
    return null;
  end if;
  if jsonb_typeof(p_value) not in ('number', 'string') then
    raise exception 'INVALID_INPUT: % harus bilangan bulat', p_label using errcode = '22023';
  end if;
  v_text := p_value #>> '{}';
  if v_text !~ '^(0|[1-9][0-9]{0,8})$' then
    raise exception 'INVALID_INPUT: % harus bilangan bulat', p_label using errcode = '22023';
  end if;
  return v_text::integer;
end $$;

-- Teks opsional/wajib dengan batas panjang; hasil di-trim, kosong menjadi NULL.
create or replace function private.ops_text(p_value jsonb, p_label text, p_max integer, p_required boolean default false)
returns text language plpgsql immutable set search_path = '' as $$
declare v_text text;
begin
  if p_value is not null and jsonb_typeof(p_value) not in ('string', 'null') then
    raise exception 'INVALID_INPUT: % harus teks', p_label using errcode = '22023';
  end if;
  v_text := nullif(trim(coalesce(p_value #>> '{}', '')), '');
  if v_text is null and p_required then
    raise exception 'INVALID_INPUT: % wajib diisi', p_label using errcode = '22023';
  end if;
  if length(v_text) > p_max then
    raise exception 'INVALID_INPUT: % maksimal % karakter', p_label, p_max using errcode = '22023';
  end if;
  return v_text;
end $$;

create or replace function private.ops_bool(p_value jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case when p_value is not null and jsonb_typeof(p_value) = 'boolean' then (p_value #>> '{}')::boolean else false end
$$;

-- Modal lot koreksi: nominal Rupiah terkonfirmasi, atau nol dengan alasan tertulis.
create or replace function private.ops_correction_cost(p_cost jsonb, p_confirmed jsonb, p_zero_reason jsonb)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_cost numeric; v_reason text;
begin
  v_cost := private.decimal_input_opt(p_cost, 0, 9999999999999999, false);
  v_reason := private.ops_text(p_zero_reason, 'Alasan modal nol', 500);
  if v_cost is not null and v_cost > 0 then
    if v_reason is not null then
      raise exception 'INVALID_INPUT: Isi modal atau alasan modal nol, bukan keduanya' using errcode = '22023';
    end if;
    if not private.ops_bool(p_confirmed) then
      raise exception 'INVALID_INPUT: Modal barang masuk wajib dikonfirmasi (cost_confirmed)' using errcode = '22023';
    end if;
    return v_cost;
  end if;
  if v_reason is null then
    raise exception 'INVALID_INPUT: Barang masuk koreksi wajib modal terkonfirmasi atau alasan modal nol' using errcode = '22023';
  end if;
  return 0;
end $$;

revoke all on function private.ops_operation_id(jsonb) from public, anon, authenticated;
revoke all on function private.ops_allowed_keys(jsonb, text[]) from public, anon, authenticated;
revoke all on function private.ops_uuid(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function private.ops_int(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function private.ops_text(jsonb, text, integer, boolean) from public, anon, authenticated;
revoke all on function private.ops_bool(jsonb) from public, anon, authenticated;
revoke all on function private.ops_correction_cost(jsonb, jsonb, jsonb) from public, anon, authenticated;

-- Kunci posisi beserta produk dan lotnya dengan urutan global API-02
-- (products -> inventory_lots -> stock_positions). Versi diperiksa setelah lock.
create or replace function private.ops_lock_position(p_position_id uuid, p_expected_version integer)
returns private.stock_positions language plpgsql security definer set search_path = '' as $$
declare v_product_id uuid; v_lot_id uuid; v_pos private.stock_positions%rowtype;
begin
  select l.product_id, l.id into v_product_id, v_lot_id
    from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where s.id = p_position_id;
  if not found then
    raise exception 'NOT_FOUND: Posisi stok tidak ditemukan' using errcode = '22023';
  end if;
  perform 1 from private.products where id = v_product_id for update;
  perform 1 from private.inventory_lots where id = v_lot_id for update;
  select * into v_pos from private.stock_positions where id = p_position_id for update;
  if p_expected_version is not null and v_pos.version <> p_expected_version then
    raise exception 'VERSION_CONFLICT: Data stok sudah berubah. Muat ulang lalu periksa kembali.' using errcode = '40001';
  end if;
  return v_pos;
end $$;
revoke all on function private.ops_lock_position(uuid, integer) from public, anon, authenticated;

-- transfer_stock_v1 -----------------------------------------------------------

create or replace function public.transfer_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_result jsonb;
  v_qty numeric; v_reason text; v_note text; v_location text; v_condition text; v_label text;
  v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_dest private.stock_positions%rowtype;
  v_doc private.stock_documents%rowtype; v_item private.stock_document_items%rowtype;
begin
  v_actor := private.require_role(array['OWNER']);
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'position_id', 'expected_version', 'qty_base',
    'destination_location', 'destination_condition', 'destination_label', 'reason', 'note']);
  v_old := private.operation_result('transfer_stock_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);
  v_reason := private.ops_text(p_input->'reason', 'Alasan', 500, true);
  v_note := private.ops_text(p_input->'note', 'Catatan', 500);
  v_label := private.ops_text(p_input->'destination_label', 'Label tujuan', 40);
  v_location := p_input->>'destination_location';
  if v_location is null or v_location not in ('SHOP', 'FIELD_FATHER') then
    raise exception 'INVALID_INPUT: Lokasi tujuan harus SHOP atau FIELD_FATHER' using errcode = '22023';
  end if;

  v_source := private.ops_lock_position(private.ops_uuid(p_input->'position_id', 'position_id'),
    private.ops_int(p_input->'expected_version', 'expected_version'));
  select * into v_lot from private.inventory_lots where id = v_source.lot_id;
  select * into v_product from private.products where id = v_lot.product_id;

  v_condition := coalesce(p_input->>'destination_condition', v_source.condition);
  if v_condition not in ('SALEABLE', 'DAMAGED') then
    raise exception 'INVALID_INPUT: Kondisi tujuan harus SALEABLE atau DAMAGED' using errcode = '22023';
  end if;
  if v_location = v_source.location and v_condition = v_source.condition then
    raise exception 'INVALID_INPUT: Tujuan transfer sama dengan posisi asal' using errcode = '22023';
  end if;
  if mod(v_qty, v_product.quantity_step) <> 0 then
    raise exception 'INVALID_NUMBER: Kuantitas tidak sesuai langkah stok produk' using errcode = '22023';
  end if;
  if v_qty > v_source.qty_base then
    raise exception 'INSUFFICIENT_STOCK: Stok pada posisi asal tidak cukup' using errcode = '22023';
  end if;
  if v_product.track_segments then
    if v_label is null then
      raise exception 'INVALID_INPUT: Posisi roll tujuan memerlukan label baru' using errcode = '22023';
    end if;
    if exists (select 1 from private.stock_positions where label = v_label) then
      raise exception 'INVALID_INPUT: Label posisi sudah dipakai' using errcode = '22023';
    end if;
  elsif v_label is not null then
    raise exception 'INVALID_INPUT: Label hanya untuk produk roll/potongan' using errcode = '22023';
  end if;

  insert into private.stock_documents(number, kind, actor_id, reason, operation_id)
    values (private.next_stock_number('TRANSFER'), 'TRANSFER', v_actor, v_reason, v_op)
    returning * into v_doc;
  insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
    factor_snapshot, qty_base, source_location, destination_location, condition, note)
    values (v_doc.id, 1, v_product.id, v_product.base_unit, v_qty, 1, v_qty, v_source.location,
      v_location, v_condition, v_note)
    returning * into v_item;
  update private.stock_positions set qty_base = qty_base - v_qty, sealed = false, version = version + 1
    where id = v_source.id;
  insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
    values (v_lot.id, v_location, v_condition, v_qty, v_label,
      case when v_product.track_segments then
        case when v_qty = v_source.qty_base then coalesce(v_source.segment_capacity, v_qty) else v_qty end
      end,
      v_product.track_segments and v_source.sealed and v_qty = v_source.qty_base)
    returning * into v_dest;
  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
    stock_document_item_id, actor_id, operation_id)
    values (v_doc.id, v_lot.id, v_source.id, -v_qty, 0, 'TRANSFER_OUT', v_item.id, v_actor, v_op),
           (v_doc.id, v_lot.id, v_dest.id, v_qty, 0, 'TRANSFER_IN', v_item.id, v_actor, v_op);
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
    values (v_actor, 'TRANSFER_STOCK', 'STOCK_DOCUMENT', v_doc.id, v_reason);

  v_result := jsonb_build_object('ok', true, 'operation_id', v_op, 'entity_id', v_doc.id,
    'document_number', v_doc.number, 'server_time', now(), 'schema_version', 1,
    'source_position_id', v_source.id, 'source_version', v_source.version + 1,
    'source_qty_base', (v_source.qty_base - v_qty)::text,
    'destination_position_id', v_dest.id, 'destination_version', v_dest.version,
    'qty_base', v_qty::numeric(18,3)::text);
  return private.finish_operation('transfer_stock_v1', p_input, v_result);
end $$;
revoke all on function public.transfer_stock_v1(jsonb) from public, anon, authenticated;
grant execute on function public.transfer_stock_v1(jsonb) to authenticated;

-- disposal (post_stock_exit) --------------------------------------------------

create or replace function private.post_stock_exit(p_input jsonb, p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_result jsonb; v_command text;
  v_qty numeric; v_cost numeric; v_reason text;
  v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype;
  v_item private.stock_document_items%rowtype;
begin
  v_actor := private.require_role(array['OWNER']);
  -- Nama command wajib sama dengan RPC publik agar get_operation_v1 dapat menemukannya.
  v_command := case p_kind when 'DISPOSAL' then 'dispose_stock_v1' end;
  if v_command is null then
    raise exception 'INVALID_INPUT: Jenis pengeluaran stok tidak dikenal' using errcode = '22023';
  end if;
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'position_id', 'expected_version', 'qty_base', 'reason', 'note']);
  v_old := private.operation_result(v_command, p_input);
  if v_old is not null then return v_old; end if;

  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);
  v_reason := private.ops_text(p_input->'reason', 'Alasan', 500, true);
  v_source := private.ops_lock_position(private.ops_uuid(p_input->'position_id', 'position_id'),
    private.ops_int(p_input->'expected_version', 'expected_version'));
  select * into v_lot from private.inventory_lots where id = v_source.lot_id;
  select * into v_product from private.products where id = v_lot.product_id;

  if mod(v_qty, v_product.quantity_step) <> 0 then
    raise exception 'INVALID_NUMBER: Kuantitas tidak sesuai langkah stok produk' using errcode = '22023';
  end if;
  if v_qty > v_source.qty_base then
    raise exception 'INSUFFICIENT_STOCK: Stok pada posisi tidak cukup' using errcode = '22023';
  end if;
  v_cost := private.cost_for_exit(v_lot, v_qty)::numeric(24,6);

  insert into private.stock_documents(number, kind, actor_id, reason, operation_id)
    values (private.next_stock_number(p_kind), p_kind, v_actor, v_reason, v_op)
    returning * into v_doc;
  insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
    factor_snapshot, qty_base, acquisition_cost, source_location, condition, note)
    values (v_doc.id, 1, v_product.id, v_product.base_unit, v_qty, 1, v_qty, v_cost,
      v_source.location, v_source.condition, private.ops_text(p_input->'note', 'Catatan', 500))
    returning * into v_item;
  update private.stock_positions set qty_base = qty_base - v_qty, sealed = false, version = version + 1
    where id = v_source.id;
  update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
    remaining_cost = remaining_cost - v_cost, version = version + 1 where id = v_lot.id;
  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
    stock_document_item_id, actor_id, operation_id)
    values (v_doc.id, v_lot.id, v_source.id, -v_qty, -v_cost, 'DISPOSAL', v_item.id, v_actor, v_op);
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
    values (v_actor, 'POST_' || p_kind, 'STOCK_DOCUMENT', v_doc.id, v_reason);

  v_result := jsonb_build_object('ok', true, 'operation_id', v_op, 'entity_id', v_doc.id,
    'document_number', v_doc.number, 'server_time', now(), 'schema_version', 1,
    'position_id', v_source.id, 'version', v_source.version + 1,
    'qty_base', v_qty::numeric(18,3)::text, 'remaining_qty_base', (v_source.qty_base - v_qty)::text,
    'cost_removed', v_cost::numeric(24,6)::text);
  return private.finish_operation(v_command, p_input, v_result);
end $$;
revoke all on function private.post_stock_exit(jsonb, text) from public, anon, authenticated;

create or replace function public.dispose_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return private.post_stock_exit(p_input, 'DISPOSAL');
end $$;
revoke all on function public.dispose_stock_v1(jsonb) from public, anon, authenticated;
grant execute on function public.dispose_stock_v1(jsonb) to authenticated;

-- adjust_stock_v1 -------------------------------------------------------------
-- direction OUT: kurangi posisi tertentu, modal keluar mengikuti lot posisi (BR-06).
-- direction IN : lot koreksi baru dengan modal terkonfirmasi atau alasan modal nol.

create or replace function public.adjust_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_result jsonb; v_direction text;
  v_qty numeric; v_cost numeric; v_reason text; v_note text; v_location text; v_condition text;
  v_label text; v_capacity numeric;
  v_source private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype;
  v_item private.stock_document_items%rowtype; v_dest private.stock_positions%rowtype;
begin
  v_actor := private.require_role(array['OWNER']);
  v_op := private.ops_operation_id(p_input);
  v_direction := p_input->>'direction';
  if v_direction is null or v_direction not in ('IN', 'OUT') then
    raise exception 'INVALID_INPUT: direction harus IN (tambah) atau OUT (kurangi)' using errcode = '22023';
  end if;
  if v_direction = 'OUT' then
    perform private.ops_allowed_keys(p_input, array['operation_id', 'direction', 'position_id', 'expected_version',
      'qty_base', 'reason', 'note']);
  else
    perform private.ops_allowed_keys(p_input, array['operation_id', 'direction', 'product_id', 'location', 'condition',
      'qty_base', 'acquisition_cost', 'cost_confirmed', 'zero_cost_reason', 'label', 'segment_capacity', 'reason', 'note']);
  end if;
  v_old := private.operation_result('adjust_stock_v1', p_input);
  if v_old is not null then return v_old; end if;

  -- qty selalu positif; arah ditentukan direction (bug lama: '-2' ditolak format).
  v_qty := private.decimal_input(p_input->'qty_base', 3, 999999999.999);
  v_reason := private.ops_text(p_input->'reason', 'Alasan', 500, true);
  v_note := private.ops_text(p_input->'note', 'Catatan', 500);

  if v_direction = 'OUT' then
    v_source := private.ops_lock_position(private.ops_uuid(p_input->'position_id', 'position_id'),
      private.ops_int(p_input->'expected_version', 'expected_version'));
    select * into v_lot from private.inventory_lots where id = v_source.lot_id;
    select * into v_product from private.products where id = v_lot.product_id;
    if mod(v_qty, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_NUMBER: Kuantitas tidak sesuai langkah stok produk' using errcode = '22023';
    end if;
    if v_qty > v_source.qty_base then
      raise exception 'INSUFFICIENT_STOCK: Stok pada posisi tidak cukup' using errcode = '22023';
    end if;
    v_cost := private.cost_for_exit(v_lot, v_qty)::numeric(24,6);

    insert into private.stock_documents(number, kind, actor_id, reason, operation_id)
      values (private.next_stock_number('ADJUSTMENT'), 'ADJUSTMENT', v_actor, v_reason, v_op)
      returning * into v_doc;
    insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
      factor_snapshot, qty_base, acquisition_cost, source_location, condition, note)
      values (v_doc.id, 1, v_product.id, v_product.base_unit, v_qty, 1, v_qty, v_cost,
        v_source.location, v_source.condition, coalesce(v_note, 'Penyesuaian kurang'))
      returning * into v_item;
    update private.stock_positions set qty_base = qty_base - v_qty, sealed = false, version = version + 1
      where id = v_source.id returning * into v_dest;
    update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
      remaining_cost = remaining_cost - v_cost, version = version + 1 where id = v_lot.id;
    insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
      stock_document_item_id, actor_id, operation_id)
      values (v_doc.id, v_lot.id, v_source.id, -v_qty, -v_cost, 'ADJUST_OUT', v_item.id, v_actor, v_op);
    v_cost := -v_cost;
  else
    select * into v_product from private.products
      where id = private.ops_uuid(p_input->'product_id', 'product_id') for update;
    if not found or not v_product.active then
      raise exception 'NOT_FOUND: Produk tidak ditemukan atau sudah diarsip' using errcode = '22023';
    end if;
    v_location := coalesce(p_input->>'location', 'SHOP');
    v_condition := coalesce(p_input->>'condition', 'SALEABLE');
    if v_location not in ('SHOP', 'FIELD_FATHER') or v_condition not in ('SALEABLE', 'DAMAGED') then
      raise exception 'INVALID_INPUT: Lokasi/kondisi tidak sah' using errcode = '22023';
    end if;
    if mod(v_qty, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_NUMBER: Kuantitas tidak sesuai langkah stok produk' using errcode = '22023';
    end if;
    v_cost := private.ops_correction_cost(p_input->'acquisition_cost', p_input->'cost_confirmed', p_input->'zero_cost_reason');
    v_label := private.ops_text(p_input->'label', 'Label', 40);
    if v_product.track_segments then
      if v_label is null then
        raise exception 'INVALID_INPUT: Potongan/roll koreksi memerlukan label posisi baru' using errcode = '22023';
      end if;
      if exists (select 1 from private.stock_positions where label = v_label) then
        raise exception 'INVALID_INPUT: Label posisi sudah dipakai' using errcode = '22023';
      end if;
      v_capacity := coalesce(private.decimal_input_opt(p_input->'segment_capacity', 3, 999999999.999), v_qty);
      if v_capacity < v_qty then
        raise exception 'INVALID_INPUT: Kapasitas roll lebih kecil dari panjang' using errcode = '22023';
      end if;
    elsif v_label is not null or p_input ? 'segment_capacity' then
      raise exception 'INVALID_INPUT: Label/kapasitas hanya untuk produk roll/potongan' using errcode = '22023';
    end if;

    insert into private.stock_documents(number, kind, actor_id, reason, operation_id)
      values (private.next_stock_number('ADJUSTMENT'), 'ADJUSTMENT', v_actor, v_reason, v_op)
      returning * into v_doc;
    insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
      factor_snapshot, qty_base, acquisition_cost, destination_location, condition, note)
      values (v_doc.id, 1, v_product.id, v_product.base_unit, v_qty, 1, v_qty, v_cost,
        v_location, v_condition, coalesce(v_note, private.ops_text(p_input->'zero_cost_reason', 'Alasan modal nol', 500),
          'Penyesuaian tambah'))
      returning * into v_item;
    insert into private.inventory_lots(product_id, origin_item_id, original_qty, original_cost, remaining_qty, remaining_cost)
      values (v_product.id, v_item.id, v_qty, v_cost, v_qty, v_cost)
      returning * into v_lot;
    insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
      values (v_lot.id, v_location, v_condition, v_qty, v_label, v_capacity, false)
      returning * into v_dest;
    insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
      stock_document_item_id, actor_id, operation_id)
      values (v_doc.id, v_lot.id, v_dest.id, v_qty, v_cost, 'ADJUST_IN', v_item.id, v_actor, v_op);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
    values (v_actor, 'ADJUST_STOCK_' || v_direction, 'STOCK_DOCUMENT', v_doc.id, v_reason);

  v_result := jsonb_build_object('ok', true, 'operation_id', v_op, 'entity_id', v_doc.id,
    'document_number', v_doc.number, 'server_time', now(), 'schema_version', 1,
    'direction', v_direction, 'position_id', v_dest.id, 'version', v_dest.version,
    'qty_base', v_qty::numeric(18,3)::text, 'position_qty_base', v_dest.qty_base::text, 'cost_delta', v_cost::numeric(24,6)::text);
  return private.finish_operation('adjust_stock_v1', p_input, v_result);
end $$;
revoke all on function public.adjust_stock_v1(jsonb) from public, anon, authenticated;
grant execute on function public.adjust_stock_v1(jsonb) to authenticated;

-- Opname (FR-INV-03) ------------------------------------------------------------

alter table private.stock_counts add column if not exists note text;
alter table private.stock_counts add column if not exists posted_at timestamptz;
alter table private.stock_counts add column if not exists version integer not null default 1;
alter table private.stock_count_items alter column counted_qty drop not null;
alter table private.stock_count_items add column if not exists line_no integer;
alter table private.stock_count_items add column if not exists difference numeric(18,3);
alter table private.stock_count_items add column if not exists cost_delta numeric(24,6);
alter table private.stock_count_items add column if not exists document_item_id uuid
  references private.stock_document_items(id);
create index if not exists stock_counts_status on private.stock_counts(status, created_at desc);

-- Mulai hitungan: simpan versi dan qty sistem setiap posisi terpilih.
create or replace function public.create_stock_count_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_result jsonb; v_count private.stock_counts%rowtype;
  v_location text; v_n integer; v_ids uuid[];
begin
  v_actor := private.require_role(array['OWNER']);
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'position_ids', 'product_ids', 'location', 'note']);
  v_old := private.operation_result('create_stock_count_v1', p_input);
  if v_old is not null then return v_old; end if;

  if (p_input ? 'position_ids') = (p_input ? 'product_ids') then
    raise exception 'INVALID_INPUT: Pilih daftar posisi atau daftar produk (salah satu)' using errcode = '22023';
  end if;
  v_location := p_input->>'location';
  if v_location is not null and v_location not in ('SHOP', 'FIELD_FATHER') then
    raise exception 'INVALID_INPUT: Lokasi tidak sah' using errcode = '22023';
  end if;

  if p_input ? 'position_ids' then
    if jsonb_typeof(p_input->'position_ids') <> 'array' or jsonb_array_length(p_input->'position_ids') not between 1 and 200 then
      raise exception 'INVALID_INPUT: Daftar posisi wajib 1-200' using errcode = '22023';
    end if;
    select array_agg(distinct private.ops_uuid(x, 'position_id')) into v_ids
      from jsonb_array_elements(p_input->'position_ids') x;
    if array_length(v_ids, 1) <> jsonb_array_length(p_input->'position_ids') then
      raise exception 'INVALID_INPUT: Posisi ganda dalam daftar' using errcode = '22023';
    end if;
    if (select count(*) from private.stock_positions where id = any (v_ids)
          and (v_location is null or location = v_location)) <> array_length(v_ids, 1) then
      raise exception 'NOT_FOUND: Sebagian posisi tidak ditemukan' using errcode = '22023';
    end if;
  else
    if jsonb_typeof(p_input->'product_ids') <> 'array' or jsonb_array_length(p_input->'product_ids') not between 1 and 100 then
      raise exception 'INVALID_INPUT: Daftar produk wajib 1-100' using errcode = '22023';
    end if;
    select array_agg(s.id) into v_ids
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id in (select private.ops_uuid(x, 'product_id') from jsonb_array_elements(p_input->'product_ids') x)
        and s.qty_base > 0 and (v_location is null or s.location = v_location);
    if v_ids is null then
      raise exception 'NOT_FOUND: Tidak ada posisi berstok untuk produk terpilih' using errcode = '22023';
    end if;
  end if;
  if array_length(v_ids, 1) > 200 then
    raise exception 'INVALID_INPUT: Maksimal 200 posisi per hitungan; bagi menjadi beberapa hitungan' using errcode = '22023';
  end if;

  insert into private.stock_counts(owner_id, note)
    values (v_actor, private.ops_text(p_input->'note', 'Catatan', 500))
    returning * into v_count;
  insert into private.stock_count_items(count_id, position_id, expected_version, system_qty, line_no)
    select v_count.id, s.id, s.version, s.qty_base,
      row_number() over (order by p.name, p.id, s.location, s.condition, s.label nulls last, s.id)
    from private.stock_positions s
    join private.inventory_lots l on l.id = s.lot_id
    join private.products p on p.id = l.product_id
    where s.id = any (v_ids);
  get diagnostics v_n = row_count;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
    values (v_actor, 'CREATE_STOCK_COUNT', 'STOCK_COUNT', v_count.id, v_count.note);

  v_result := jsonb_build_object('ok', true, 'operation_id', v_op, 'entity_id', v_count.id,
    'server_time', now(), 'schema_version', 1, 'status', 'DRAFT', 'version', v_count.version,
    'item_count', v_n);
  return private.finish_operation('create_stock_count_v1', p_input, v_result);
end $$;
revoke all on function public.create_stock_count_v1(jsonb) from public, anon, authenticated;
grant execute on function public.create_stock_count_v1(jsonb) to authenticated;

create or replace function public.get_stock_count_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role text; v_count private.stock_counts%rowtype; v_items jsonb;
begin
  perform private.require_role(array['OWNER', 'MAINTAINER']);
  perform private.ops_allowed_keys(p_input, array['count_id']);
  select * into v_count from private.stock_counts where id = private.ops_uuid(p_input->'count_id', 'count_id');
  if not found then
    raise exception 'NOT_FOUND: Hitungan stok tidak ditemukan' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'line_no', ci.line_no, 'position_id', ci.position_id, 'product_id', p.id, 'sku', p.sku, 'name', p.name,
      'base_unit', p.base_unit, 'quantity_step', p.quantity_step::text, 'track_segments', p.track_segments,
      'label', s.label, 'location', s.location, 'condition', s.condition,
      'system_qty', ci.system_qty::text, 'expected_version', ci.expected_version,
      'current_qty', s.qty_base::text, 'current_version', s.version,
      'changed_since_start', s.version <> ci.expected_version,
      'counted_qty', ci.counted_qty::text, 'difference', ci.difference::text,
      'cost_delta', ci.cost_delta::text, 'reason', ci.reason)
      order by ci.line_no), '[]'::jsonb) into v_items
    from private.stock_count_items ci
    join private.stock_positions s on s.id = ci.position_id
    join private.inventory_lots l on l.id = s.lot_id
    join private.products p on p.id = l.product_id
    where ci.count_id = v_count.id;
  return jsonb_build_object('id', v_count.id, 'status', v_count.status, 'version', v_count.version,
    'note', v_count.note, 'created_at', v_count.created_at, 'posted_at', v_count.posted_at,
    'document_number', (select number from private.stock_documents where id = v_count.posted_document_id),
    'items', v_items, 'server_time', now());
end $$;
revoke all on function public.get_stock_count_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_stock_count_v1(jsonb) to authenticated;

create or replace function public.list_stock_counts_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_limit integer; v_offset integer; v_status text; v_rows jsonb; v_total integer;
begin
  perform private.require_role(array['OWNER', 'MAINTAINER']);
  perform private.ops_allowed_keys(coalesce(p_input, '{}'::jsonb), array['status', 'limit', 'offset']);
  v_limit := coalesce(private.ops_int(p_input->'limit', 'limit', false), 25);
  v_offset := coalesce(private.ops_int(p_input->'offset', 'offset', false), 0);
  v_status := p_input->>'status';
  if v_limit not between 1 and 100 or (v_status is not null and v_status not in ('DRAFT', 'POSTED')) then
    raise exception 'INVALID_INPUT: Filter hitungan tidak sah' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(r.row_data order by r.created_at desc, r.id desc), '[]'::jsonb), count(*)
    into v_rows, v_total
  from (
    select c.id, c.created_at, jsonb_build_object('id', c.id, 'status', c.status, 'version', c.version,
      'note', c.note, 'created_at', c.created_at, 'posted_at', c.posted_at,
      'item_count', (select count(*) from private.stock_count_items i where i.count_id = c.id),
      'document_number', (select number from private.stock_documents d where d.id = c.posted_document_id)) row_data
    from private.stock_counts c
    where v_status is null or c.status = v_status
    order by c.created_at desc, c.id desc
    limit v_limit + 1 offset v_offset
  ) r;
  return jsonb_build_object('rows', (select coalesce(jsonb_agg(e order by n), '[]'::jsonb)
      from jsonb_array_elements(v_rows) with ordinality t(e, n) where n <= v_limit),
    'has_more', v_total > v_limit, 'next_offset', case when v_total > v_limit then v_offset + v_limit end);
end $$;
revoke all on function public.list_stock_counts_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_stock_counts_v1(jsonb) to authenticated;

-- Posting hitungan: seluruh posisi atomik; versi berubah sejak mulai -> VERSION_CONFLICT.
create or replace function public.post_stock_count_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_result jsonb; v_reason text;
  v_count private.stock_counts%rowtype; v_ci private.stock_count_items%rowtype;
  v_entry jsonb; v_pos private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype;
  v_product private.products%rowtype; v_doc private.stock_documents%rowtype;
  v_item private.stock_document_items%rowtype; v_new_lot private.inventory_lots%rowtype;
  v_new_pos private.stock_positions%rowtype;
  v_counted numeric; v_diff numeric; v_cost numeric; v_label text; v_line integer := 0;
  v_expected_n integer; v_given_n integer; v_total_cost numeric := 0; v_adjusted integer := 0;
begin
  v_actor := private.require_role(array['OWNER']);
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'count_id', 'items', 'reason']);
  v_old := private.operation_result('post_stock_count_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_count from private.stock_counts
    where id = private.ops_uuid(p_input->'count_id', 'count_id') for update;
  if not found then
    raise exception 'NOT_FOUND: Hitungan stok tidak ditemukan' using errcode = '22023';
  end if;
  if v_count.status <> 'DRAFT' then
    raise exception 'ALREADY_FINALIZED: Hitungan stok sudah diposting' using errcode = '22023';
  end if;
  v_reason := coalesce(private.ops_text(p_input->'reason', 'Alasan', 500), 'Stok opname');

  if jsonb_typeof(p_input->'items') is distinct from 'array' then
    raise exception 'INVALID_INPUT: Daftar hasil hitung wajib' using errcode = '22023';
  end if;
  for v_entry in select value from jsonb_array_elements(p_input->'items') loop
    perform private.ops_allowed_keys(v_entry, array['position_id', 'counted_qty', 'reason',
      'acquisition_cost', 'cost_confirmed', 'zero_cost_reason', 'new_label']);
    perform private.ops_uuid(v_entry->'position_id', 'position_id');
    -- counted_qty desimal non-negatif (bug lama: '-5' tidak divalidasi).
    perform private.decimal_input(v_entry->'counted_qty', 3, 999999999.999, false);
  end loop;
  select count(*) into v_expected_n from private.stock_count_items where count_id = v_count.id;
  select count(distinct x->>'position_id') into v_given_n from jsonb_array_elements(p_input->'items') x;
  if v_given_n <> jsonb_array_length(p_input->'items') or v_given_n <> v_expected_n
     or exists (select 1 from jsonb_array_elements(p_input->'items') x
                where not exists (select 1 from private.stock_count_items ci
                                  where ci.count_id = v_count.id and ci.position_id = (x->>'position_id')::uuid)) then
    raise exception 'INVALID_INPUT: Hasil hitung harus mencakup setiap posisi hitungan tepat satu kali' using errcode = '22023';
  end if;

  -- Lock seluruh sumber daya sesuai urutan global sebelum menulis.
  perform 1 from private.products where id in (
    select l.product_id from private.stock_count_items ci
    join private.stock_positions s on s.id = ci.position_id join private.inventory_lots l on l.id = s.lot_id
    where ci.count_id = v_count.id) order by id for update;
  perform 1 from private.inventory_lots where id in (
    select s.lot_id from private.stock_count_items ci join private.stock_positions s on s.id = ci.position_id
    where ci.count_id = v_count.id) order by id for update;
  perform 1 from private.stock_positions where id in (
    select position_id from private.stock_count_items where count_id = v_count.id) order by id for update;
  if exists (select 1 from private.stock_count_items ci join private.stock_positions s on s.id = ci.position_id
             where ci.count_id = v_count.id and s.version <> ci.expected_version) then
    raise exception 'VERSION_CONFLICT: Stok sebagian posisi berubah sejak hitungan dimulai. Buat hitungan baru.'
      using errcode = '40001';
  end if;

  for v_ci in select * from private.stock_count_items where count_id = v_count.id order by position_id loop
    select value into v_entry from jsonb_array_elements(p_input->'items')
      where (value->>'position_id')::uuid = v_ci.position_id;
    select * into v_pos from private.stock_positions where id = v_ci.position_id;
    select * into v_lot from private.inventory_lots where id = v_pos.lot_id;
    select * into v_product from private.products where id = v_lot.product_id;
    v_counted := private.decimal_input(v_entry->'counted_qty', 3, 999999999.999, false);
    if mod(v_counted, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_NUMBER: Hasil hitung tidak sesuai langkah stok produk' using errcode = '22023';
    end if;
    v_diff := v_counted - v_pos.qty_base;
    v_cost := 0;

    if v_diff <> 0 and v_doc.id is null then
      insert into private.stock_documents(number, kind, actor_id, reason, operation_id)
        values (private.next_stock_number('COUNT'), 'COUNT', v_actor, v_reason, v_op)
        returning * into v_doc;
    end if;

    if v_diff < 0 then
      v_cost := private.cost_for_exit(v_lot, -v_diff)::numeric(24,6);
      v_line := v_line + 1;
      insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
        factor_snapshot, qty_base, acquisition_cost, source_location, condition, note)
        values (v_doc.id, v_line, v_product.id, v_product.base_unit, -v_diff, 1, -v_diff, v_cost,
          v_pos.location, v_pos.condition, private.ops_text(v_entry->'reason', 'Alasan', 500))
        returning * into v_item;
      update private.stock_positions set qty_base = qty_base + v_diff, sealed = false, version = version + 1
        where id = v_pos.id;
      update private.inventory_lots set remaining_qty = remaining_qty + v_diff,
        remaining_cost = remaining_cost - v_cost, version = version + 1 where id = v_lot.id;
      insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
        stock_document_item_id, actor_id, operation_id)
        values (v_doc.id, v_lot.id, v_pos.id, v_diff, -v_cost, 'COUNT_OUT', v_item.id, v_actor, v_op);
      v_cost := -v_cost;
    elsif v_diff > 0 then
      v_cost := private.ops_correction_cost(v_entry->'acquisition_cost', v_entry->'cost_confirmed', v_entry->'zero_cost_reason');
      v_label := private.ops_text(v_entry->'new_label', 'Label baru', 40);
      if v_product.track_segments then
        if v_label is null then
          raise exception 'INVALID_INPUT: Kelebihan pada roll dicatat sebagai potongan baru berlabel (new_label)' using errcode = '22023';
        end if;
        if exists (select 1 from private.stock_positions where label = v_label) then
          raise exception 'INVALID_INPUT: Label posisi sudah dipakai' using errcode = '22023';
        end if;
      elsif v_label is not null then
        raise exception 'INVALID_INPUT: Label hanya untuk produk roll/potongan' using errcode = '22023';
      end if;
      v_line := v_line + 1;
      insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
        factor_snapshot, qty_base, acquisition_cost, destination_location, condition, note)
        values (v_doc.id, v_line, v_product.id, v_product.base_unit, v_diff, 1, v_diff, v_cost,
          v_pos.location, v_pos.condition,
          coalesce(private.ops_text(v_entry->'reason', 'Alasan', 500), private.ops_text(v_entry->'zero_cost_reason', 'Alasan modal nol', 500)))
        returning * into v_item;
      insert into private.inventory_lots(product_id, origin_item_id, original_qty, original_cost, remaining_qty, remaining_cost)
        values (v_product.id, v_item.id, v_diff, v_cost, v_diff, v_cost) returning * into v_new_lot;
      insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
        values (v_new_lot.id, v_pos.location, v_pos.condition, v_diff, v_label,
          case when v_product.track_segments then v_diff end, false)
        returning * into v_new_pos;
      insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
        stock_document_item_id, actor_id, operation_id)
        values (v_doc.id, v_new_lot.id, v_new_pos.id, v_diff, v_cost, 'COUNT_IN', v_item.id, v_actor, v_op);
    end if;

    if v_diff <> 0 then
      v_adjusted := v_adjusted + 1;
      v_total_cost := v_total_cost + v_cost;
    end if;
    update private.stock_count_items set counted_qty = v_counted, difference = v_diff,
      cost_delta = case when v_diff <> 0 then v_cost end,
      document_item_id = case when v_diff <> 0 then v_item.id end,
      reason = private.ops_text(v_entry->'reason', 'Alasan', 500)
      where count_id = v_count.id and position_id = v_ci.position_id;
  end loop;

  update private.stock_counts set status = 'POSTED', posted_at = now(), posted_document_id = v_doc.id,
    version = version + 1 where id = v_count.id returning * into v_count;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
    values (v_actor, 'POST_STOCK_COUNT', 'STOCK_COUNT', v_count.id, v_reason);

  v_result := jsonb_build_object('ok', true, 'operation_id', v_op, 'entity_id', v_count.id,
    'document_number', v_doc.number, 'server_time', now(), 'schema_version', 1,
    'status', v_count.status, 'version', v_count.version,
    'adjusted_lines', v_adjusted, 'cost_delta', v_total_cost::numeric(24,6)::text);
  return private.finish_operation('post_stock_count_v1', p_input, v_result);
end $$;
revoke all on function public.post_stock_count_v1(jsonb) from public, anon, authenticated;
grant execute on function public.post_stock_count_v1(jsonb) to authenticated;

-- Baca posisi stok ----------------------------------------------------------------

create or replace function public.list_stock_positions_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_input jsonb := coalesce(p_input, '{}'::jsonb);
  v_product uuid; v_location text; v_condition text; v_include_empty boolean; v_query text;
  v_limit integer; v_offset integer; v_rows jsonb; v_n integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(v_input, array['product_id', 'location', 'condition', 'include_empty', 'query', 'limit', 'offset']);
  v_product := private.ops_uuid(v_input->'product_id', 'product_id', false);
  v_location := v_input->>'location';
  v_condition := v_input->>'condition';
  v_include_empty := private.ops_bool(v_input->'include_empty');
  v_query := lower(private.ops_text(v_input->'query', 'Pencarian', 120));
  v_limit := coalesce(private.ops_int(v_input->'limit', 'limit', false), 25);
  v_offset := coalesce(private.ops_int(v_input->'offset', 'offset', false), 0);
  if v_limit not between 1 and 100 or (v_location is not null and v_location not in ('SHOP', 'FIELD_FATHER'))
     or (v_condition is not null and v_condition not in ('SALEABLE', 'DAMAGED')) then
    raise exception 'INVALID_INPUT: Filter posisi stok tidak sah' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(x.row_data order by x.rn), '[]'::jsonb), count(*) into v_rows, v_n from (
    select row_number() over (order by p.name, p.id, l.posted_at, l.id, s.id) rn,
      jsonb_build_object('position_id', s.id, 'version', s.version, 'product_id', p.id, 'sku', p.sku,
        'name', p.name, 'base_unit', p.base_unit, 'quantity_step', p.quantity_step::text,
        'track_segments', p.track_segments, 'location', s.location, 'condition', s.condition,
        'qty_base', s.qty_base::text, 'label', s.label, 'segment_capacity', s.segment_capacity::text,
        'sealed', s.sealed, 'lot_id', l.id, 'lot_posted_at', l.posted_at)
      || case when v_role in ('OWNER', 'MAINTAINER') then jsonb_build_object(
          'lot_remaining_qty', l.remaining_qty::text, 'lot_remaining_cost', l.remaining_cost::text)
         else '{}'::jsonb end row_data
    from private.stock_positions s
    join private.inventory_lots l on l.id = s.lot_id
    join private.products p on p.id = l.product_id
    where (v_product is null or p.id = v_product)
      and (v_location is null or s.location = v_location)
      and (v_condition is null or s.condition = v_condition)
      and (v_include_empty or s.qty_base > 0)
      and (v_query is null or lower(p.name) like v_query || '%' or lower(p.sku) = v_query or lower(s.label) = v_query)
    order by p.name, p.id, l.posted_at, l.id, s.id
    limit v_limit + 1 offset v_offset
  ) x;

  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(e order by n), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality t(e, n) where n <= v_limit),
    'has_more', v_n > v_limit, 'next_offset', case when v_n > v_limit then v_offset + v_limit end,
    'server_time', now());
end $$;
revoke all on function public.list_stock_positions_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_stock_positions_v1(jsonb) to authenticated;

-- Riwayat mutasi stok ---------------------------------------------------------------

create or replace function public.list_stock_movements_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_input jsonb := coalesce(p_input, '{}'::jsonb);
  v_product uuid; v_position uuid; v_kind text; v_start timestamptz; v_end timestamptz;
  v_limit integer; v_offset integer; v_rows jsonb; v_n integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(v_input, array['product_id', 'position_id', 'kind', 'start_date', 'end_date', 'limit', 'offset']);
  v_product := private.ops_uuid(v_input->'product_id', 'product_id', false);
  v_position := private.ops_uuid(v_input->'position_id', 'position_id', false);
  v_kind := private.ops_text(v_input->'kind', 'Jenis', 40);
  v_limit := coalesce(private.ops_int(v_input->'limit', 'limit', false), 25);
  v_offset := coalesce(private.ops_int(v_input->'offset', 'offset', false), 0);
  if v_limit not between 1 and 100 then
    raise exception 'INVALID_INPUT: limit 1-100' using errcode = '22023';
  end if;
  if v_input ? 'start_date' or v_input ? 'end_date' then
    select r.start_at, r.end_at into v_start, v_end from private.date_range_input(v_input, 366) r;
  elsif v_product is null and v_position is null then
    raise exception 'INVALID_INPUT: Pilih produk, posisi, atau rentang tanggal' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(x.row_data order by x.rn), '[]'::jsonb), count(*) into v_rows, v_n from (
    select row_number() over (order by m.occurred_at desc, m.id desc) rn,
      jsonb_build_object('id', m.id, 'occurred_at', m.occurred_at, 'kind', m.kind,
        'qty_delta', m.qty_delta::text, 'product_id', p.id, 'sku', p.sku, 'name', p.name,
        'base_unit', p.base_unit, 'position_id', s.id, 'label', s.label, 'location', s.location,
        'condition', s.condition, 'document_number', d.number, 'document_kind', d.kind, 'reason', d.reason,
        'invoice_number', inv.number, 'service_ticket_number', t.number, 'actor_name', ap.display_name)
      || case when v_role in ('OWNER', 'MAINTAINER') then jsonb_build_object('cost_delta', m.cost_delta::text)
         else '{}'::jsonb end row_data
    from private.stock_movements m
    join private.stock_positions s on s.id = m.position_id
    join private.inventory_lots l on l.id = m.lot_id
    join private.products p on p.id = l.product_id
    left join private.stock_document_items di on di.id = m.stock_document_item_id
    left join private.stock_documents d on d.id = di.document_id
    left join private.invoice_items ii on ii.id = m.invoice_item_id
    left join private.invoices inv on inv.id = ii.invoice_id
    left join private.service_part_events pe on pe.id = m.service_part_event_id
    left join private.service_tickets t on t.id = pe.ticket_id
    left join private.app_profiles ap on ap.id = m.actor_id
    where (v_product is null or p.id = v_product)
      and (v_position is null or m.position_id = v_position)
      and (v_kind is null or m.kind = v_kind)
      and (v_start is null or (m.occurred_at >= v_start and m.occurred_at < v_end))
    order by m.occurred_at desc, m.id desc
    limit v_limit + 1 offset v_offset
  ) x;

  return jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(e order by n), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality t(e, n) where n <= v_limit),
    'has_more', v_n > v_limit, 'next_offset', case when v_n > v_limit then v_offset + v_limit end,
    'server_time', now());
end $$;
revoke all on function public.list_stock_movements_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_stock_movements_v1(jsonb) to authenticated;
