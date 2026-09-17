-- Perbaikan audit 2026-09: penjualan barang.
-- Menutup K01 (peran), K02 (diskon staff / nota nol), K04 (baris ganda),
-- K05 (roll BR-03 dengan posisi fisik pilihan), S01 (BR-04 eksak),
-- S09 (tunai wajib tendered, sesi kas terkunci), idempotensi.

-- Diskon (baris atau nota). STAFF tidak boleh mengirim diskon apa pun.
create or replace function private.sales_discount_input(
  p_mode jsonb, p_value jsonb, p_role text, p_context text)
returns table(mode text, value numeric)
language plpgsql immutable set search_path = '' as $$
declare v_mode text; v_has_value boolean;
begin
  if p_mode is not null and jsonb_typeof(p_mode) not in ('string', 'null') then
    raise exception 'INVALID_INPUT: Mode diskon % tidak sah', p_context using errcode = '22023';
  end if;
  v_mode := nullif(trim(coalesce(p_mode #>> '{}', '')), '');
  v_has_value := p_value is not null and jsonb_typeof(p_value) <> 'null'
    and not (jsonb_typeof(p_value) = 'string' and trim(p_value #>> '{}') = '');
  if v_mode is null and not v_has_value then
    return query select null::text, null::numeric;
    return;
  end if;
  if p_role is distinct from 'OWNER' then
    raise exception 'FORBIDDEN: Hanya owner yang boleh memberi diskon' using errcode = '42501';
  end if;
  if v_mode is null then
    raise exception 'INVALID_INPUT: Mode diskon % wajib dipilih', p_context using errcode = '22023';
  elsif v_mode = 'percent' then
    return query select v_mode, private.decimal_input(p_value, 4, 100, false);
  elsif v_mode = 'amount' then
    return query select v_mode, private.decimal_input(p_value, 0, 9999999999999999, false);
  else
    raise exception 'INVALID_INPUT: Mode diskon % tidak dikenal (percent/amount)', p_context using errcode = '22023';
  end if;
end $$;
revoke all on function private.sales_discount_input(jsonb, jsonb, text, text) from public, anon, authenticated;

-- Hitung harga keranjang menurut BR-04 dari data server. Tidak menulis apa pun.
-- Hasil (jsonb, angka eksak):
--   lines[]: line_no, product_id, product_unit_id, unit_version, product_name, unit_label,
--            factor_base, track_segments, qty_sell, qty_base, unit_price, discount_mode,
--            discount_value, gross_exact, line_discount_exact, base_net,
--            invoice_discount_alloc, net_total, position_id, expected_position_version
--   subtotal, discount_mode, discount_value, discount_total, total
create or replace function private.sales_price_cart(p_input jsonb, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_max_money constant numeric := 9999999999999999;
  v_line jsonb;
  v_no integer := 0;
  v_count integer;
  v_unit private.product_units%rowtype;
  v_product private.products%rowtype;
  v_unit_id uuid;
  v_expected integer;
  v_pos_id uuid;
  v_pos_version integer;
  v_qty numeric;
  v_base numeric;
  v_gross numeric;
  v_disc numeric;
  v_mode text;
  v_value numeric;
  v_bnet numeric;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_total numeric;
  v_inv_mode text;
  v_inv_value numeric;
  v_lines jsonb := '[]'::jsonb;
  v_final jsonb;
  v_sum_alloc numeric;
  v_sum_net numeric;
begin
  if p_input->'items' is null or jsonb_typeof(p_input->'items') <> 'array' then
    raise exception 'INVALID_INPUT: Daftar barang wajib diisi' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_input->'items');
  if v_count < 1 or v_count > 100 then
    raise exception 'INVALID_INPUT: Daftar barang harus 1-100 baris' using errcode = '22023';
  end if;

  select d.mode, d.value into v_inv_mode, v_inv_value
    from private.sales_discount_input(p_input->'discount_mode', p_input->'discount_value', p_role, 'nota') d;

  for v_line in select e from jsonb_array_elements(p_input->'items') with ordinality t(e, n) order by n loop
    v_no := v_no + 1;
    perform private.sales_reject_unknown(v_line, array['product_unit_id', 'qty', 'expected_unit_version',
      'discount_mode', 'discount_value', 'position_id', 'expected_position_version'], 'baris ' || v_no);
    v_unit_id := private.sales_uuid_input(v_line->'product_unit_id', 'Satuan barang baris ' || v_no);
    v_expected := private.sales_int_input(v_line->'expected_unit_version', 'Versi satuan baris ' || v_no);
    v_pos_id := private.sales_uuid_input(v_line->'position_id', 'Potongan/roll baris ' || v_no, false);
    v_pos_version := private.sales_int_input(v_line->'expected_position_version', 'Versi potongan baris ' || v_no);
    v_qty := private.decimal_input(v_line->'qty', 3, 999999999.999);
    select d.mode, d.value into v_mode, v_value
      from private.sales_discount_input(v_line->'discount_mode', v_line->'discount_value', p_role, 'baris ' || v_no) d;

    select * into v_unit from private.product_units where id = v_unit_id;
    if not found then
      raise exception 'NOT_FOUND: Satuan barang pada baris % tidak ditemukan', v_no using errcode = '22023';
    end if;
    select * into v_product from private.products where id = v_unit.product_id;
    if not v_product.active then
      raise exception 'NOT_FOUND: Barang "%" sudah diarsip dan tidak dapat dijual', v_product.name
        using errcode = '22023';
    end if;
    if not v_unit.active or (v_expected is not null and v_expected <> v_unit.version) then
      raise exception 'PRICE_CHANGED: Harga/satuan "% (%)" berubah sejak keranjang dibuat. Muat ulang lalu periksa keranjang.',
        v_product.name, v_unit.label
        using errcode = '40001',
          detail = coalesce((
            select jsonb_build_object('product_id', v_product.id, 'current_unit_id', u.id,
              'label', u.label, 'sell_price', u.sell_price::text, 'version', u.version)::text
            from private.product_units u
            where u.product_id = v_product.id and u.active
            order by (u.id = v_unit.id) desc, u.is_default desc, u.label limit 1), '{}');
    end if;

    if mod(v_qty, v_unit.sale_step) <> 0 then
      raise exception 'INVALID_QUANTITY: Jumlah "%" harus kelipatan % %', v_product.name,
        trim_scale(v_unit.sale_step)::text, v_unit.label using errcode = '22023';
    end if;
    v_base := v_qty * v_unit.factor_base;
    if v_base <> round(v_base, 3) or v_base > 999999999.999 or mod(v_base, v_product.quantity_step) <> 0 then
      raise exception 'INVALID_QUANTITY: Jumlah "%" tidak sesuai langkah stok %', v_product.name, v_product.base_unit
        using errcode = '22023';
    end if;

    -- BR-04 langkah 1-4: G eksak, D dari G eksak, B dibulatkan setelah diskon.
    v_gross := v_qty * v_unit.sell_price;
    if v_gross > c_max_money then
      raise exception 'INVALID_NUMBER: Nilai baris % melebihi batas', v_no using errcode = '22023';
    end if;
    v_disc := case v_mode
      when 'percent' then v_gross * v_value * 0.01
      when 'amount' then v_value
      else 0 end;
    if v_disc > v_gross then
      raise exception 'INVALID_INPUT: Diskon baris % melebihi nilai baris', v_no using errcode = '22023';
    end if;
    v_bnet := round(v_gross - v_disc, 0);
    v_subtotal := v_subtotal + v_bnet;

    v_lines := v_lines || jsonb_build_object(
      'line_no', v_no, 'product_id', v_product.id, 'product_unit_id', v_unit.id,
      'unit_version', v_unit.version, 'product_name', v_product.name, 'sku', v_product.sku,
      'unit_label', v_unit.label, 'base_unit', v_product.base_unit,
      'factor_base', v_unit.factor_base, 'track_segments', v_product.track_segments,
      'qty_sell', v_qty, 'qty_base', v_base, 'unit_price', v_unit.sell_price,
      'discount_mode', v_mode, 'discount_value', v_value,
      'gross_exact', v_gross, 'line_discount_exact', v_disc, 'base_net', v_bnet,
      'position_id', v_pos_id, 'expected_position_version', v_pos_version);
  end loop;

  if v_subtotal > c_max_money then
    raise exception 'INVALID_NUMBER: Total nota melebihi batas' using errcode = '22023';
  end if;

  -- BR-04 langkah 6-7.
  v_discount := case v_inv_mode
    when 'percent' then round(v_subtotal * v_inv_value * 0.01, 0)
    when 'amount' then v_inv_value
    else 0 end;
  if v_discount > v_subtotal then
    raise exception 'INVALID_INPUT: Diskon nota melebihi subtotal' using errcode = '22023';
  end if;
  v_total := v_subtotal - v_discount;

  -- Alokasi diskon nota: floor(D×B_i/S) lalu sisa ke remainder terbesar, seri line_no naik.
  select coalesce(jsonb_agg(x.e || jsonb_build_object(
      'invoice_discount_alloc', x.a, 'net_total', (x.e->>'base_net')::numeric - x.a) order by x.n), '[]'::jsonb),
    coalesce(sum(x.a), 0), coalesce(sum((x.e->>'base_net')::numeric - x.a), 0)
  into v_final, v_sum_alloc, v_sum_net
  from (
    select f.e, f.n,
      f.a0 + case when row_number() over (order by f.rem desc, f.n) <= v_discount - sum(f.a0) over ()
                  then 1 else 0 end as a
    from (
      select e, (e->>'line_no')::integer as n,
        case when v_subtotal > 0 then div(v_discount * (e->>'base_net')::numeric, v_subtotal) else 0 end as a0,
        case when v_subtotal > 0 then mod(v_discount * (e->>'base_net')::numeric, v_subtotal) else 0 end as rem
      from jsonb_array_elements(v_lines) e
    ) f
  ) x;

  if v_sum_alloc <> v_discount or v_sum_net <> v_total then
    raise exception 'INTERNAL_ERROR: Invariant alokasi diskon gagal' using errcode = 'XX000';
  end if;

  return jsonb_build_object('lines', v_final, 'subtotal', v_subtotal,
    'discount_mode', v_inv_mode, 'discount_value', v_inv_value,
    'discount_total', v_discount, 'total', v_total);
end $$;
revoke all on function private.sales_price_cart(jsonb, text) from public, anon, authenticated;

-- === finalize_sale_v1 =========================================================
create or replace function public.finalize_sale_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_max_money constant numeric := 9999999999999999;
  v_actor uuid := auth.uid();
  v_role text;
  v_old jsonb;
  v_op uuid;
  v_reason text;
  v_client_ref uuid;
  v_intent uuid;
  v_customer uuid;
  v_payment jsonb;
  v_method text;
  v_reference text;
  v_tendered numeric;
  v_change numeric := 0;
  v_session private.cash_sessions%rowtype;
  v_cart jsonb;
  v_line jsonb;
  v_subtotal numeric;
  v_discount numeric;
  v_total numeric;
  v_roll_pos uuid[] := '{}';
  v_bulk_products uuid[] := '{}';
  v_need record;
  v_pos record;
  v_avail numeric;
  v_existing text;
  v_invoice_id uuid;
  v_number text;
  v_item_id uuid;
  v_left numeric;
  v_take numeric;
  v_cost numeric;
  v_payment_id uuid;
  v_items_out jsonb;
  v_result jsonb;
begin
  v_old := private.sales_begin_command('finalize_sale_v1', p_input, array['OWNER', 'STAFF']);
  if v_old is not null then return v_old; end if;
  select role into v_role from private.app_profiles where id = v_actor;
  v_op := (p_input->>'operation_id')::uuid;

  perform private.sales_reject_unknown(p_input, array['operation_id', 'client_reference_id', 'customer_id',
    'items', 'discount_mode', 'discount_value', 'payment', 'reason', 'payment_intent_id'], 'penjualan');
  v_reason := private.sales_text_input(p_input->'reason', 'Alasan', 500);
  v_client_ref := private.sales_uuid_input(p_input->'client_reference_id', 'client_reference_id', false);
  v_intent := private.sales_uuid_input(p_input->'payment_intent_id', 'payment_intent_id', false);
  v_customer := private.sales_uuid_input(p_input->'customer_id', 'Pelanggan', false);

  v_payment := p_input->'payment';
  if v_payment is not null and jsonb_typeof(v_payment) <> 'null' then
    perform private.sales_reject_unknown(v_payment, array['method', 'tendered', 'confirmed', 'reference'], 'pembayaran');
    v_method := v_payment->>'method';
    if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS') then
      raise exception 'INVALID_INPUT: Metode bayar harus CASH, TRANSFER, atau QRIS' using errcode = '22023';
    end if;
    v_reference := private.sales_text_input(v_payment->'reference', 'Referensi pembayaran', 100);
  end if;

  -- Urutan kunci API-02: sesi kas -> produk -> lot -> posisi -> nomor dokumen.
  if v_method = 'CASH' then
    v_session := private.lock_open_cash_session('SHOP_DRAWER');
  end if;

  perform 1 from private.products p
    where p.id in (select u.product_id from private.product_units u
      where u.id::text in (select x->>'product_unit_id'
        from jsonb_array_elements(case when jsonb_typeof(p_input->'items') = 'array'
          then p_input->'items' else '[]'::jsonb end) x))
    order by p.id for update;

  -- Harga dibaca ulang setelah produk terkunci.
  v_cart := private.sales_price_cart(p_input, v_role);
  v_subtotal := (v_cart->>'subtotal')::numeric;
  v_discount := (v_cart->>'discount_total')::numeric;
  v_total := (v_cart->>'total')::numeric;

  -- Pembayaran (BR-07).
  if v_total = 0 then
    if v_role <> 'OWNER' then
      raise exception 'APPROVAL_REQUIRED: Nota bernilai nol hanya dapat diproses owner' using errcode = '42501';
    end if;
    if v_reason is null then
      raise exception 'APPROVAL_REQUIRED: Nota bernilai nol wajib diberi alasan' using errcode = '22023';
    end if;
    v_method := null;
  elsif v_method is null then
    raise exception 'INVALID_INPUT: Metode pembayaran wajib dipilih' using errcode = '22023';
  elsif v_method = 'CASH' then
    v_tendered := private.decimal_input(v_payment->'tendered', 0, c_max_money, false);
    if v_tendered < v_total then
      raise exception 'INSUFFICIENT_PAYMENT: Uang diterima kurang dari total belanja' using errcode = '22023';
    end if;
    v_change := v_tendered - v_total;
  else
    if (v_payment->'confirmed') is distinct from 'true'::jsonb then
      raise exception 'PAYMENT_NOT_CONFIRMED: Pembayaran % harus dikonfirmasi petugas sudah diterima', v_method
        using errcode = '22023';
    end if;
  end if;

  -- Rencana stok: roll wajib posisi pilihan; bulk tidak boleh memilih posisi.
  for v_line in select e from jsonb_array_elements(v_cart->'lines') e loop
    if (v_line->>'track_segments')::boolean then
      if v_line->>'position_id' is null then
        raise exception 'POSITION_REQUIRED: Pilih roll/potongan fisik untuk "%" (baris %)',
          v_line->>'product_name', v_line->>'line_no' using errcode = '22023';
      end if;
      v_roll_pos := v_roll_pos || (v_line->>'position_id')::uuid;
    else
      if v_line->>'position_id' is not null then
        raise exception 'INVALID_INPUT: Barang "%" tidak memakai pilihan potongan', v_line->>'product_name'
          using errcode = '22023';
      end if;
      v_bulk_products := v_bulk_products || (v_line->>'product_id')::uuid;
    end if;
  end loop;

  perform 1 from private.inventory_lots l
    where l.id in (
      select s.lot_id from private.stock_positions s where s.id = any (v_roll_pos)
      union
      select s.lot_id from private.stock_positions s
        join private.inventory_lots x on x.id = s.lot_id
        where x.product_id = any (v_bulk_products)
          and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0)
    order by l.id for update;
  perform 1 from private.stock_positions s
    where s.id = any (v_roll_pos)
       or (s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0
           and s.lot_id in (select x.id from private.inventory_lots x where x.product_id = any (v_bulk_products)))
    order by s.id for update;

  -- K05/BR-03: satu baris roll = satu posisi fisik; kebutuhan diagregasi per posisi.
  for v_need in
    select e->>'position_id' as position_id,
      sum((e->>'qty_base')::numeric) as need,
      count(*) as line_count,
      bool_or((e->>'factor_base')::numeric > 1) as whole_roll,
      max((e->>'factor_base')::numeric) as factor,
      max((e->>'qty_sell')::numeric) as qty_sell,
      min(e->>'product_id') as product_id,
      min(e->>'product_name') as product_name,
      min(e->>'base_unit') as base_unit,
      bool_or(e->>'expected_position_version' is not null) as has_version,
      min((e->>'expected_position_version')::integer) as min_version,
      max((e->>'expected_position_version')::integer) as max_version
    from jsonb_array_elements(v_cart->'lines') e
    where (e->>'track_segments')::boolean
    group by e->>'position_id'
  loop
    select s.id, s.label, s.location, s.condition, s.qty_base, s.segment_capacity, s.sealed, s.version,
      l.product_id
      into v_pos
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where s.id = v_need.position_id::uuid;
    if not found then
      raise exception 'NOT_FOUND: Potongan/roll untuk "%" tidak ditemukan', v_need.product_name using errcode = '22023';
    end if;
    if v_pos.product_id::text <> v_need.product_id then
      raise exception 'INVALID_INPUT: Potongan % bukan milik barang "%"', coalesce(v_pos.label, '-'), v_need.product_name
        using errcode = '22023';
    end if;
    if v_pos.location <> 'SHOP' or v_pos.condition <> 'SALEABLE' or v_pos.qty_base <= 0 then
      raise exception 'INSUFFICIENT_STOCK: Potongan % tidak tersedia untuk dijual (habis, rusak, atau tidak di toko)',
        coalesce(v_pos.label, '-') using errcode = '22023';
    end if;
    if v_need.has_version and (v_need.min_version <> v_pos.version or v_need.max_version <> v_pos.version) then
      raise exception 'VERSION_CONFLICT: Potongan % sudah berubah. Muat ulang daftar potongan.', coalesce(v_pos.label, '-')
        using errcode = '40001';
    end if;
    if v_need.whole_roll then
      if v_need.line_count > 1 then
        raise exception 'INVALID_INPUT: Roll % tidak boleh dipakai lebih dari satu baris', coalesce(v_pos.label, '-')
          using errcode = '22023';
      end if;
      if v_need.qty_sell <> 1 then
        raise exception 'INVALID_QUANTITY: Satu baris hanya untuk satu roll utuh; tambahkan baris per roll'
          using errcode = '22023';
      end if;
      if not v_pos.sealed or v_pos.segment_capacity <> v_need.factor or v_pos.qty_base <> v_need.factor then
        raise exception 'SEGMENT_NOT_SEALED: Roll utuh harus diambil dari roll bersegel berkapasitas % %; % tidak memenuhi',
          trim_scale(v_need.factor)::text, v_need.base_unit, coalesce(v_pos.label, '-')
          using errcode = '22023';
      end if;
    elsif v_need.need > v_pos.qty_base then
      raise exception 'SEGMENT_TOO_SHORT: Potongan % hanya tersisa % %; satu potongan tidak dapat digabung dengan potongan lain',
        coalesce(v_pos.label, '-'), trim_scale(v_pos.qty_base)::text, v_need.base_unit
        using errcode = '22023';
    end if;
  end loop;

  -- K04: kebutuhan bulk diagregasi per produk sebelum cek stok.
  for v_need in
    select e->>'product_id' as product_id, min(e->>'product_name') as product_name,
      min(e->>'base_unit') as base_unit, sum((e->>'qty_base')::numeric) as need
    from jsonb_array_elements(v_cart->'lines') e
    where not (e->>'track_segments')::boolean
    group by e->>'product_id'
  loop
    select coalesce(sum(s.qty_base), 0) into v_avail
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_need.product_id::uuid and s.location = 'SHOP' and s.condition = 'SALEABLE';
    if v_avail < v_need.need then
      raise exception 'INSUFFICIENT_STOCK: Stok "%" di toko tidak cukup (tersedia % %)', v_need.product_name,
        trim_scale(v_avail)::text, v_need.base_unit using errcode = '22023';
    end if;
  end loop;

  if v_client_ref is not null then
    select number into v_existing from private.invoices where client_reference_id = v_client_ref;
    if found then
      raise exception 'ALREADY_FINALIZED: Keranjang ini sudah menjadi nota %', v_existing using errcode = '22023';
    end if;
  end if;
  if v_intent is not null and exists (select 1 from private.payments where intent_id = v_intent) then
    raise exception 'ALREADY_FINALIZED: Pembayaran ini sudah tercatat' using errcode = '22023';
  end if;
  if v_customer is not null and not exists (select 1 from private.customers where id = v_customer) then
    raise exception 'NOT_FOUND: Pelanggan tidak ditemukan' using errcode = '22023';
  end if;

  -- Penulisan.
  v_number := private.next_invoice_number('SALE');
  insert into private.invoices(number, kind, actor_id, subtotal_net_lines, discount_total, total,
    customer_id, client_reference_id, operation_id, free_reason)
  values (v_number, 'SALE', v_actor, v_subtotal, v_discount, v_total,
    v_customer, v_client_ref, v_op, case when v_total = 0 then v_reason end)
  returning id into v_invoice_id;

  for v_line in select e from jsonb_array_elements(v_cart->'lines') with ordinality t(e, n) order by n loop
    insert into private.invoice_items(invoice_id, line_no, kind, product_id, product_unit_id,
      description_snapshot, unit_label_snapshot, qty_sell, factor_snapshot, qty_base, unit_price_snapshot,
      item_discount_mode, item_discount_value, item_discount_exact,
      gross_exact, base_net, invoice_discount_alloc, net_total)
    values (v_invoice_id, (v_line->>'line_no')::integer, 'PRODUCT', (v_line->>'product_id')::uuid,
      (v_line->>'product_unit_id')::uuid,
      (v_line->>'product_name') || ' (' || (v_line->>'unit_label') || ')', v_line->>'unit_label',
      (v_line->>'qty_sell')::numeric, (v_line->>'factor_base')::numeric, (v_line->>'qty_base')::numeric,
      (v_line->>'unit_price')::numeric,
      v_line->>'discount_mode', (v_line->>'discount_value')::numeric,
      case when v_line->>'discount_mode' is not null then (v_line->>'line_discount_exact')::numeric end,
      (v_line->>'gross_exact')::numeric, (v_line->>'base_net')::numeric,
      (v_line->>'invoice_discount_alloc')::numeric, (v_line->>'net_total')::numeric)
    returning id into v_item_id;

    -- Bulk: FIFO (lot.posted_at, lot.id, position.id). Roll: posisi pilihan saja.
    v_left := (v_line->>'qty_base')::numeric;
    for v_pos in
      select s.id, s.lot_id, s.qty_base
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where case when (v_line->>'track_segments')::boolean
        then s.id = (v_line->>'position_id')::uuid
        else l.product_id = (v_line->>'product_id')::uuid
          and s.location = 'SHOP' and s.condition = 'SALEABLE' and s.qty_base > 0 end
      order by l.posted_at, l.id, s.id
    loop
      exit when v_left = 0;
      v_take := least(v_pos.qty_base, v_left);
      continue when v_take <= 0;
      v_cost := private.cost_for_exit_lot(v_pos.lot_id, v_take);
      update private.stock_positions
        set qty_base = qty_base - v_take, sealed = false, version = version + 1
        where id = v_pos.id;
      update private.inventory_lots
        set remaining_qty = remaining_qty - v_take, remaining_cost = remaining_cost - v_cost, version = version + 1
        where id = v_pos.lot_id;
      insert into private.cost_allocations(lot_id, origin_position_id, invoice_item_id, qty_base, cost_amount)
      values (v_pos.lot_id, v_pos.id, v_item_id, v_take, v_cost);
      insert into private.stock_movements(group_id, lot_id, position_id, qty_delta, cost_delta, kind,
        invoice_item_id, actor_id, operation_id)
      values (v_invoice_id, v_pos.lot_id, v_pos.id, -v_take, -v_cost, 'SALE_OUT', v_item_id, v_actor, v_op);
      v_left := v_left - v_take;
    end loop;
    -- K04: alokasi harus habis; tidak ada nota yang lebih besar dari stok keluar.
    if v_left <> 0 then
      raise exception 'INSUFFICIENT_STOCK: Stok "%" tidak cukup', v_line->>'product_name' using errcode = '22023';
    end if;
  end loop;

  if v_total > 0 then
    insert into private.payments(direction, purpose, invoice_id, method, amount, tendered, change,
      cash_session_id, reference, confirmed_by, actor_id, intent_id, operation_id)
    values ('IN', 'SALE_RECEIPT', v_invoice_id, v_method, v_total,
      case when v_method = 'CASH' then v_tendered end, v_change,
      case when v_method = 'CASH' then v_session.id end, v_reference,
      case when v_method <> 'CASH' then v_actor end, v_actor, v_intent, v_op)
    returning id into v_payment_id;
    if v_method = 'CASH' then
      insert into private.cash_movements(session_id, direction, kind, amount, payment_id, actor_id, operation_id)
      values (v_session.id, 'IN', 'CUSTOMER_PAYMENT', v_total, v_payment_id, v_actor, v_op);
    end if;
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, case when v_total = 0 then 'SALE_FINALIZE_FREE' else 'SALE_FINALIZE' end,
    'INVOICE', v_invoice_id, v_reason);

  select coalesce(jsonb_agg(jsonb_build_object(
      'invoice_item_id', ii.id, 'line_no', ii.line_no, 'product_unit_id', ii.product_unit_id,
      'description', ii.description_snapshot, 'unit_label', ii.unit_label_snapshot,
      'qty_sell', ii.qty_sell::text, 'qty_base', ii.qty_base::text,
      'unit_price', ii.unit_price_snapshot::text, 'gross_exact', ii.gross_exact::text,
      'line_discount', coalesce(ii.item_discount_exact, 0)::text, 'base_net', ii.base_net::text,
      'invoice_discount_alloc', ii.invoice_discount_alloc::text, 'net_total', ii.net_total::text)
      order by ii.line_no), '[]'::jsonb)
    into v_items_out
    from private.invoice_items ii where ii.invoice_id = v_invoice_id;

  v_result := jsonb_build_object(
    'ok', true, 'entity_id', v_invoice_id, 'document_number', v_number,
    'operation_id', v_op, 'server_time', now(), 'schema_version', 2,
    'subtotal', v_subtotal::text, 'discount', v_discount::text, 'total', v_total::text,
    'payment_id', v_payment_id, 'payment_method', v_method,
    'tendered', case when v_method = 'CASH' then v_tendered::text end,
    'change', v_change::text, 'items', v_items_out);
  return private.finish_operation('finalize_sale_v1', p_input, v_result);
end $$;
revoke all on function public.finalize_sale_v1(jsonb) from public, anon, authenticated;
grant execute on function public.finalize_sale_v1(jsonb) to authenticated;

-- === preview_sale_v1 ==========================================================
-- Total server sebelum bayar (tanpa kunci/tulis). Payload sama dengan finalize.
create or replace function public.preview_sale_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_role text;
  v_cart jsonb;
  v_total numeric;
  v_tendered numeric;
  v_lines jsonb;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.sales_reject_unknown(p_input, array['operation_id', 'client_reference_id', 'customer_id',
    'items', 'discount_mode', 'discount_value', 'payment', 'reason', 'payment_intent_id'], 'penjualan');
  v_cart := private.sales_price_cart(p_input, v_role);
  v_total := (v_cart->>'total')::numeric;
  if jsonb_typeof(p_input->'payment') = 'object' and p_input->'payment'->>'method' = 'CASH' then
    v_tendered := private.decimal_input_opt(p_input->'payment'->'tendered', 0, 9999999999999999, false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'line_no', (e->>'line_no')::integer,
      'product_id', e->>'product_id', 'product_unit_id', e->>'product_unit_id',
      'unit_version', (e->>'unit_version')::integer,
      'description', (e->>'product_name') || ' (' || (e->>'unit_label') || ')',
      'unit_label', e->>'unit_label', 'track_segments', (e->>'track_segments')::boolean,
      'position_id', e->>'position_id',
      'qty_sell', e->>'qty_sell', 'qty_base', e->>'qty_base', 'unit_price', e->>'unit_price',
      'discount_mode', e->>'discount_mode', 'discount_value', e->>'discount_value',
      'gross_exact', e->>'gross_exact', 'line_discount', e->>'line_discount_exact',
      'base_net', e->>'base_net', 'invoice_discount_alloc', e->>'invoice_discount_alloc',
      'net_total', e->>'net_total',
      'available_base', (case when (e->>'track_segments')::boolean then
          (select coalesce(sum(s.qty_base), 0) from private.stock_positions s
            join private.inventory_lots l on l.id = s.lot_id
            where s.id = (e->>'position_id')::uuid and l.product_id = (e->>'product_id')::uuid
              and s.location = 'SHOP' and s.condition = 'SALEABLE')
        else
          (select coalesce(sum(s.qty_base), 0) from private.stock_positions s
            join private.inventory_lots l on l.id = s.lot_id
            where l.product_id = (e->>'product_id')::uuid and s.location = 'SHOP' and s.condition = 'SALEABLE')
        end)::text)
      order by (e->>'line_no')::integer), '[]'::jsonb)
    into v_lines
    from jsonb_array_elements(v_cart->'lines') e;

  return jsonb_build_object(
    'ok', true, 'server_time', now(), 'schema_version', 2,
    'subtotal', v_cart->>'subtotal', 'discount_mode', v_cart->>'discount_mode',
    'discount_value', v_cart->>'discount_value', 'discount', v_cart->>'discount_total',
    'total', v_cart->>'total',
    'requires_owner_reason', v_total = 0,
    'tendered', v_tendered::text,
    'change', case when v_tendered is not null and v_tendered >= v_total then (v_tendered - v_total)::text end,
    'items', v_lines);
end $$;
revoke all on function public.preview_sale_v1(jsonb) from public, anon, authenticated;
grant execute on function public.preview_sale_v1(jsonb) to authenticated;

-- === list_sellable_positions_v1 ==============================================
-- Daftar roll/potongan layak jual (SHOP, SALEABLE, sisa > 0) untuk dipilih kasir.
create or replace function public.list_sellable_positions_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_product private.products%rowtype;
  v_id uuid;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.sales_reject_unknown(p_input, array['product_id'], 'daftar potongan');
  v_id := private.sales_uuid_input(p_input->'product_id', 'Barang');
  select * into v_product from private.products where id = v_id;
  if not found then
    raise exception 'NOT_FOUND: Barang tidak ditemukan' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'product_id', v_product.id, 'base_unit', v_product.base_unit,
    'track_segments', v_product.track_segments,
    'positions', (select coalesce(jsonb_agg(jsonb_build_object(
        'position_id', s.id, 'label', s.label, 'qty_base', s.qty_base::text,
        'segment_capacity', s.segment_capacity::text, 'sealed', s.sealed,
        'version', s.version, 'received_at', l.posted_at)
        order by s.sealed, l.posted_at, s.label, s.id), '[]'::jsonb)
      from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
      where l.product_id = v_product.id and s.location = 'SHOP' and s.condition = 'SALEABLE'
        and s.qty_base > 0));
end $$;
revoke all on function public.list_sellable_positions_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_sellable_positions_v1(jsonb) to authenticated;
