-- AT-08: deteksi harga berubah (PRICE_CHANGED) pada finalisasi penjualan.
-- Server tetap otoritatif membaca harga dari DB; klien mengirim versi satuan
-- yang dilihat. Bila berbeda, operasi ditolak agar user meninjau ulang.

create or replace function public.finalize_sale_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_item_count integer;
  v_invoice_id uuid;
  v_number text;
  v_session_id uuid;

  v_line jsonb;
  v_unit private.product_units%rowtype;
  v_product private.products%rowtype;
  v_qty_sell numeric(18,3);
  v_qty_base numeric(18,3);
  v_price numeric(24,6);
  v_gross numeric(20,0);
  v_line_disc_mode text;
  v_line_disc_val numeric(24,6);
  v_line_discount numeric(20,0);
  v_base_net numeric(20,0);

  v_inv_disc_mode text;
  v_inv_disc_val numeric(24,6);
  v_subtotal numeric(20,0) := 0;
  v_invoice_discount numeric(20,0) := 0;
  v_total numeric(20,0) := 0;

  v_base_arr numeric[] := '{}';
  v_alloc_arr numeric[] := '{}';
  v_rem_arr numeric[] := '{}';
  v_floor_sum numeric(20,0) := 0;
  v_remainder integer := 0;
  v_i integer;
  v_j integer;
  v_pick integer;
  v_best numeric;
  v_used boolean[];
  v_alloc numeric(20,0);

  v_line_no integer := 0;
  v_pos private.stock_positions%rowtype;
  v_cost numeric(24,6);
  v_item private.invoice_items%rowtype;
  v_payment_id uuid;
  v_method text;
  v_tendered numeric(20,0);
  v_change numeric(20,0) := 0;
  v_confirmed boolean;
  v_qty_left numeric(18,3);
  v_shop_total numeric(18,3);
  v_expected_version integer;
  v_result jsonb;
begin
  v_old := private.operation_result('finalize_sale_v1', p_input);
  if v_old is not null then return v_old; end if;

  if jsonb_typeof(p_input->'items') <> 'array' then
    raise exception 'Daftar barang wajib' using errcode='22023';
  end if;
  v_item_count := jsonb_array_length(p_input->'items');
  if v_item_count < 1 or v_item_count > 100 then
    raise exception 'Daftar barang wajib (1-100 baris)' using errcode='22023';
  end if;

  v_inv_disc_mode := p_input->>'discount_mode';
  v_inv_disc_val := coalesce((p_input->>'discount_value')::numeric, 0);
  if v_inv_disc_mode = 'percent' then
    if v_inv_disc_val < 0 or v_inv_disc_val > 100 then
      raise exception 'Diskon nota di luar 0-100' using errcode='22023';
    end if;
  elsif v_inv_disc_mode = 'amount' then
    if v_inv_disc_val < 0 then
      raise exception 'Diskon nota tidak boleh negatif' using errcode='22023';
    end if;
  elsif v_inv_disc_mode is not null and v_inv_disc_mode <> '' then
    raise exception 'Mode diskon tidak dikenal' using errcode='22023';
  end if;

  perform 1 from private.products p
    join private.product_units u on u.product_id = p.id
    where u.id in (select (x->>'product_unit_id')::uuid from jsonb_array_elements(p_input->'items') x)
    order by p.id for update;

  -- PASS 1: validasi, cek versi harga, hitung base_net
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    select * into v_unit from private.product_units where id=(v_line->>'product_unit_id')::uuid and active;
    if not found then
      -- Satuan lama dinonaktifkan karena harga/opsi berubah → minta tinjau ulang
      if exists (select 1 from private.product_units where id=(v_line->>'product_unit_id')::uuid) then
        raise exception 'PRICE_CHANGED: harga/satuan berubah sejak keranjang dibuat' using errcode='40001';
      end if;
      raise exception 'Satuan tidak ditemukan atau tidak aktif' using errcode='22023';
    end if;
    select * into v_product from private.products where id=v_unit.product_id and active;
    if not found then raise exception 'Produk diarsip' using errcode='22023'; end if;

    -- PRICE_CHANGED: bila klien mengirim versi satuan, harus cocok
    if (v_line ? 'expected_unit_version') then
      v_expected_version := (v_line->>'expected_unit_version')::integer;
      if v_unit.version <> v_expected_version then
        raise exception 'PRICE_CHANGED: harga/satuan berubah sejak keranjang dibuat'
          using errcode = '40001';
      end if;
    end if;

    v_qty_sell := private.decimal_input(v_line->'qty', 3, 999999999.999);
    v_qty_base := v_qty_sell * v_unit.factor_base;
    if mod(v_qty_sell, v_unit.sale_step) <> 0 or round(v_qty_base,3) <> v_qty_base
       or mod(v_qty_base, v_product.quantity_step) <> 0 then
      raise exception 'Kuantitas tidak memenuhi langkah jual' using errcode='22023';
    end if;

    if v_product.track_segments then
      v_qty_left := v_qty_base;
      for v_pos in select * from private.stock_positions s
          join private.inventory_lots l on l.id = s.lot_id
          where l.product_id = v_product.id
          and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0
          order by l.posted_at, l.id, s.id loop
        if v_pos.sealed then
          if v_pos.qty_base = v_qty_left then v_qty_left := 0; exit; end if;
        else
          if v_pos.qty_base >= v_qty_left then v_qty_left := 0; exit;
          else v_qty_left := v_qty_left - v_pos.qty_base; end if;
        end if;
      end loop;
      if v_qty_left > 0 then raise exception 'INSUFFICIENT_STOCK' using errcode='22023'; end if;
    else
      select coalesce(sum(s.qty_base), 0) into v_shop_total
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'SHOP' and s.condition = 'SALEABLE';
      if v_shop_total < v_qty_base then raise exception 'INSUFFICIENT_STOCK' using errcode='22023'; end if;
    end if;

    v_price := v_unit.sell_price;
    v_gross := round(v_qty_sell * v_price, 0);

    v_line_disc_mode := v_line->>'discount_mode';
    v_line_disc_val := coalesce((v_line->>'discount_value')::numeric, 0);
    if v_line_disc_mode = 'percent' then
      if v_line_disc_val < 0 or v_line_disc_val > 100 then
        raise exception 'Diskon baris di luar 0-100' using errcode='22023';
      end if;
      v_line_discount := round(v_gross * v_line_disc_val / 100, 0);
    elsif v_line_disc_mode = 'amount' then
      v_line_discount := round(v_line_disc_val, 0);
    elsif v_line_disc_mode is null or v_line_disc_mode = '' then
      v_line_discount := 0;
    else
      raise exception 'Mode diskon baris tidak dikenal' using errcode='22023';
    end if;
    if v_line_discount < 0 or v_line_discount > v_gross then
      raise exception 'Diskon baris melebihi nilai' using errcode='22023';
    end if;

    v_base_net := v_gross - v_line_discount;
    v_subtotal := v_subtotal + v_base_net;
    v_base_arr := v_base_arr || v_base_net;
  end loop;

  if v_inv_disc_mode = 'percent' then
    v_invoice_discount := round(v_subtotal * v_inv_disc_val / 100, 0);
  elsif v_inv_disc_mode = 'amount' then
    v_invoice_discount := round(v_inv_disc_val, 0);
  else
    v_invoice_discount := 0;
  end if;
  if v_invoice_discount > v_subtotal then
    raise exception 'Diskon nota melebihi subtotal' using errcode='22023';
  end if;
  v_total := v_subtotal - v_invoice_discount;

  v_alloc_arr := '{}';
  v_rem_arr := '{}';
  v_floor_sum := 0;
  for v_i in 1..v_item_count loop
    if v_subtotal > 0 then
      v_alloc := (v_invoice_discount * v_base_arr[v_i]) / v_subtotal;
      v_rem_arr := v_rem_arr || ((v_invoice_discount * v_base_arr[v_i]) % v_subtotal);
    else
      v_alloc := 0;
      v_rem_arr := v_rem_arr || 0;
    end if;
    v_alloc_arr := v_alloc_arr || v_alloc;
    v_floor_sum := v_floor_sum + v_alloc;
  end loop;
  v_remainder := v_invoice_discount - v_floor_sum;
  v_used := array_fill(false, array[v_item_count]);
  for v_j in 1..v_remainder loop
    v_pick := 0;
    v_best := -1;
    for v_i in 1..v_item_count loop
      if not v_used[v_i] and v_rem_arr[v_i] > v_best then
        v_best := v_rem_arr[v_i];
        v_pick := v_i;
      end if;
    end loop;
    if v_pick > 0 then
      v_used[v_pick] := true;
      v_alloc_arr[v_pick] := v_alloc_arr[v_pick] + 1;
    end if;
  end loop;

  v_number := private.next_invoice_number('SALE');
  insert into private.invoices(number, kind, actor_id, subtotal_net_lines,
    discount_total, total, customer_id, client_reference_id, operation_id)
  values (v_number, 'SALE', v_actor, v_subtotal,
    v_invoice_discount, v_total,
    nullif(p_input->>'customer_id','')::uuid,
    nullif(p_input->>'client_reference_id','')::uuid,
    (p_input->>'operation_id')::uuid)
  returning id into v_invoice_id;

  v_line_no := 0;
  for v_line in select value from jsonb_array_elements(p_input->'items') loop
    v_line_no := v_line_no + 1;
    select * into v_unit from private.product_units where id=(v_line->>'product_unit_id')::uuid;
    select * into v_product from private.products where id=v_unit.product_id;

    v_qty_sell := private.decimal_input(v_line->'qty', 3, 999999999.999);
    v_qty_base := v_qty_sell * v_unit.factor_base;
    v_price := v_unit.sell_price;
    v_gross := round(v_qty_sell * v_price, 0);

    v_line_disc_mode := v_line->>'discount_mode';
    v_line_disc_val := coalesce((v_line->>'discount_value')::numeric, 0);
    v_base_net := v_base_arr[v_line_no];
    v_alloc := v_alloc_arr[v_line_no];

    insert into private.invoice_items(invoice_id, line_no, kind, product_id,
      description_snapshot, qty_sell, factor_snapshot, qty_base,
      unit_price_snapshot, item_discount_mode, item_discount_value,
      gross_exact, base_net, invoice_discount_alloc, net_total)
    values (v_invoice_id, v_line_no, 'PRODUCT', v_product.id,
      v_product.name || ' (' || v_unit.label || ')', v_qty_sell, v_unit.factor_base, v_qty_base,
      v_price, v_line_disc_mode, v_line_disc_val,
      v_gross::numeric(38,9), v_base_net, v_alloc, v_base_net - v_alloc)
    returning * into v_item;

    for v_pos in select * from private.stock_positions s
        join private.inventory_lots l on l.id = s.lot_id
        where l.product_id = v_product.id
        and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0
        order by l.posted_at, l.id, s.id loop
      if v_pos.qty_base >= v_qty_base then
        v_cost := private.cost_for_exit_lot(v_pos.lot_id, v_qty_base);
        update private.stock_positions set qty_base = qty_base - v_qty_base,
          sealed = false, version = version + 1 where id = v_pos.id;
        update private.inventory_lots set remaining_qty = remaining_qty - v_qty_base,
          remaining_cost = remaining_cost - v_cost, version = version + 1
          where id = v_pos.lot_id;
        insert into private.cost_allocations(lot_id, origin_position_id, invoice_item_id,
          qty_base, cost_amount, occurred_at)
        values (v_pos.lot_id, v_pos.id, v_item.id, v_qty_base, v_cost, now());
        insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta,
          kind, invoice_item_id, actor_id, operation_id)
        values (v_invoice_id, v_pos.lot_id, v_pos.id, -v_qty_base, -v_cost,
          'SALE_OUT', v_item.id, v_actor, (p_input->>'operation_id')::uuid);
        exit;
      else
        v_cost := private.cost_for_exit_lot(v_pos.lot_id, v_pos.qty_base);
        update private.stock_positions set qty_base = 0, sealed = false,
          version = version + 1 where id = v_pos.id;
        update private.inventory_lots set remaining_qty = remaining_qty - v_pos.qty_base,
          remaining_cost = remaining_cost - v_cost, version = version + 1
          where id = v_pos.lot_id;
        insert into private.cost_allocations(lot_id, origin_position_id, invoice_item_id,
          qty_base, cost_amount, occurred_at)
        values (v_pos.lot_id, v_pos.id, v_item.id, v_pos.qty_base, v_cost, now());
        insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta,
          kind, invoice_item_id, actor_id, operation_id)
        values (v_invoice_id, v_pos.lot_id, v_pos.id, -v_pos.qty_base, -v_cost,
          'SALE_OUT', v_item.id, v_actor, (p_input->>'operation_id')::uuid);
        v_qty_base := v_qty_base - v_pos.qty_base;
      end if;
    end loop;
  end loop;

  v_method := p_input->'payment'->>'method';
  if v_total = 0 then
    null;
  elsif v_method = 'CASH' then
    select id into v_session_id from private.cash_sessions
      where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'
      order by opened_at desc limit 1 for update;
    if not found then raise exception 'CASH_SESSION_CLOSED' using errcode='40001'; end if;

    v_tendered := private.decimal_input(p_input->'payment'->'tendered', 0, 9999999999999999, false);
    if v_tendered < v_total then raise exception 'Uang tunai kurang dari total' using errcode='22023'; end if;
    v_change := v_tendered - v_total;

    insert into private.payments(direction, purpose, invoice_id, method, amount,
      tendered, change, cash_session_id, actor_id, operation_id, intent_id)
    values ('IN', 'SALE_RECEIPT', v_invoice_id, 'CASH', v_total,
      v_tendered, v_change, v_session_id, v_actor,
      (p_input->>'operation_id')::uuid, nullif(p_input->>'payment_intent_id','')::uuid)
    returning id into v_payment_id;

    insert into private.cash_movements(session_id, direction, kind, amount,
      payment_id, actor_id, operation_id)
    values (v_session_id, 'IN', 'CUSTOMER_PAYMENT', v_total,
      v_payment_id, v_actor, (p_input->>'operation_id')::uuid);

  elsif v_method in ('TRANSFER', 'QRIS') then
    v_confirmed := (p_input->'payment'->>'confirmed')::boolean;
    if coalesce(v_confirmed, false) <> true then
      raise exception 'Pembayaran non-tunai harus dikonfirmasi petugas' using errcode='22023';
    end if;

    insert into private.payments(direction, purpose, invoice_id, method, amount,
      cash_session_id, actor_id, operation_id, intent_id)
    values ('IN', 'SALE_RECEIPT', v_invoice_id, v_method, v_total,
      null, v_actor, (p_input->>'operation_id')::uuid,
      nullif(p_input->>'payment_intent_id','')::uuid)
    returning id into v_payment_id;
  else
    raise exception 'Metode bayar tidak dikenal' using errcode='22023';
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'SALE_FINALIZE', 'INVOICE', v_invoice_id, p_input->>'reason');

  v_result := jsonb_build_object(
    'ok', true, 'entity_id', v_invoice_id,
    'document_number', v_number, 'operation_id', p_input->>'operation_id',
    'server_time', now(), 'subtotal', v_subtotal::text,
    'discount', v_invoice_discount::text,
    'total', v_total::text, 'change', coalesce(v_change::text, '0'));
  return private.finish_operation('finalize_sale_v1', p_input, v_result);
end $$;
revoke all on function public.finalize_sale_v1(jsonb) from public,anon,authenticated;
grant execute on function public.finalize_sale_v1(jsonb) to authenticated;
