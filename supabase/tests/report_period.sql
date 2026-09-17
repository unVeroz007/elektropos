-- K03/S02/BR-13/D2: batas tanggal WIB, neto berdasarkan posting masing-masing dokumen,
-- COGS barang/servis, laba kotor, DP, refund, koreksi metode, kerugian disposal, peran.
\set ON_ERROR_STOP on

begin;

create function pg_temp.act(p_sub text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_sub, true)
$$;
create function pg_temp.expect_error(p_sql text, p_code text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_code in sqlerrm) = 0 then
      raise exception 'Diharapkan error % tetapi dapat: %', p_code, sqlerrm;
    end if;
    return;
  end;
  raise exception 'Diharapkan error % tetapi perintah berhasil: %', p_code, left(p_sql, 160);
end $$;
create function pg_temp.inv(p_number text, p_kind text, p_at timestamptz, p_total numeric, p_ticket uuid default null)
returns uuid language sql as $$
  insert into private.invoices(number, kind, service_ticket_id, actor_id, posted_at, subtotal_net_lines, discount_total, total, operation_id)
  values (p_number, p_kind, p_ticket, '11111111-1111-4111-8111-111111111111', p_at, p_total, 0, p_total, gen_random_uuid())
  returning id
$$;
create function pg_temp.pay(p_direction text, p_purpose text, p_method text, p_amount numeric, p_at timestamptz,
  p_invoice uuid default null, p_ticket uuid default null, p_original uuid default null)
returns uuid language sql as $$
  insert into private.payments(direction, purpose, invoice_id, service_ticket_id, original_payment_id, method, amount,
    actor_id, occurred_at, operation_id)
  values (p_direction, p_purpose, p_invoice, p_ticket, p_original, p_method, p_amount,
    '11111111-1111-4111-8111-111111111111', p_at, gen_random_uuid())
  returning id
$$;
create function pg_temp.report(p_start text, p_end text) returns jsonb language sql as $$
  select public.get_report_v1(jsonb_build_object('start_date', p_start, 'end_date', p_end))
$$;

select pg_temp.act('11111111-1111-4111-8111-111111111111');
select public.post_opening_stock_v1(jsonb_build_object(
  'operation_id', 'd3000000-0000-4000-8000-000000000001', 'reason', 'Stok awal',
  'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
    'qty', '10', 'acquisition_cost', '100000'))));

-- K03: batas hari WIB. Bug lama: nota 00:30 dan 13:30 WIB keluar dari tanggalnya.
do $$
declare v jsonb;
begin
  perform pg_temp.inv('B-0000', 'SALE', '2026-08-10 00:00:00+07', 1000);
  perform pg_temp.inv('B-0030', 'SALE', '2026-08-10 00:30:00+07', 2000);
  perform pg_temp.inv('B-1330', 'SALE', '2026-08-10 13:30:00+07', 4000);
  perform pg_temp.inv('B-2359', 'SALE', '2026-08-10 23:59:59+07', 8000);
  perform pg_temp.inv('B-NEXT', 'SALE', '2026-08-11 00:00:00+07', 16000);
  perform pg_temp.inv('B-PREV', 'SALE', '2026-08-09 23:59:59+07', 32000);
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v := pg_temp.report('2026-08-10', '2026-08-10');
  if v->'sales'->>'invoice_total' <> '15000' or (v->'sales'->>'invoice_count')::integer <> 4 then
    raise exception 'K03: 10 Agustus seharusnya 15000/4 nota, dapat %', v->'sales';
  end if;
  if v->'period'->>'start_at' <> '2026-08-09T17:00:00+00:00' or v->'period'->>'end_at' <> '2026-08-10T17:00:00+00:00' then
    raise exception 'K03: jendela WIB salah %', v->'period';
  end if;
  if pg_temp.report('2026-08-11', '2026-08-11')->'sales'->>'invoice_total' <> '16000' then
    raise exception 'K03: 11 Agustus 00:00 WIB harus masuk tanggal 11';
  end if;
  if pg_temp.report('2026-08-09', '2026-08-09')->'sales'->>'invoice_total' <> '32000' then
    raise exception 'K03: 9 Agustus 23:59:59 WIB harus masuk tanggal 9';
  end if;
  -- Tanpa tumpang tindih: jumlah per hari = rentang gabungan.
  if pg_temp.report('2026-08-09', '2026-08-11')->'sales'->>'invoice_total' <> '63000' then
    raise exception 'K03: rentang gabungan seharusnya 63000';
  end if;
  delete from private.invoices where number like 'B-%';
end $$;

-- Data September: penjualan, servis dengan DP, koreksi metode, disposal.
do $$
declare v_lot uuid; v_pos uuid; v_inv uuid; v_item uuid; v_ca uuid; v_rcpt uuid; v_ticket uuid; v_event uuid;
  v_sinv uuid; v_lunas uuid; v_cn uuid;
begin
  select s.lot_id, s.id into v_lot, v_pos from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = 'a2000000-0000-4000-8000-000000000001';

  v_inv := pg_temp.inv('S-SEP', 'SALE', '2026-09-05 10:00+07', 100000);
  insert into private.invoice_items(invoice_id, line_no, kind, product_id, description_snapshot, qty_sell, factor_snapshot,
    qty_base, unit_price_snapshot, gross_exact, base_net, invoice_discount_alloc, net_total)
    values (v_inv, 1, 'PRODUCT', 'a2000000-0000-4000-8000-000000000001', 'Lampu', 2, 1, 2, 50000, 100000, 100000, 0, 100000)
    returning id into v_item;
  insert into private.cost_allocations(lot_id, origin_position_id, invoice_item_id, qty_base, cost_amount, occurred_at)
    values (v_lot, v_pos, v_item, 2, 20000, '2026-09-05 10:00+07') returning id into v_ca;
  v_rcpt := pg_temp.pay('IN', 'SALE_RECEIPT', 'CASH', 100000, '2026-09-05 10:00+07', v_inv);

  insert into private.service_tickets(number, mechanic_id, service_location, custody_location, equipment_type, complaint,
    work_status, created_at)
    values ('T-SEP', '11111111-1111-4111-8111-111111111111', 'STORE', 'SHOP', 'Pompa', 'Mati', 'READY', '2026-09-01 09:00+07')
    returning id into v_ticket;
  perform pg_temp.pay('IN', 'SERVICE_RECEIPT', 'QRIS', 30000, '2026-09-02 09:00+07', null, v_ticket);
  insert into private.service_part_events(ticket_id, product_id, kind, qty_base, actor_id, occurred_at)
    values (v_ticket, 'a2000000-0000-4000-8000-000000000001', 'USE', 1, '11111111-1111-4111-8111-111111111111', '2026-09-03 09:00+07')
    returning id into v_event;
  v_sinv := pg_temp.inv('SRV-SEP', 'SERVICE', '2026-09-10 10:00+07', 75000, v_ticket);
  insert into private.service_cost_recognitions(invoice_id, part_event_id, cost_amount) values (v_sinv, v_event, 12000.5);
  v_lunas := pg_temp.pay('IN', 'SERVICE_RECEIPT', 'CASH', 45000, '2026-09-12 10:00+07', null, v_ticket);
  -- Koreksi metode: tunai ternyata transfer (net nol, bukan penerimaan baru).
  perform pg_temp.pay('OUT', 'PAYMENT_REVERSAL', 'CASH', 45000, '2026-09-20 10:00+07', null, v_ticket, v_lunas);
  perform pg_temp.pay('IN', 'PAYMENT_REPLACEMENT', 'TRANSFER', 45000, '2026-09-20 10:00+07', null, v_ticket, v_lunas);

  -- Retur 1 lampu pada Oktober atas nota September.
  insert into private.credit_notes(number, invoice_id, kind, reason, total, actor_id, posted_at, operation_id)
    values ('CRD-OCT', v_inv, 'RETURN', 'Rusak', 50000, '11111111-1111-4111-8111-111111111111', '2026-10-03 10:00+07', gen_random_uuid())
    returning id into v_cn;
  insert into private.credit_note_items(credit_note_id, invoice_item_id, qty_return_base, amount, cost_reversal_amount, disposition, line_no)
    values (v_cn, v_item, 1, 50000, 10000, 'DAMAGED', 1);
  -- reversed_cost pada alokasi ikut berubah; laporan September tidak boleh memakainya.
  update private.cost_allocations set reversed_qty = 1, reversed_cost = 10000 where id = v_ca;
  perform pg_temp.pay('OUT', 'CUSTOMER_REFUND', 'TRANSFER', 50000, '2026-10-03 10:05+07', v_inv, null, v_rcpt);
end $$;

do $$
declare v_res jsonb; v_pos uuid;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  select s.id into v_pos from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = 'a2000000-0000-4000-8000-000000000001';
  v_res := public.dispose_stock_v1(jsonb_build_object('operation_id', 'd3000000-0000-4000-8000-000000000002',
    'position_id', v_pos, 'expected_version', 1, 'qty_base', '1', 'reason', 'Pecah'));
  update private.stock_movements set occurred_at = '2026-09-15 10:00+07' where kind = 'DISPOSAL';
end $$;

-- Laporan September (OWNER): nilai eksplisit.
do $$
declare v jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v := pg_temp.report('2026-09-01', '2026-09-30');
  if v->'sales'->>'net' <> '100000' or v->'service'->>'net' <> '75000' or v->>'sales_net' <> '100000' then
    raise exception 'Sep: neto salah %', v;
  end if;
  if v->'customer_receipts'->>'total' <> '175000' or v->'customer_receipts'->'by_method'->>'CASH' <> '145000'
     or v->'customer_receipts'->'by_method'->>'QRIS' <> '30000' or v->'customer_receipts'->>'deposit_total' <> '30000'
     or v->'customer_receipts'->'deposit_by_method'->>'QRIS' <> '30000' or v->'customer_receipts'->>'service' <> '75000' then
    raise exception 'Sep: penerimaan salah %', v->'customer_receipts';
  end if;
  if v->'customer_refunds'->>'total' <> '0' or v->>'net_customer_receipts' <> '175000' then
    raise exception 'Sep: refund/penerimaan bersih salah';
  end if;
  if v->'payment_corrections'->>'net' <> '0' or v->'payment_corrections'->>'reversal_total' <> '45000'
     or v->'net_by_method'->>'CASH' <> '100000' or v->'net_by_method'->>'TRANSFER' <> '45000' then
    raise exception 'Sep: koreksi metode salah % / %', v->'payment_corrections', v->'net_by_method';
  end if;
  -- COGS barang 20000 (reversed_cost di alokasi TIDAK dipakai), servis 12000.5 -> total 32000.5 -> dibulatkan 32001.
  if v->'cost'->>'sale_cogs_net' <> '20000' or v->'cost'->>'service_cogs_net' <> '12001'
     or v->'cost'->>'cogs_net' <> '32001' or v->>'cogs' <> '32001' then
    raise exception 'Sep: COGS salah %', v->'cost';
  end if;
  -- Laba kotor = 175000 - 32000.5 = 142999.5 -> 143000.
  if v->'gross_profit'->>'total' <> '143000' or v->'gross_profit'->>'note' not like '%BUKAN laba bersih%' then
    raise exception 'Sep: laba kotor salah %', v->'gross_profit';
  end if;
  if v->'stock_losses'->>'disposal_cost' <> '10000' then
    raise exception 'Sep: kerugian disposal salah %', v->'stock_losses';
  end if;
end $$;

-- Oktober: retur bulan berikutnya membuat periode baru negatif; September tidak berubah.
do $$
declare v jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v := pg_temp.report('2026-10-01', '2026-10-31');
  if v->'sales'->>'net' <> '-50000' or v->'sales'->>'credit_total' <> '50000' or v->'cost'->>'sale_cogs_net' <> '-10000'
     or v->'gross_profit'->>'total' <> '-40000' or v->'customer_refunds'->>'total' <> '50000'
     or v->'customer_refunds'->'by_method'->>'TRANSFER' <> '50000' or v->>'net_customer_receipts' <> '-50000'
     or v->'stock_losses'->>'disposal_cost' <> '0' then
    raise exception 'Okt: laporan retur salah %', v;
  end if;
  v := pg_temp.report('2026-09-01', '2026-09-30');
  if v->'sales'->>'net' <> '100000' or v->'cost'->>'sale_cogs_net' <> '20000' then
    raise exception 'Retur Oktober menulis ulang September: %', v;
  end if;
  -- Gabungan dua bulan = jumlah masing-masing.
  v := pg_temp.report('2026-09-01', '2026-10-31');
  if v->'sales'->>'net' <> '50000' or v->'cost'->>'sale_cogs_net' <> '10000' then
    raise exception 'Gabungan Sep-Okt salah %', v;
  end if;
end $$;

-- Peran (D2): STAFF menerima omzet/penerimaan tanpa kunci modal; MAINTAINER menerima modal.
do $$
declare v jsonb;
begin
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  v := pg_temp.report('2026-09-01', '2026-09-30');
  if v->'sales'->>'net' <> '100000' or v->'customer_receipts'->>'total' <> '175000' then
    raise exception 'STAFF harus melihat omzet/penerimaan';
  end if;
  if v ? 'cost' or v ? 'cogs' or v ? 'gross_profit' or v ? 'stock_losses'
     or v::text ~* '(cost|cogs|gross|modal|laba)' then
    raise exception 'STAFF menerima data modal: %', v;
  end if;
  perform pg_temp.act('33333333-3333-4333-8333-333333333333');
  if pg_temp.report('2026-09-01', '2026-09-30')->'cost'->>'cogs_net' <> '32001' then
    raise exception 'MAINTAINER harus menerima modal';
  end if;
  perform pg_temp.act('44444444-4444-4444-8444-444444444444');
  perform pg_temp.expect_error('select pg_temp.report(''2026-09-01'', ''2026-09-30'')', 'ACCOUNT_INACTIVE');
  perform set_config('role', 'anon', true);
  perform pg_temp.expect_error('select public.get_report_v1(''{"start_date":"2026-09-01","end_date":"2026-09-01"}'')', 'permission denied');
  perform set_config('role', 'postgres', true);
end $$;

-- Validasi rentang.
do $$
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform pg_temp.report('2025-09-01', '2026-09-01');
  perform pg_temp.expect_error('select pg_temp.report(''2025-09-01'', ''2026-09-02'')', 'INVALID_DATE');
  perform pg_temp.expect_error('select pg_temp.report(''2026-09-02'', ''2026-09-01'')', 'INVALID_DATE');
  perform pg_temp.expect_error('select pg_temp.report(''2026-13-01'', ''2026-09-01'')', 'INVALID_DATE');
  perform pg_temp.expect_error('select public.get_report_v1(''{"start_date":"2026-09-01"}'')', 'INVALID_DATE');
  perform pg_temp.expect_error('select public.get_report_v1(''{"start_date":"2026-09-01","end_date":"2026-09-01","x":1}'')', 'INVALID_INPUT');
end $$;

rollback;
