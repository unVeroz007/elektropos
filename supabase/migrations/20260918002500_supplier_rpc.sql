-- Perbaikan audit 2026-09 D5: daftar distributor dan retur barang ke distributor.
-- Barang keluar stok menjadi klaim senilai modal (BR-05); penyelesaian:
-- REFUND (uang kembali), CREDIT (saldo kredit), REPLACEMENT (lot baru bernilai klaim),
-- REJECTED (klaim menjadi kerugian). settlement_difference = nilai diterima - klaim.

-- === upsert_supplier_v1 ===================================================
create or replace function public.upsert_supplier_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_id uuid; v_name text; v_supplier private.suppliers%rowtype;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input,
    array['operation_id', 'supplier_id', 'expected_version', 'name', 'contact', 'address', 'active'], 'distributor');
  v_old := private.operation_result('upsert_supplier_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_id := private.input_uuid(p_input->'supplier_id', 'supplier_id', false);
  v_name := regexp_replace(private.input_text(p_input->'name', 'Nama distributor', 120, true), '\s+', ' ', 'g');
  if exists (select 1 from private.suppliers where lower(trim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'DUPLICATE_NAME: Nama distributor sudah ada' using errcode = '22023';
  end if;

  if v_id is null then
    if p_input ? 'expected_version' then
      raise exception 'INVALID_INPUT: expected_version hanya untuk mengubah distributor' using errcode = '22023';
    end if;
    begin
      insert into private.suppliers(name, contact, address, active)
      values (v_name, private.input_text(p_input->'contact', 'Kontak', 120),
        private.input_text(p_input->'address', 'Alamat', 300),
        private.input_bool(p_input->'active', 'active', true))
      returning * into v_supplier;
    exception when unique_violation then
      raise exception 'DUPLICATE_NAME: Nama distributor sudah ada' using errcode = '22023';
    end;
  else
    select * into v_supplier from private.suppliers where id = v_id for update;
    if not found then
      raise exception 'NOT_FOUND: Distributor tidak ditemukan' using errcode = '22023';
    end if;
    if v_supplier.version <> private.input_version(p_input->'expected_version') then
      raise exception 'VERSION_CONFLICT: Data distributor berubah. Muat ulang.' using errcode = '40001';
    end if;
    begin
      update private.suppliers set name = v_name,
        contact = private.input_text(p_input->'contact', 'Kontak', 120),
        address = private.input_text(p_input->'address', 'Alamat', 300),
        active = private.input_bool(p_input->'active', 'active', v_supplier.active),
        version = version + 1
        where id = v_id returning * into v_supplier;
    exception when unique_violation then
      raise exception 'DUPLICATE_NAME: Nama distributor sudah ada' using errcode = '22023';
    end;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, case when v_id is null then 'CREATE_SUPPLIER' else 'UPDATE_SUPPLIER' end, 'SUPPLIER', v_supplier.id, null);

  return private.finish_operation('upsert_supplier_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_supplier.id, 'name', v_supplier.name, 'active', v_supplier.active,
    'version', v_supplier.version, 'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.upsert_supplier_v1(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_supplier_v1(jsonb) to authenticated;

-- === list_suppliers_v1 ====================================================
create or replace function public.list_suppliers_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_query text; v_inactive boolean;
begin
  perform private.require_role(array['OWNER', 'MAINTAINER']);
  perform private.input_keys_only(coalesce(p_input, '{}'::jsonb), array['query', 'include_inactive'], 'daftar distributor');
  v_query := private.input_text(p_input->'query', 'Pencarian', 120);
  v_inactive := private.input_bool(p_input->'include_inactive', 'include_inactive', false);
  return jsonb_build_object('items', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'contact', s.contact, 'address', s.address,
      'active', s.active, 'version', s.version,
      'credit_balance', private.supplier_credit_balance(s.id)::text,
      'pending_return_count', (select count(*) from private.supplier_returns r
        where r.supplier_id = s.id and r.status = 'PENDING'),
      'pending_claim_value', (select coalesce(sum(r.claim_value), 0) from private.supplier_returns r
        where r.supplier_id = s.id and r.status = 'PENDING')::text
    ) order by lower(s.name), s.id), '[]'::jsonb)
    from private.suppliers s
    where (v_inactive or s.active)
      and (v_query is null or s.name ilike '%' || replace(replace(v_query, '%', '\%'), '_', '\_') || '%')));
end $$;
revoke all on function public.list_suppliers_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_suppliers_v1(jsonb) to authenticated;

-- === create_supplier_return_v1 ============================================
create or replace function public.create_supplier_return_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_op uuid; v_supplier_id uuid; v_reason text; v_item jsonb; v_idx integer := 0;
  v_ids uuid[] := '{}'; v_req jsonb := '{}'::jsonb; v_row record; v_qty numeric; v_cost numeric;
  v_claim numeric := 0; v_doc private.stock_documents%rowtype; v_doc_item uuid; v_return uuid;
  v_pos private.stock_positions%rowtype; v_lot private.inventory_lots%rowtype; v_product private.products%rowtype;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input, array['operation_id', 'supplier_id', 'reason', 'items'], 'retur distributor');
  v_old := private.operation_result('create_supplier_return_v1', p_input);
  if v_old is not null then return v_old; end if;
  v_op := (p_input->>'operation_id')::uuid;

  v_supplier_id := private.input_uuid(p_input->'supplier_id', 'supplier_id');
  v_reason := private.input_text(p_input->'reason', 'Alasan retur', 500, true);
  if jsonb_typeof(p_input->'items') is distinct from 'array' or jsonb_array_length(p_input->'items') not between 1 and 100 then
    raise exception 'INVALID_INPUT: Daftar barang retur wajib diisi (1-100 baris)' using errcode = '22023';
  end if;
  for v_item in select value from jsonb_array_elements(p_input->'items') loop
    v_idx := v_idx + 1;
    perform private.input_keys_only(v_item, array['position_id', 'qty_base', 'expected_version'], format('baris %s', v_idx));
    if private.input_uuid(v_item->'position_id', format('Baris %s: position_id', v_idx)) = any (v_ids) then
      raise exception 'INVALID_INPUT: Baris %: posisi stok yang sama tidak boleh dipilih dua kali', v_idx using errcode = '22023';
    end if;
    v_ids := v_ids || (v_item->>'position_id')::uuid;
    v_req := v_req || jsonb_build_object((v_item->>'position_id')::uuid::text, jsonb_build_object(
      'qty', private.input_decimal(v_item->'qty_base', 3, 999999999.999, true, format('Baris %s jumlah', v_idx)),
      'version', private.input_version(v_item->'expected_version'), 'line', v_idx));
  end loop;

  -- Urutan kunci: distributor -> produk -> lot -> posisi (masing-masing menurut id).
  perform 1 from private.suppliers where id = v_supplier_id and active for update;
  if not found then
    raise exception 'NOT_FOUND: Distributor tidak ditemukan atau tidak aktif' using errcode = '22023';
  end if;
  if (select count(*) from private.stock_positions where id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'NOT_FOUND: Posisi stok tidak ditemukan' using errcode = '22023';
  end if;
  perform 1 from private.products where id in (select l.product_id from private.inventory_lots l
    join private.stock_positions s on s.lot_id = l.id where s.id = any (v_ids)) order by id for update;
  perform 1 from private.inventory_lots where id in (select lot_id from private.stock_positions where id = any (v_ids))
    order by id for update;
  perform 1 from private.stock_positions where id = any (v_ids) order by id for update;

  -- Validasi setelah kunci.
  for v_row in select s.id from private.stock_positions s where s.id = any (v_ids) order by s.id loop
    select * into v_pos from private.stock_positions where id = v_row.id;
    select p.* into v_product from private.products p join private.inventory_lots l on l.product_id = p.id
      where l.id = v_pos.lot_id;
    v_qty := (v_req->v_pos.id::text->>'qty')::numeric;
    if v_pos.version <> (v_req->v_pos.id::text->>'version')::integer then
      raise exception 'VERSION_CONFLICT: Baris %: stok berubah. Muat ulang.', v_req->v_pos.id::text->>'line'
        using errcode = '40001';
    end if;
    if v_qty > v_pos.qty_base then
      raise exception 'INSUFFICIENT_STOCK: Baris %: jumlah retur melebihi stok posisi', v_req->v_pos.id::text->>'line'
        using errcode = '22023';
    end if;
    if mod(v_qty, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_INPUT: Baris %: jumlah tidak sesuai langkah stok', v_req->v_pos.id::text->>'line'
        using errcode = '22023';
    end if;
  end loop;

  insert into private.stock_documents(number, kind, supplier_id, actor_id, reason, operation_id)
  values (private.next_stock_number('SUPPLIER_RETURN'), 'SUPPLIER_RETURN', v_supplier_id, v_actor, v_reason, v_op)
  returning * into v_doc;

  v_idx := 0;
  for v_row in select s.id from private.stock_positions s where s.id = any (v_ids) order by s.id loop
    v_idx := v_idx + 1;
    select * into v_pos from private.stock_positions where id = v_row.id;
    select * into v_lot from private.inventory_lots where id = v_pos.lot_id;
    select * into v_product from private.products where id = v_lot.product_id;
    v_qty := (v_req->v_pos.id::text->>'qty')::numeric;
    -- BR-05: modal keluar dari lot posisi; lot yang sama diproses berurutan id posisi.
    v_cost := private.cost_for_exit_lot(v_lot.id, v_qty);
    insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
      factor_snapshot, qty_base, acquisition_cost, source_location, condition, note)
    values (v_doc.id, v_idx, v_product.id, v_product.base_unit, v_qty, 1, v_qty, v_cost,
      v_pos.location, v_pos.condition, v_pos.label)
    returning id into v_doc_item;
    update private.stock_positions set qty_base = qty_base - v_qty, sealed = false, version = version + 1
      where id = v_pos.id;
    update private.inventory_lots set remaining_qty = remaining_qty - v_qty,
      remaining_cost = remaining_cost - v_cost, version = version + 1 where id = v_lot.id;
    insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
      stock_document_item_id, actor_id, operation_id)
    values (v_doc.id, v_lot.id, v_pos.id, -v_qty, -v_cost, 'SUPPLIER_RETURN_OUT', v_doc_item, v_actor, v_op);
    v_claim := v_claim + v_cost;
  end loop;

  insert into private.supplier_returns(stock_document_id, supplier_id, claim_value, reason, actor_id, operation_id)
  values (v_doc.id, v_supplier_id, v_claim, v_reason, v_actor, v_op)
  returning id into v_return;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREATE_SUPPLIER_RETURN', 'SUPPLIER_RETURN', v_return, v_reason);

  return private.finish_operation('create_supplier_return_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_return, 'document_number', v_doc.number, 'status', 'PENDING',
    'claim_value', v_claim::text, 'version', 1, 'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.create_supplier_return_v1(jsonb) from public, anon, authenticated;
grant execute on function public.create_supplier_return_v1(jsonb) to authenticated;

-- === settle_supplier_return_v1 ============================================
create or replace function public.settle_supplier_return_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_op uuid; v_ret private.supplier_returns%rowtype; v_outcome text; v_allowed text[];
  v_amount numeric(20,0); v_method text; v_cashbox text; v_session private.cash_sessions%rowtype;
  v_movement uuid; v_credit uuid; v_note text; v_reference text; v_diff numeric; v_doc private.stock_documents%rowtype;
  v_line jsonb; v_idx integer; v_n integer; v_bases numeric[] := '{}'; v_costs numeric[] := '{}';
  v_explicit integer := 0; v_q record; v_total_w numeric := 0; v_claim_micro numeric; v_alloc numeric; v_rem_left numeric;
  v_lines jsonb := '[]'::jsonb; v_rank record;
begin
  v_actor := private.require_role(array['OWNER']);
  v_outcome := p_input->>'outcome';
  v_allowed := array['operation_id', 'supplier_return_id', 'expected_version', 'outcome', 'note'];
  v_allowed := v_allowed || case v_outcome
    when 'REFUND' then array['amount', 'method', 'cashbox', 'confirmed', 'reference']
    when 'CREDIT' then array['amount', 'reference']
    when 'REPLACEMENT' then array['items']
    else array[]::text[] end;
  perform private.input_keys_only(p_input, v_allowed, 'penyelesaian retur distributor');
  v_old := private.operation_result('settle_supplier_return_v1', p_input);
  if v_old is not null then return v_old; end if;
  v_op := (p_input->>'operation_id')::uuid;
  if v_outcome is null or v_outcome not in ('REFUND', 'CREDIT', 'REPLACEMENT', 'REJECTED') then
    raise exception 'INVALID_INPUT: Hasil wajib REFUND, CREDIT, REPLACEMENT, atau REJECTED' using errcode = '22023';
  end if;
  v_note := private.input_text(p_input->'note', 'Catatan', 500, v_outcome = 'REJECTED');
  v_reference := private.input_text(p_input->'reference', 'Referensi', 120);

  -- Kunci dokumen retur (root) lebih dulu.
  select * into v_ret from private.supplier_returns
    where id = private.input_uuid(p_input->'supplier_return_id', 'supplier_return_id') for update;
  if not found then
    raise exception 'NOT_FOUND: Retur distributor tidak ditemukan' using errcode = '22023';
  end if;
  if v_ret.status <> 'PENDING' then
    raise exception 'ALREADY_SETTLED: Retur distributor ini sudah diselesaikan' using errcode = '40001';
  end if;
  if v_ret.version <> private.input_version(p_input->'expected_version') then
    raise exception 'VERSION_CONFLICT: Data retur berubah. Muat ulang.' using errcode = '40001';
  end if;

  if v_outcome in ('REFUND', 'CREDIT') then
    v_amount := private.input_decimal(p_input->'amount', 0, 9999999999999999, true, 'Jumlah');
    v_diff := v_amount - v_ret.claim_value;
  elsif v_outcome = 'REJECTED' then
    v_amount := 0;
    v_diff := -v_ret.claim_value;
  else
    v_diff := 0;
  end if;

  if v_outcome = 'REFUND' then
    v_method := p_input->>'method';
    if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS') then
      raise exception 'INVALID_INPUT: Metode uang kembali wajib CASH, TRANSFER, atau QRIS' using errcode = '22023';
    end if;
    if v_method = 'CASH' then
      if p_input ? 'confirmed' then
        raise exception 'INVALID_INPUT: Konfirmasi hanya untuk TRANSFER/QRIS' using errcode = '22023';
      end if;
      v_cashbox := private.cash_cashbox_input(p_input->'cashbox', 'Kas penerima');
      v_session := private.lock_open_cash_session(v_cashbox);
      insert into private.cash_movements(session_id, direction, kind, amount, supplier_return_id, reason, actor_id, operation_id)
      values (v_session.id, 'IN', 'SUPPLIER_REFUND', v_amount, v_ret.id,
        coalesce(v_note, 'Uang kembali retur distributor'), v_actor, v_op)
      returning id into v_movement;
    else
      if p_input ? 'cashbox' then
        raise exception 'INVALID_INPUT: Kas hanya diisi untuk metode tunai' using errcode = '22023';
      end if;
      if not private.input_bool(p_input->'confirmed', 'confirmed', false) then
        raise exception 'PAYMENT_NOT_CONFIRMED: Pastikan uang % dari distributor sudah masuk, lalu centang konfirmasi',
          v_method using errcode = '22023';
      end if;
    end if;
  elsif v_outcome = 'CREDIT' then
    insert into private.supplier_credit_entries(supplier_id, direction, amount, supplier_return_id, actor_id, operation_id)
    values (v_ret.supplier_id, 'IN', v_amount, v_ret.id, v_actor, v_op)
    returning id into v_credit;
  elsif v_outcome = 'REPLACEMENT' then
    if jsonb_typeof(p_input->'items') is distinct from 'array' or jsonb_array_length(p_input->'items') not between 1 and 100 then
      raise exception 'INVALID_INPUT: Daftar barang pengganti wajib diisi (1-100 baris)' using errcode = '22023';
    end if;
    v_n := jsonb_array_length(p_input->'items');
    v_idx := 0;
    for v_line in select value from jsonb_array_elements(p_input->'items') loop
      v_idx := v_idx + 1;
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'INVALID_INPUT: Baris % tidak sah', v_idx using errcode = '22023';
      end if;
      if v_line ? 'free_reason' then
        raise exception 'INVALID_INPUT: Baris %: barang pengganti tidak memakai alasan modal nol', v_idx using errcode = '22023';
      end if;
      select * into v_q from private.inbound_qty_base(v_line, v_idx);
      v_bases := v_bases || v_q.qty_base;
      v_total_w := v_total_w + v_q.qty_base;
      if v_line ? 'acquisition_cost' then
        v_explicit := v_explicit + 1;
        v_costs := v_costs || private.input_decimal(v_line->'acquisition_cost', 6, 999999999999999999.999999, false,
          format('Baris %s modal', v_idx));
      end if;
    end loop;
    if v_explicit = v_n then
      if (select sum(c) from unnest(v_costs) c) <> v_ret.claim_value then
        raise exception 'INVALID_INPUT: Total modal barang pengganti harus sama dengan nilai klaim %',
          private.cash_rupiah(v_ret.claim_value) using errcode = '22023';
      end if;
    elsif v_explicit = 0 then
      -- Alokasi proporsional qty dasar, sisa pembagian (satuan 0,000001) ke pecahan terbesar lalu nomor baris.
      v_claim_micro := v_ret.claim_value * 1000000;
      v_costs := array_fill(0::numeric, array[v_n]);
      v_rem_left := v_claim_micro;
      for v_idx in 1..v_n loop
        v_alloc := trunc(v_claim_micro * v_bases[v_idx] / v_total_w);
        v_costs[v_idx] := v_alloc;
        v_rem_left := v_rem_left - v_alloc;
      end loop;
      for v_rank in select i from generate_series(1, v_n) i
        order by mod(v_claim_micro * v_bases[i] * 1000, v_total_w * 1000) desc, i limit v_rem_left
      loop
        v_costs[v_rank.i] := v_costs[v_rank.i] + 1;
      end loop;
      for v_idx in 1..v_n loop v_costs[v_idx] := v_costs[v_idx] / 1000000; end loop;
    else
      raise exception 'INVALID_INPUT: Isi modal untuk semua baris pengganti, atau kosongkan semuanya' using errcode = '22023';
    end if;

    v_idx := 0;
    for v_line in select value from jsonb_array_elements(p_input->'items') loop
      v_idx := v_idx + 1;
      perform private.input_uuid(v_line->'product_unit_id', format('Baris %s: product_unit_id', v_idx));
    end loop;
    perform 1 from private.products p where p.id in
      (select u.product_id from private.product_units u where u.id in
        (select (x->>'product_unit_id')::uuid from jsonb_array_elements(p_input->'items') x))
      order by p.id for update;
    insert into private.stock_documents(number, kind, supplier_id, actor_id, reason, corrects_document_id, operation_id)
    values (private.next_stock_number('SUPPLIER_REPLACEMENT'), 'SUPPLIER_REPLACEMENT', v_ret.supplier_id, v_actor,
      coalesce(v_note, 'Barang pengganti retur distributor'), v_ret.stock_document_id, v_op)
    returning * into v_doc;
    v_idx := 0;
    for v_line in select value from jsonb_array_elements(p_input->'items') loop
      v_idx := v_idx + 1;
      v_lines := v_lines || private.inbound_line(v_doc, v_idx, v_line - 'acquisition_cost', v_costs[v_idx],
        'SUPPLIER_REPLACEMENT_IN', v_actor, v_op);
    end loop;
  end if;

  update private.supplier_returns set status = 'SETTLED', outcome = v_outcome,
    settled_amount = v_amount, settlement_method = v_method, settlement_cashbox = v_cashbox,
    settlement_reference = v_reference, cash_movement_id = v_movement, replacement_document_id = v_doc.id,
    settlement_difference = v_diff, settlement_note = v_note, settled_by = v_actor, settled_at = now(),
    version = version + 1
    where id = v_ret.id returning * into v_ret;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'SETTLE_SUPPLIER_RETURN_' || v_outcome, 'SUPPLIER_RETURN', v_ret.id, v_note);

  return private.finish_operation('settle_supplier_return_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_ret.id, 'status', v_ret.status, 'outcome', v_outcome,
    'claim_value', v_ret.claim_value::text, 'settled_amount', v_amount::text,
    'settlement_difference', v_diff::text, 'cash_session_id', v_session.id, 'credit_entry_id', v_credit,
    'replacement_document_id', v_doc.id, 'replacement_document_number', v_doc.number, 'lines', v_lines,
    'version', v_ret.version, 'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.settle_supplier_return_v1(jsonb) from public, anon, authenticated;
grant execute on function public.settle_supplier_return_v1(jsonb) to authenticated;

-- === list_supplier_returns_v1 =============================================
create or replace function public.list_supplier_returns_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_status text; v_supplier uuid; v_start timestamptz; v_end timestamptz; v_limit integer; v_offset integer;
begin
  perform private.require_role(array['OWNER', 'MAINTAINER']);
  p_input := coalesce(p_input, '{}'::jsonb);
  perform private.input_keys_only(p_input,
    array['status', 'supplier_id', 'start_date', 'end_date', 'limit', 'offset'], 'daftar retur distributor');
  v_status := p_input->>'status';
  if v_status is not null and v_status not in ('PENDING', 'SETTLED') then
    raise exception 'INVALID_INPUT: Status wajib PENDING atau SETTLED' using errcode = '22023';
  end if;
  v_supplier := private.input_uuid(p_input->'supplier_id', 'supplier_id', false);
  if p_input ? 'start_date' or p_input ? 'end_date' then
    select start_at, end_at into v_start, v_end from private.date_range_input(p_input, 366);
  end if;
  v_limit := coalesce(private.decimal_input_opt(p_input->'limit', 0, 200), 50);
  v_offset := coalesce(private.decimal_input_opt(p_input->'offset', 0, 1000000, false), 0);

  return jsonb_build_object('items', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'document_number', d.number, 'supplier_id', r.supplier_id, 'supplier_name', s.name,
      'status', r.status, 'reason', r.reason, 'claim_value', r.claim_value::text,
      'created_at', r.created_at, 'outcome', r.outcome, 'settled_amount', r.settled_amount::text,
      'settlement_method', r.settlement_method, 'settlement_cashbox', r.settlement_cashbox,
      'settlement_reference', r.settlement_reference,
      'settlement_difference', r.settlement_difference::text, 'settlement_note', r.settlement_note,
      'settled_at', r.settled_at,
      'replacement_document_number', (select number from private.stock_documents where id = r.replacement_document_id),
      'version', r.version,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
          'line_no', i.line_no, 'product_id', i.product_id, 'sku', p.sku, 'name', p.name,
          'qty_base', i.qty_base::text, 'unit', i.unit_snapshot, 'cost', i.acquisition_cost::text,
          'source_location', i.source_location, 'condition', i.condition, 'position_label', i.note
        ) order by i.line_no), '[]'::jsonb)
        from private.stock_document_items i join private.products p on p.id = i.product_id
        where i.document_id = r.stock_document_id)
    ) order by r.created_at desc, r.id), '[]'::jsonb)
    from private.supplier_returns r
    join private.stock_documents d on d.id = r.stock_document_id
    join private.suppliers s on s.id = r.supplier_id
    where r.id in (select x.id from private.supplier_returns x
      where (v_status is null or x.status = v_status)
        and (v_supplier is null or x.supplier_id = v_supplier)
        and (v_start is null or (x.created_at >= v_start and x.created_at < v_end))
      order by x.created_at desc, x.id limit v_limit offset v_offset)));
end $$;
revoke all on function public.list_supplier_returns_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_supplier_returns_v1(jsonb) to authenticated;
