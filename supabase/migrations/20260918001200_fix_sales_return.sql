-- Perbaikan audit 2026-09: retur penjualan (BR-05, BR-07, BR-08).
-- Menutup K06 (modal dibalik kumulatif per alokasi asal), T07 (NONE tanpa
-- pembalikan modal, retur pecahan, nota T=0), K11 (refund_method wajib,
-- kas terkunci + cek saldo, alokasi ke receipt yang masih bersaldo).

create or replace function public.return_sale_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_op uuid;
  v_reason text;
  v_method text;
  v_reference text;
  v_invoice private.invoices%rowtype;
  v_session private.cash_sessions%rowtype;
  v_line jsonb;
  v_alloc_in jsonb;
  v_no integer := 0;
  v_item private.invoice_items%rowtype;
  v_product private.products%rowtype;
  v_item_ids uuid[] := '{}';
  v_item_id uuid;
  v_qty numeric;
  v_already numeric;
  v_disposition text;
  v_label text;
  v_amount numeric;
  v_total numeric := 0;
  v_plan jsonb := '[]'::jsonb;
  v_chosen jsonb;
  v_ca record;
  v_ca_id uuid;
  v_take numeric;
  v_left numeric;
  v_sum numeric;
  v_rev_old numeric;
  v_rev_delta numeric;
  v_cost_total numeric;
  v_k integer;
  v_credit_id uuid;
  v_credit_number text;
  v_credit_item_id uuid;
  v_pos_id uuid;
  v_pos_label text;
  v_positions jsonb;
  v_items_out jsonb := '[]'::jsonb;
  v_receipt record;
  v_available numeric;
  v_refund_left numeric;
  v_refund_id uuid;
  v_first_receipt uuid;
  v_result jsonb;
begin
  v_old := private.sales_begin_command('return_sale_v1', p_input, array['OWNER']);
  if v_old is not null then return v_old; end if;
  v_op := (p_input->>'operation_id')::uuid;

  perform private.sales_reject_unknown(p_input, array['operation_id', 'invoice_id', 'reason', 'refund_method',
    'refund_reference', 'items'], 'retur');
  v_reason := private.sales_text_input(p_input->'reason', 'Alasan retur', 500, true);
  v_reference := private.sales_text_input(p_input->'refund_reference', 'Referensi refund', 100);
  if p_input->'refund_method' is not null and jsonb_typeof(p_input->'refund_method') <> 'null' then
    v_method := p_input->>'refund_method';
    if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS') then
      raise exception 'INVALID_INPUT: Metode refund harus CASH, TRANSFER, atau QRIS' using errcode = '22023';
    end if;
  end if;
  if p_input->'items' is null or jsonb_typeof(p_input->'items') <> 'array'
     or jsonb_array_length(p_input->'items') not between 1 and 100 then
    raise exception 'INVALID_INPUT: Daftar barang retur wajib (1-100 baris)' using errcode = '22023';
  end if;

  -- Kunci akar dokumen: nota. Semua retur nota yang sama berurutan.
  select * into v_invoice from private.invoices
    where id = private.sales_uuid_input(p_input->'invoice_id', 'Nota') for update;
  if not found then
    raise exception 'NOT_FOUND: Nota tidak ditemukan' using errcode = '22023';
  end if;
  if v_invoice.kind <> 'SALE' then
    raise exception 'INVALID_INPUT: Retur ini hanya untuk nota penjualan barang' using errcode = '22023';
  end if;

  -- Tahap 1: validasi baris dan hitung hak refund H(x) kumulatif per baris.
  for v_line in select e from jsonb_array_elements(p_input->'items') with ordinality t(e, n) order by n loop
    v_no := v_no + 1;
    perform private.sales_reject_unknown(v_line, array['invoice_item_id', 'qty_base', 'disposition',
      'allocations', 'label'], 'baris retur ' || v_no);
    v_item_id := private.sales_uuid_input(v_line->'invoice_item_id', 'Baris nota ' || v_no);
    if v_item_id = any (v_item_ids) then
      raise exception 'INVALID_INPUT: Baris nota yang sama tidak boleh diretur dua kali dalam satu retur'
        using errcode = '22023';
    end if;
    v_item_ids := v_item_ids || v_item_id;
    select * into v_item from private.invoice_items where id = v_item_id and invoice_id = v_invoice.id;
    if not found then
      raise exception 'NOT_FOUND: Baris nota % tidak ditemukan pada nota ini', v_no using errcode = '22023';
    end if;
    if v_item.kind <> 'PRODUCT' or v_item.product_id is null then
      raise exception 'INVALID_INPUT: Baris % bukan barang yang dapat diretur', v_no using errcode = '22023';
    end if;
    select * into v_product from private.products where id = v_item.product_id;

    v_disposition := v_line->>'disposition';
    if v_disposition is null or v_disposition not in ('SALEABLE', 'DAMAGED', 'NONE') then
      raise exception 'INVALID_INPUT: Kondisi barang retur baris % wajib dipilih (SALEABLE/DAMAGED/NONE)', v_no
        using errcode = '22023';
    end if;
    v_qty := private.decimal_input(v_line->'qty_base', 3, 999999999.999);
    if mod(v_qty, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_QUANTITY: Jumlah retur "%" harus kelipatan % %', v_product.name,
        trim_scale(v_product.quantity_step)::text, v_product.base_unit using errcode = '22023';
    end if;
    v_label := private.sales_text_input(v_line->'label', 'Label posisi retur', 50);
    if v_label is not null and (not v_product.track_segments or v_disposition = 'NONE') then
      raise exception 'INVALID_INPUT: Label posisi hanya untuk retur roll/potongan yang kembali ke stok'
        using errcode = '22023';
    end if;
    if v_line ? 'allocations' and v_disposition = 'NONE' then
      raise exception 'INVALID_INPUT: Pilihan alokasi tidak berlaku untuk barang yang tidak kembali'
        using errcode = '22023';
    end if;

    select coalesce(sum(cni.qty_return_base), 0) into v_already
      from private.credit_note_items cni where cni.invoice_item_id = v_item.id;
    if v_already + v_qty > v_item.qty_base then
      raise exception 'REFUND_LIMIT_EXCEEDED: Jumlah retur "%" melebihi sisa yang dapat diretur (% %)',
        v_product.name, trim_scale(v_item.qty_base - v_already)::text, v_product.base_unit
        using errcode = '22023';
    end if;

    v_amount := private.sales_ratio_half_up(v_item.net_total, v_already + v_qty, v_item.qty_base, 0)
      - private.sales_ratio_half_up(v_item.net_total, v_already, v_item.qty_base, 0);
    v_total := v_total + v_amount;
    v_plan := v_plan || jsonb_build_object('line_no', v_no, 'item_id', v_item.id, 'qty', v_qty,
      'amount', v_amount, 'disposition', v_disposition, 'label', v_label,
      'track_segments', v_product.track_segments, 'product_id', v_product.id,
      'allocations', v_line->'allocations');
  end loop;

  if v_total > 0 and v_method is null then
    raise exception 'INVALID_INPUT: Metode refund wajib dipilih' using errcode = '22023';
  end if;

  -- Urutan kunci: nota -> sesi kas -> produk -> lot -> alokasi -> pembayaran asal.
  if v_total > 0 and v_method = 'CASH' then
    v_session := private.lock_open_cash_session('SHOP_DRAWER');
  end if;
  perform 1 from private.products where id in
    (select (e->>'product_id')::uuid from jsonb_array_elements(v_plan) e) order by id for update;
  perform 1 from private.inventory_lots where id in
    (select ca.lot_id from private.cost_allocations ca where ca.invoice_item_id = any (v_item_ids))
    order by id for update;
  perform 1 from private.cost_allocations where invoice_item_id = any (v_item_ids) order by id for update;

  -- Receipt asal/pengganti yang masih bersaldo (BR-07).
  perform 1 from private.payments p
    where p.invoice_id = v_invoice.id and p.direction = 'IN'
      and p.purpose in ('SALE_RECEIPT', 'PAYMENT_REPLACEMENT')
    order by p.id for update;
  select coalesce(sum(r.balance), 0) into v_available from (
    select p.amount - coalesce((select sum(ra.amount) from private.refund_allocations ra
      where ra.original_payment_id = p.id), 0) as balance
    from private.payments p
    where p.invoice_id = v_invoice.id and p.direction = 'IN'
      and p.purpose in ('SALE_RECEIPT', 'PAYMENT_REPLACEMENT')
      and not exists (select 1 from private.payments rv
        where rv.original_payment_id = p.id and rv.purpose = 'PAYMENT_REVERSAL')) r;
  if v_total > v_available then
    raise exception 'REFUND_LIMIT_EXCEEDED: Refund melebihi uang yang masih dapat dikembalikan untuk nota ini'
      using errcode = '22023';
  end if;
  if v_total > 0 and v_method = 'CASH' and private.cash_session_expected(v_session.id) < v_total then
    raise exception 'INSUFFICIENT_CASH: Saldo laci toko tidak cukup untuk refund tunai' using errcode = '22023';
  end if;

  -- Tahap 2: tulis credit note, stok, modal.
  v_credit_number := private.next_credit_number();
  insert into private.credit_notes(number, invoice_id, kind, reason, total, actor_id, operation_id)
  values (v_credit_number, v_invoice.id, 'RETURN', v_reason, v_total, v_actor, v_op)
  returning id into v_credit_id;

  for v_line in select e from jsonb_array_elements(v_plan) with ordinality t(e, n) order by n loop
    v_qty := (v_line->>'qty')::numeric;
    v_disposition := v_line->>'disposition';
    v_item_id := (v_line->>'item_id')::uuid;
    v_cost_total := 0;
    v_positions := '[]'::jsonb;

    insert into private.credit_note_items(credit_note_id, invoice_item_id, qty_return_base, amount,
      cost_reversal_amount, disposition, line_no)
    values (v_credit_id, v_item_id, v_qty, (v_line->>'amount')::numeric, 0, v_disposition,
      (v_line->>'line_no')::integer)
    returning id into v_credit_item_id;

    -- T07: barang tidak kembali -> tidak ada stok dan COGS tidak dibalik.
    if v_disposition <> 'NONE' then
      -- Tentukan qty per alokasi: pilihan owner atau urutan alokasi asal deterministik.
      v_chosen := '[]'::jsonb;
      if v_line->'allocations' is not null and jsonb_typeof(v_line->'allocations') <> 'null' then
        if jsonb_typeof(v_line->'allocations') <> 'array' or jsonb_array_length(v_line->'allocations') = 0 then
          raise exception 'INVALID_INPUT: Pilihan alokasi harus berupa daftar' using errcode = '22023';
        end if;
        v_sum := 0;
        for v_alloc_in in select e from jsonb_array_elements(v_line->'allocations') e loop
          perform private.sales_reject_unknown(v_alloc_in, array['cost_allocation_id', 'qty_base'], 'alokasi retur');
          v_ca_id := private.sales_uuid_input(v_alloc_in->'cost_allocation_id', 'Alokasi asal');
          v_take := private.decimal_input(v_alloc_in->'qty_base', 3, 999999999.999);
          if v_chosen @> jsonb_build_array(jsonb_build_object('id', v_ca_id)) then
            raise exception 'INVALID_INPUT: Alokasi asal dipilih dua kali' using errcode = '22023';
          end if;
          select ca.id, ca.qty_base, ca.reversed_qty into v_ca from private.cost_allocations ca
            where ca.id = v_ca_id and ca.invoice_item_id = v_item_id;
          if not found then
            raise exception 'NOT_FOUND: Alokasi asal bukan milik baris nota ini' using errcode = '22023';
          end if;
          if mod(v_take, (select quantity_step from private.products where id = (v_line->>'product_id')::uuid)) <> 0 then
            raise exception 'INVALID_QUANTITY: Jumlah alokasi retur tidak sesuai langkah stok' using errcode = '22023';
          end if;
          if v_take > v_ca.qty_base - v_ca.reversed_qty then
            raise exception 'REFUND_LIMIT_EXCEEDED: Jumlah melebihi sisa alokasi asal yang dapat dikembalikan'
              using errcode = '22023';
          end if;
          v_sum := v_sum + v_take;
          v_chosen := v_chosen || jsonb_build_array(jsonb_build_object('id', v_ca_id, 'qty', v_take));
        end loop;
        if v_sum <> v_qty then
          raise exception 'INVALID_INPUT: Jumlah pilihan alokasi harus sama dengan jumlah retur' using errcode = '22023';
        end if;
      else
        v_left := v_qty;
        for v_ca in
          select ca.id, ca.qty_base, ca.reversed_qty
          from private.cost_allocations ca join private.inventory_lots l on l.id = ca.lot_id
          where ca.invoice_item_id = v_item_id and ca.reversed_qty < ca.qty_base
          order by l.posted_at, l.id, ca.origin_position_id, ca.id
        loop
          exit when v_left = 0;
          v_take := least(v_left, v_ca.qty_base - v_ca.reversed_qty);
          v_chosen := v_chosen || jsonb_build_array(jsonb_build_object('id', v_ca.id, 'qty', v_take));
          v_left := v_left - v_take;
        end loop;
        if v_left <> 0 then
          raise exception 'REFUND_LIMIT_EXCEEDED: Sisa alokasi modal baris ini tidak cukup untuk retur fisik'
            using errcode = '22023';
        end if;
      end if;

      v_k := 0;
      for v_alloc_in in select e from jsonb_array_elements(v_chosen) with ordinality t(e, n) order by n loop
        v_k := v_k + 1;
        v_take := (v_alloc_in->>'qty')::numeric;
        select * into v_ca from private.cost_allocations where id = (v_alloc_in->>'id')::uuid;
        -- K06: C_rev(x) = round_half_up(C×x/Q, 6) kumulatif, C_rev(Q) = C.
        v_rev_old := v_ca.reversed_cost;
        v_rev_delta := private.sales_ratio_half_up(v_ca.cost_amount, v_ca.reversed_qty + v_take, v_ca.qty_base, 6)
          - private.sales_ratio_half_up(v_ca.cost_amount, v_ca.reversed_qty, v_ca.qty_base, 6);
        update private.cost_allocations
          set reversed_qty = reversed_qty + v_take, reversed_cost = reversed_cost + v_rev_delta
          where id = v_ca.id;

        if (v_line->>'track_segments')::boolean then
          v_pos_label := coalesce(v_line->>'label', v_credit_number || '-' || (v_line->>'line_no'));
          if jsonb_array_length(v_chosen) > 1 then v_pos_label := v_pos_label || '-' || v_k; end if;
          if exists (select 1 from private.stock_positions where label = v_pos_label) then
            raise exception 'INVALID_INPUT: Label posisi "%" sudah dipakai', v_pos_label using errcode = '22023';
          end if;
        else
          v_pos_label := null;
        end if;

        -- Potongan kembali selalu posisi baru, tidak disambung ke roll asal (BR-03).
        insert into private.stock_positions(lot_id, location, condition, qty_base, label, segment_capacity, sealed)
        values (v_ca.lot_id, 'SHOP', v_disposition, v_take, v_pos_label,
          case when (v_line->>'track_segments')::boolean then v_take end, false)
        returning id into v_pos_id;
        update private.inventory_lots
          set remaining_qty = remaining_qty + v_take, remaining_cost = remaining_cost + v_rev_delta,
              version = version + 1
          where id = v_ca.lot_id;
        insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
          invoice_item_id, actor_id, operation_id)
        values (v_credit_id, v_ca.lot_id, v_pos_id, v_take, v_rev_delta, 'RETURN_IN', v_item_id, v_actor, v_op);
        insert into private.return_cost_allocations(credit_item_id, original_cost_allocation_id, qty_base,
          cost_amount, target_position_id)
        values (v_credit_item_id, v_ca.id, v_take, v_rev_delta, v_pos_id);

        v_cost_total := v_cost_total + v_rev_delta;
        v_positions := v_positions || jsonb_build_object('position_id', v_pos_id, 'label', v_pos_label,
          'qty_base', v_take::text, 'condition', v_disposition);
      end loop;

      update private.credit_note_items set cost_reversal_amount = v_cost_total where id = v_credit_item_id;
    end if;

    v_items_out := v_items_out || jsonb_build_object('invoice_item_id', v_item_id,
      'qty_base', v_qty::text, 'amount', v_line->>'amount', 'disposition', v_disposition,
      'cost_reversal', v_cost_total::text, 'positions', v_positions);
  end loop;

  -- Tahap 3: refund uang, dialokasikan ke receipt yang masih bersaldo.
  if v_total > 0 then
    insert into private.payments(direction, purpose, invoice_id, method, amount, cash_session_id, reference,
      confirmed_by, actor_id, operation_id)
    values ('OUT', 'CUSTOMER_REFUND', v_invoice.id, v_method, v_total,
      case when v_method = 'CASH' then v_session.id end, v_reference, v_actor, v_actor, v_op)
    returning id into v_refund_id;

    v_refund_left := v_total;
    for v_receipt in
      select p.id, p.amount - coalesce((select sum(ra.amount) from private.refund_allocations ra
        where ra.original_payment_id = p.id), 0) as balance
      from private.payments p
      where p.invoice_id = v_invoice.id and p.direction = 'IN'
        and p.purpose in ('SALE_RECEIPT', 'PAYMENT_REPLACEMENT')
        and not exists (select 1 from private.payments rv
          where rv.original_payment_id = p.id and rv.purpose = 'PAYMENT_REVERSAL')
      order by p.occurred_at, p.id
    loop
      exit when v_refund_left = 0;
      continue when v_receipt.balance <= 0;
      v_take := least(v_receipt.balance, v_refund_left);
      insert into private.refund_allocations(refund_payment_id, original_payment_id, amount, credit_note_id)
      values (v_refund_id, v_receipt.id, v_take, v_credit_id);
      v_first_receipt := coalesce(v_first_receipt, v_receipt.id);
      v_refund_left := v_refund_left - v_take;
    end loop;
    if v_refund_left <> 0 then
      raise exception 'REFUND_LIMIT_EXCEEDED: Refund melebihi penerimaan nota' using errcode = '22023';
    end if;
    update private.payments set original_payment_id = v_first_receipt where id = v_refund_id;

    if v_method = 'CASH' then
      insert into private.cash_movements(session_id, direction, kind, amount, payment_id, reason, actor_id, operation_id)
      values (v_session.id, 'OUT', 'REFUND', v_total, v_refund_id, v_reason, v_actor, v_op);
    end if;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RETURN_SALE', 'CREDIT_NOTE', v_credit_id, v_reason);

  v_result := jsonb_build_object('ok', true, 'entity_id', v_credit_id, 'document_number', v_credit_number,
    'invoice_id', v_invoice.id, 'refund_total', v_total::text, 'refund_payment_id', v_refund_id,
    'refund_method', case when v_total > 0 then v_method end, 'items', v_items_out,
    'operation_id', v_op, 'server_time', now(), 'schema_version', 2);
  return private.finish_operation('return_sale_v1', p_input, v_result);
end $$;
revoke all on function public.return_sale_v1(jsonb) from public, anon, authenticated;
grant execute on function public.return_sale_v1(jsonb) to authenticated;
