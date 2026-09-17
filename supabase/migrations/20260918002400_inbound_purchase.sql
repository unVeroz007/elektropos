-- Perbaikan audit 2026-09: barang masuk, stok awal, pembelian tunai (D3, T08, BR-03, BR-05).
-- Nama command idempotensi = nama RPC publik (post_stock_receipt_v1, post_opening_stock_v1).

-- Satu posisi fisik + gerakan ledger. Modal lot dicatat pada gerakan pertama
-- sehingga sum(cost_delta) per lot = remaining_cost.
create or replace function private.inbound_position(
  p_lot_id uuid, p_item_id uuid, p_doc_id uuid, p_label text, p_qty numeric, p_capacity numeric,
  p_sealed boolean, p_cost numeric, p_kind text, p_actor uuid, p_op uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_position uuid;
begin
  if p_label is not null then
    if length(p_label) > 60 or p_label ~ '[[:cntrl:]]' then
      raise exception 'INVALID_INPUT: Label roll maksimal 60 karakter' using errcode = '22023';
    end if;
    if exists (select 1 from private.stock_positions where label = p_label) then
      raise exception 'LABEL_TAKEN: Label roll "%" sudah dipakai. Gunakan label lain.', p_label using errcode = '22023';
    end if;
  end if;
  begin
    insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
    values (p_lot_id, 'SHOP', 'SALEABLE', p_qty, p_label, p_capacity, p_sealed)
    returning id into v_position;
  exception when unique_violation then
    raise exception 'LABEL_TAKEN: Label roll "%" sudah dipakai. Gunakan label lain.', p_label using errcode = '22023';
  end;
  insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
    stock_document_item_id, actor_id, operation_id)
  values (p_doc_id, p_lot_id, v_position, p_qty, p_cost, p_kind, p_item_id, p_actor, p_op);
  return jsonb_build_object('position_id', v_position, 'label', p_label, 'qty_base', p_qty::text,
    'segment_capacity', p_capacity::text, 'sealed', p_sealed);
end $$;
revoke all on function private.inbound_position(uuid,uuid,uuid,text,numeric,numeric,boolean,numeric,text,uuid,uuid)
  from public, anon, authenticated;

-- Hitung qty dasar satu baris (validasi satuan, langkah, konversi).
create or replace function private.inbound_qty_base(p_line jsonb, p_line_no integer)
returns table(unit_id uuid, product_id uuid, qty numeric, qty_base numeric)
language plpgsql stable security definer set search_path = '' as $$
declare v_unit private.product_units%rowtype; v_product private.products%rowtype; v_qty numeric; v_base numeric;
begin
  select * into v_unit from private.product_units
    where id = private.input_uuid(p_line->'product_unit_id', format('Baris %s: product_unit_id', p_line_no)) and active;
  if not found then
    raise exception 'NOT_FOUND: Baris %: satuan barang tidak ditemukan atau tidak aktif', p_line_no using errcode = '22023';
  end if;
  select * into v_product from private.products where id = v_unit.product_id and active;
  if not found then
    raise exception 'NOT_FOUND: Baris %: produk sudah diarsip', p_line_no using errcode = '22023';
  end if;
  v_qty := private.input_decimal(p_line->'qty', 3, 999999999.999, true, format('Baris %s jumlah', p_line_no));
  v_base := v_qty * v_unit.factor_base;
  if mod(v_qty, v_unit.sale_step) <> 0 or round(v_base, 3) <> v_base
     or v_base > 999999999.999 or mod(v_base, v_product.quantity_step) <> 0 then
    raise exception 'INVALID_INPUT: Baris %: jumlah tidak sesuai kelipatan satuan barang', p_line_no using errcode = '22023';
  end if;
  return query select v_unit.id, v_product.id, v_qty, v_base;
end $$;
revoke all on function private.inbound_qty_base(jsonb, integer) from public, anon, authenticated;

-- Satu baris barang masuk = satu dokumen item + satu lot (BR-05) + posisi fisik.
-- Produk roll (track_segments) wajib `rolls` ("N roll @ kapasitas", label otomatis)
-- dan/atau `positions` eksplisit berlabel; Σ panjang posisi = qty dasar.
create or replace function private.inbound_line(
  p_doc private.stock_documents, p_line_no integer, p_line jsonb, p_cost numeric,
  p_movement_kind text, p_actor uuid, p_op uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_q record; v_unit private.product_units%rowtype; v_product private.products%rowtype;
  v_item uuid; v_lot uuid; v_positions jsonb := '[]'::jsonb; v_pos jsonb; v_sum numeric := 0; v_count integer := 0;
  v_rolls jsonb; v_n integer; v_capacity numeric; v_qty numeric; v_prefix text; v_label text; v_sealed boolean;
  v_cost_left numeric := p_cost; v_width integer; i integer;
begin
  perform private.input_keys_only(p_line,
    array['product_unit_id', 'qty', 'acquisition_cost', 'free_reason', 'note', 'positions', 'rolls'],
    format('baris %s', p_line_no));
  select * into v_q from private.inbound_qty_base(p_line, p_line_no);
  select * into v_unit from private.product_units where id = v_q.unit_id;
  select * into v_product from private.products where id = v_q.product_id;

  insert into private.stock_document_items(document_id, line_no, product_id, unit_snapshot, qty_input,
    factor_snapshot, qty_base, acquisition_cost, destination_location, condition, note, free_reason)
  values (p_doc.id, p_line_no, v_product.id, v_unit.label, v_q.qty, v_unit.factor_base, v_q.qty_base, p_cost,
    'SHOP', 'SALEABLE', private.input_text(p_line->'note', 'Catatan', 500),
    private.input_text(p_line->'free_reason', 'Alasan modal nol', 500))
  returning id into v_item;
  insert into private.inventory_lots(product_id, origin_item_id, original_qty, original_cost, remaining_qty, remaining_cost)
  values (v_product.id, v_item, v_q.qty_base, p_cost, v_q.qty_base, p_cost)
  returning id into v_lot;

  if not v_product.track_segments then
    if p_line ? 'positions' or p_line ? 'rolls' then
      raise exception 'INVALID_INPUT: Baris %: barang ini bukan roll; jangan isi daftar roll', p_line_no using errcode = '22023';
    end if;
    v_positions := jsonb_build_array(private.inbound_position(v_lot, v_item, p_doc.id, null, v_q.qty_base, null,
      false, p_cost, p_movement_kind, p_actor, p_op));
  else
    if not (p_line ? 'positions' or p_line ? 'rolls') then
      raise exception 'INVALID_INPUT: Baris %: barang roll wajib diisi daftar roll/potongan', p_line_no using errcode = '22023';
    end if;

    if p_line ? 'rolls' then
      v_rolls := p_line->'rolls';
      perform private.input_keys_only(v_rolls, array['count', 'capacity', 'label_prefix'], format('roll baris %s', p_line_no));
      v_n := private.input_decimal(v_rolls->'count', 0, 500, true, format('Baris %s jumlah roll', p_line_no));
      v_capacity := private.input_decimal(v_rolls->'capacity', 3, 999999999.999, true, format('Baris %s isi per roll', p_line_no));
      if mod(v_capacity, v_product.quantity_step) <> 0 then
        raise exception 'INVALID_INPUT: Baris %: isi per roll tidak sesuai langkah stok', p_line_no using errcode = '22023';
      end if;
      v_prefix := coalesce(private.input_text(v_rolls->'label_prefix', 'Awalan label', 40),
        v_product.sku || '-' || to_char(p_doc.posted_at at time zone 'Asia/Jakarta', 'YYMMDD') || '-'
          || ltrim(split_part(p_doc.number, '-', 3), '0') || 'L' || p_line_no);
      v_width := greatest(2, length(v_n::text));
      for i in 1..v_n loop
        v_label := v_prefix || '-' || lpad(i::text, v_width, '0');
        v_positions := v_positions || private.inbound_position(v_lot, v_item, p_doc.id, v_label, v_capacity,
          v_capacity, true, v_cost_left, p_movement_kind, p_actor, p_op);
        v_cost_left := 0;
        v_sum := v_sum + v_capacity; v_count := v_count + 1;
      end loop;
    end if;

    if p_line ? 'positions' then
      if jsonb_typeof(p_line->'positions') <> 'array' or jsonb_array_length(p_line->'positions') = 0 then
        raise exception 'INVALID_INPUT: Baris %: daftar potongan harus berisi minimal satu', p_line_no using errcode = '22023';
      end if;
      for v_pos in select value from jsonb_array_elements(p_line->'positions') loop
        perform private.input_keys_only(v_pos, array['label', 'qty_base', 'segment_capacity', 'sealed'],
          format('potongan baris %s', p_line_no));
        v_label := private.input_text(v_pos->'label', format('Baris %s label roll', p_line_no), 60, true);
        v_qty := private.input_decimal(v_pos->'qty_base', 3, 999999999.999, true, format('Baris %s panjang', p_line_no));
        v_capacity := private.input_decimal(v_pos->'segment_capacity', 3, 999999999.999, true,
          format('Baris %s kapasitas roll', p_line_no));
        v_sealed := private.input_bool(v_pos->'sealed', 'sealed', false);
        if v_qty > v_capacity then
          raise exception 'INVALID_INPUT: Baris %: panjang roll % melebihi kapasitasnya', p_line_no, v_label using errcode = '22023';
        end if;
        if v_sealed and v_qty <> v_capacity then
          raise exception 'INVALID_INPUT: Baris %: roll % hanya boleh bersegel bila utuh', p_line_no, v_label using errcode = '22023';
        end if;
        if mod(v_qty, v_product.quantity_step) <> 0 then
          raise exception 'INVALID_INPUT: Baris %: panjang roll % tidak sesuai langkah stok', p_line_no, v_label using errcode = '22023';
        end if;
        v_positions := v_positions || private.inbound_position(v_lot, v_item, p_doc.id, v_label, v_qty,
          v_capacity, v_sealed, v_cost_left, p_movement_kind, p_actor, p_op);
        v_cost_left := 0;
        v_sum := v_sum + v_qty; v_count := v_count + 1;
      end loop;
    end if;

    if v_count > 500 then
      raise exception 'INVALID_INPUT: Baris %: maksimal 500 roll/potongan', p_line_no using errcode = '22023';
    end if;
    if v_sum <> v_q.qty_base then
      raise exception 'INVALID_INPUT: Baris %: total panjang roll/potongan % harus sama dengan jumlah masuk %',
        p_line_no, v_sum, v_q.qty_base using errcode = '22023';
    end if;
  end if;

  return jsonb_build_object('line_no', p_line_no, 'item_id', v_item, 'lot_id', v_lot,
    'product_id', v_product.id, 'qty_base', v_q.qty_base::text, 'positions', v_positions);
end $$;
revoke all on function private.inbound_line(private.stock_documents, integer, jsonb, numeric, text, uuid, uuid)
  from public, anon, authenticated;

-- === post_inbound (RECEIPT/OPENING) =======================================
create or replace function private.post_inbound(p_input jsonb, p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_command text; v_old jsonb; v_op uuid; v_line jsonb; v_idx integer := 0;
  v_cost numeric; v_costs numeric[] := '{}'; v_total numeric(20,0) := 0;
  v_supplier_id uuid; v_payment jsonb; v_method text; v_amount numeric(20,0); v_cashbox text;
  v_session private.cash_sessions%rowtype; v_expected numeric(20,0); v_balance numeric(20,0);
  v_source_date date; v_doc private.stock_documents%rowtype; v_lines jsonb := '[]'::jsonb;
  v_movement uuid; v_credit uuid;
begin
  v_actor := private.require_role(array['OWNER']);
  if p_kind = 'RECEIPT' then
    v_command := 'post_stock_receipt_v1';
    perform private.input_keys_only(p_input,
      array['operation_id', 'supplier_id', 'source_note', 'source_date', 'reason', 'items', 'payment'], 'barang masuk');
  elsif p_kind = 'OPENING' then
    v_command := 'post_opening_stock_v1';
    perform private.input_keys_only(p_input,
      array['operation_id', 'source_note', 'source_date', 'reason', 'items'], 'stok awal (tanpa pembayaran)');
  else
    raise exception 'INVALID_INPUT: Jenis barang masuk tidak dikenal' using errcode = '22023';
  end if;
  v_old := private.operation_result(v_command, p_input);
  if v_old is not null then return v_old; end if;
  v_op := (p_input->>'operation_id')::uuid;

  if jsonb_typeof(p_input->'items') is distinct from 'array' or jsonb_array_length(p_input->'items') not between 1 and 100 then
    raise exception 'INVALID_INPUT: Daftar barang wajib diisi (1-100 baris)' using errcode = '22023';
  end if;
  begin
    v_source_date := nullif(p_input->>'source_date', '')::date;
  exception when others then
    raise exception 'INVALID_DATE: Tanggal nota tidak sah (format YYYY-MM-DD)' using errcode = '22023';
  end;

  -- Modal per baris: Rupiah bulat, wajib; nol hanya dengan alasan perolehan gratis.
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_idx := v_idx + 1;
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'INVALID_INPUT: Baris % tidak sah', v_idx using errcode = '22023';
    end if;
    v_cost := private.input_decimal(v_line->'acquisition_cost', 0, 9999999999999999, false,
      format('Baris %s total modal', v_idx));
    if v_cost = 0 and private.input_text(v_line->'free_reason', 'Alasan modal nol', 500) is null then
      raise exception 'INVALID_INPUT: Baris %: modal nol hanya untuk barang gratis; isi alasannya', v_idx using errcode = '22023';
    end if;
    v_costs := v_costs || v_cost;
    v_total := v_total + v_cost;
  end loop;

  if p_kind = 'RECEIPT' then
    v_supplier_id := private.input_uuid(p_input->'supplier_id', 'supplier_id', false);
    v_payment := p_input->'payment';
    if v_total > 0 or v_payment is not null then
      perform private.input_keys_only(v_payment, array['method', 'amount', 'cashbox', 'confirmed', 'reference'], 'pembayaran');
      v_amount := private.input_decimal(v_payment->'amount', 0, 9999999999999999, false, 'Jumlah bayar');
      if v_amount <> v_total then
        raise exception 'PAYMENT_MISMATCH: Jumlah bayar % harus sama dengan total modal barang %',
          private.cash_rupiah(v_amount), private.cash_rupiah(v_total) using errcode = '22023';
      end if;
      v_method := v_payment->>'method';
      if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS', 'SUPPLIER_CREDIT') then
        raise exception 'INVALID_INPUT: Metode bayar wajib CASH, TRANSFER, QRIS, atau SUPPLIER_CREDIT' using errcode = '22023';
      end if;
      if v_method <> 'CASH' and v_payment ? 'cashbox' then
        raise exception 'INVALID_INPUT: Kas hanya diisi untuk pembayaran tunai' using errcode = '22023';
      end if;
      if v_method in ('TRANSFER', 'QRIS') and not private.input_bool(v_payment->'confirmed', 'confirmed', false) then
        raise exception 'PAYMENT_NOT_CONFIRMED: Pastikan pembayaran % ke distributor sudah dilakukan, lalu centang konfirmasi',
          v_method using errcode = '22023';
      end if;
      if v_method = 'SUPPLIER_CREDIT' and v_supplier_id is null then
        raise exception 'INVALID_INPUT: Pilih distributor untuk memakai saldo kredit' using errcode = '22023';
      end if;
    end if;

    -- Urutan kunci: distributor (root) -> sesi kas -> produk.
    if v_supplier_id is not null then
      perform 1 from private.suppliers where id = v_supplier_id and active for update;
      if not found then
        raise exception 'NOT_FOUND: Distributor tidak ditemukan atau tidak aktif' using errcode = '22023';
      end if;
    end if;
    if v_total > 0 and v_method = 'CASH' then
      v_cashbox := private.cash_cashbox_input(v_payment->'cashbox', 'Kas pembayar');
      v_session := private.lock_open_cash_session(v_cashbox);
      v_expected := private.cash_session_expected(v_session.id);
      if v_expected < v_total then
        raise exception 'INSUFFICIENT_CASH: Saldo kas % tidak cukup untuk membayar %',
          private.cash_rupiah(v_expected), private.cash_rupiah(v_total) using errcode = '22023';
      end if;
    elsif v_total > 0 and v_method = 'SUPPLIER_CREDIT' then
      v_balance := private.supplier_credit_balance(v_supplier_id);
      if v_balance < v_total then
        raise exception 'INSUFFICIENT_CREDIT: Saldo kredit distributor % tidak cukup untuk membayar %',
          private.cash_rupiah(v_balance), private.cash_rupiah(v_total) using errcode = '22023';
      end if;
    end if;
  end if;

  -- Validasi uuid satuan lalu kunci produk dalam urutan id.
  v_idx := 0;
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_idx := v_idx + 1;
    perform private.input_uuid(v_line->'product_unit_id', format('Baris %s: product_unit_id', v_idx));
  end loop;
  perform 1 from private.products p where p.id in
    (select u.product_id from private.product_units u where u.id in
      (select (x->>'product_unit_id')::uuid from jsonb_array_elements(p_input->'items') x))
    order by p.id for update;

  insert into private.stock_documents(number, kind, supplier_id, source_note, source_date, actor_id, reason, operation_id)
  values (private.next_stock_number(p_kind), p_kind, v_supplier_id,
    private.input_text(p_input->'source_note', 'Nomor nota', 120), v_source_date, v_actor,
    private.input_text(p_input->'reason', 'Keterangan', 500), v_op)
  returning * into v_doc;

  v_idx := 0;
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_idx := v_idx + 1;
    v_lines := v_lines || private.inbound_line(v_doc, v_idx, v_line, v_costs[v_idx], p_kind, v_actor, v_op);
  end loop;

  if p_kind = 'RECEIPT' and v_total > 0 then
    if v_method = 'CASH' then
      insert into private.cash_movements(session_id, direction, kind, amount, stock_document_id, reason, actor_id, operation_id)
      values (v_session.id, 'OUT', 'PURCHASE', v_total, v_doc.id, 'Pembelian ' || v_doc.number, v_actor, v_op)
      returning id into v_movement;
    elsif v_method = 'SUPPLIER_CREDIT' then
      insert into private.supplier_credit_entries(supplier_id, direction, amount, stock_document_id, actor_id, operation_id)
      values (v_supplier_id, 'OUT', v_total, v_doc.id, v_actor, v_op)
      returning id into v_credit;
    end if;
    insert into private.purchase_payments(stock_document_id, method, amount, confirmed_by, cashbox_id,
      cash_movement_id, credit_entry_id, reference, actor_id)
    values (v_doc.id, v_method, v_total, v_actor, v_cashbox, v_movement, v_credit,
      private.input_text(v_payment->'reference', 'Referensi', 120), v_actor);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'POST_' || p_kind, 'STOCK_DOCUMENT', v_doc.id, v_doc.reason);

  return private.finish_operation(v_command, p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_doc.id, 'document_number', v_doc.number,
    'total_cost', v_total::text, 'payment_method', v_method, 'cashbox', v_cashbox,
    'cash_session_id', v_session.id, 'lines', v_lines,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function private.post_inbound(jsonb, text) from public, anon, authenticated;

create or replace function public.post_opening_stock_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return private.post_inbound(p_input, 'OPENING'); end $$;
create or replace function public.post_stock_receipt_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return private.post_inbound(p_input, 'RECEIPT'); end $$;
revoke all on function public.post_opening_stock_v1(jsonb), public.post_stock_receipt_v1(jsonb) from public, anon, authenticated;
grant execute on function public.post_opening_stock_v1(jsonb), public.post_stock_receipt_v1(jsonb) to authenticated;
