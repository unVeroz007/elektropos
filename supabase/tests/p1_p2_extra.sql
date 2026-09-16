-- AT-05/06/11/14: presisi, roll, FIFO modal, stok habis.
\set ON_ERROR_STOP on

begin;

-- AT-14: invariant — sum(lot remaining) = lot original - allocated, sum(cost_alloc) = total modal keluar.
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config('role', 'postgres', true);

do $$
declare v_bad integer; v_detail text;
begin
  -- Invariant: sum(position.qty) == lot.remaining_qty
  select count(*) into v_bad from private.inventory_lots l
  where l.remaining_qty <> (select coalesce(sum(p.qty_base),0) from private.stock_positions p where p.lot_id = l.id);
  if v_bad > 0 then
    select l.id::text || ' remain=' || l.remaining_qty::text || ' pos=' ||
      (select coalesce(sum(p.qty_base),0)::text from private.stock_positions p where p.lot_id = l.id)
    into v_detail
    from private.inventory_lots l
    where l.remaining_qty <> (select coalesce(sum(p.qty_base),0) from private.stock_positions p where p.lot_id = l.id)
    limit 1;
    raise exception 'AT-14: % lot tidak cocok: %', v_bad, v_detail;
  end if;

  -- Invariant: setiap cost_allocation >= 0
  select count(*) into v_bad from private.cost_allocations ca where ca.cost_amount < 0;
  if v_bad > 0 then raise exception 'AT-14: % cost allocation negatif', v_bad; end if;

  -- Invariant: sum(invoice_items.net_total) == invoice.total untuk setiap SALE
  select count(*) into v_bad from private.invoices i
  where i.kind = 'SALE' and i.total <> (select coalesce(sum(ii.net_total),0) from private.invoice_items ii where ii.invoice_id = i.id);
  if v_bad > 0 then raise exception 'AT-14: % invoice SALE total tidak cocok', v_bad; end if;

  -- Invariant: stok negatif tidak ada
  select count(*) into v_bad from private.stock_positions where qty_base < 0;
  if v_bad > 0 then raise exception 'AT-14: % posisi stok negatif', v_bad; end if;

  select count(*) into v_bad from private.inventory_lots where remaining_qty < 0;
  if v_bad > 0 then raise exception 'AT-14: % lot stok negatif', v_bad; end if;
end $$;

-- AT-11: stok tersisa 1 pcs, jual 2 ditolak.
select set_config('role', 'authenticated', true);
do $$
begin
  begin
    perform public.finalize_sale_v1(jsonb_build_object(
      'operation_id', 'e0000000-0000-4000-8000-000000000004',
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '2')),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
    raise exception 'AT-11: seharusnya ditolak';
  exception when others then
    if position('INSUFFICIENT_STOCK' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

-- AT-05: stok 1m meter dijual 0.1m x10 kali -> sisa tepat 0.
select set_config('role', 'authenticated', true);
do $$
declare v_res jsonb; i integer;
begin
  -- Stok awal 1m kabel (track_segments=true, bukan segel agar bisa dijual 0.1m)
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'e0000000-0000-4000-8000-000000000010',
    'reason', 'Stok uji presisi',
    'items', jsonb_build_array(jsonb_build_object(
      'product_unit_id', 'a1000000-0000-4000-8000-000000000002',
      'qty', '1', 'acquisition_cost', '5000',
      'positions', jsonb_build_array(jsonb_build_object(
        'qty_base', '1', 'segment_capacity', '1', 'sealed', false, 'label', 'PRESISI-01'))))));

  -- 10 kali jual 0.1m
  for i in 1..10 loop
    v_res := public.finalize_sale_v1(jsonb_build_object(
      'operation_id', ('e0000000-0000-4000-8000-000000000' || lpad((100+i)::text,3,'0'))::uuid,
      'items', jsonb_build_array(jsonb_build_object(
        'product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '0.1')),
      'payment', jsonb_build_object('method', 'TRANSFER', 'confirmed', true)));
    if not (v_res->>'ok')::boolean then raise exception 'AT-05: penjualan % gagal', i; end if;
  end loop;
end $$;

select set_config('role', 'postgres', true);
do $$
declare v_qty numeric; v_cost numeric; v_saldo numeric;
begin
  select coalesce(sum(l.remaining_qty),0), coalesce(sum(l.remaining_cost),0)
    into v_qty, v_cost
  from private.inventory_lots l where l.product_id='a2000000-0000-4000-8000-000000000002';
  if v_qty <> 0 then raise exception 'AT-05: sisa meter harus 0, dapat %', v_qty; end if;
  if v_cost <> 0 then raise exception 'AT-05: sisa modal harus 0, dapat %', v_cost; end if;
end $$;

-- Invariant global: sum(position.qty) = lot.remaining_qty, no negative stock
do $$
declare v_bad integer; v_detail text;
begin
  select count(*) into v_bad from private.inventory_lots l
  where l.remaining_qty <> (select coalesce(sum(p.qty_base),0) from private.stock_positions p where p.lot_id = l.id);
  if v_bad > 0 then
    select l.id::text || ' remain=' || l.remaining_qty::text || ' pos=' ||
      (select coalesce(sum(p.qty_base),0)::text from private.stock_positions p where p.lot_id = l.id)
    into v_detail
    from private.inventory_lots l
    where l.remaining_qty <> (select coalesce(sum(p.qty_base),0) from private.stock_positions p where p.lot_id = l.id)
    limit 1;
    raise exception 'Invariant posisi: % lot tidak cocok — %', v_bad, v_detail;
  end if;

  select count(*) into v_bad from private.stock_positions where qty_base < 0;
  if v_bad > 0 then raise exception 'Invariant: % posisi stok negatif', v_bad; end if;

  select count(*) into v_bad from private.inventory_lots where remaining_qty < 0;
  if v_bad > 0 then raise exception 'Invariant: % lot stok negatif', v_bad; end if;

  -- sum(invoice_items.net_total) == invoice.total
  select count(*) into v_bad from private.invoices i
  where i.total <> (select coalesce(sum(ii.net_total),0) from private.invoice_items ii where ii.invoice_id = i.id);
  if v_bad > 0 then raise exception 'Invariant: % invoice total tidak cocok', v_bad; end if;
end $$;

rollback;
