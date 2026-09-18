-- FR-RPT-01/K03: beranda "hari ini" memakai tanggal lokal WIB, servis perlu tindakan,
-- kunjungan terjadwal, stok rendah, kas per cashbox, status backup, peran.
\set ON_ERROR_STOP on

begin;

create function pg_temp.act(p_sub text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_sub, true)
$$;
create function pg_temp.inv(p_number text, p_kind text, p_at timestamptz, p_total numeric, p_ticket uuid default null)
returns uuid language sql as $$
  insert into private.invoices(number, kind, service_ticket_id, actor_id, posted_at, subtotal_net_lines, discount_total, total, operation_id)
  values (p_number, p_kind, p_ticket, '11111111-1111-4111-8111-111111111111', p_at, p_total, 0, p_total, gen_random_uuid())
  returning id
$$;
create function pg_temp.pay(p_direction text, p_purpose text, p_method text, p_amount numeric, p_at timestamptz,
  p_invoice uuid default null, p_ticket uuid default null)
returns uuid language sql as $$
  insert into private.payments(direction, purpose, invoice_id, service_ticket_id, method, amount, actor_id, occurred_at, operation_id)
  values (p_direction, p_purpose, p_invoice, p_ticket, p_method, p_amount, '11111111-1111-4111-8111-111111111111', p_at, gen_random_uuid())
  returning id
$$;
create function pg_temp.ticket(p_number text, p_status text, p_custody text, p_location text, p_scheduled timestamptz, p_closed timestamptz)
returns uuid language sql as $$
  insert into private.service_tickets(number, mechanic_id, service_location, custody_location, equipment_type, complaint,
    work_status, scheduled_at, completed_at, closed_at, address)
  values (p_number, '11111111-1111-4111-8111-111111111111', p_location, p_custody, 'Mesin cuci', 'Bocor', p_status,
    p_scheduled, p_closed, p_closed, case when p_location = 'ONSITE' then 'Jl. Contoh 1' end)
  returning id
$$;

do $$
declare v_today timestamptz := private.local_day_start(private.local_today()); v_inv uuid; v_t uuid;
begin
  -- Batas hari: 00:00, 00:30, 13:30, 23:59:59 WIB masuk; kemarin 23:59:59 dan besok 00:00 tidak.
  v_inv := pg_temp.inv('D-0000', 'SALE', v_today, 1000);
  perform pg_temp.pay('IN', 'SALE_RECEIPT', 'CASH', 1000, v_today, v_inv);
  v_inv := pg_temp.inv('D-0030', 'SALE', v_today + interval '30 minutes', 2000);
  perform pg_temp.pay('IN', 'SALE_RECEIPT', 'QRIS', 2000, v_today + interval '30 minutes', v_inv);
  v_inv := pg_temp.inv('D-1330', 'SALE', v_today + interval '13 hours 30 minutes', 4000);
  perform pg_temp.pay('IN', 'SALE_RECEIPT', 'TRANSFER', 4000, v_today + interval '13 hours 30 minutes', v_inv);
  perform pg_temp.pay('OUT', 'CUSTOMER_REFUND', 'CASH', 500, v_today + interval '14 hours', v_inv);
  v_inv := pg_temp.inv('D-2359', 'SALE', v_today + interval '23 hours 59 minutes 59 seconds', 8000);
  v_inv := pg_temp.inv('D-PREV', 'SALE', v_today - interval '1 second', 32000);
  perform pg_temp.pay('IN', 'SALE_RECEIPT', 'CASH', 32000, v_today - interval '1 second', v_inv);
  v_inv := pg_temp.inv('D-NEXT', 'SALE', v_today + interval '1 day', 64000);

  -- Servis: dua aktif, satu siap diambil (masih di toko), satu kunjungan hari ini, satu sudah diserahkan.
  v_t := pg_temp.ticket('SV-READY', 'READY', 'SHOP', 'STORE', null, null);
  perform pg_temp.inv('SV-INV', 'SERVICE', v_today + interval '9 hours', 150000, v_t);
  perform pg_temp.ticket('SV-VISIT', 'INSPECTING', 'CUSTOMER', 'ONSITE', v_today + interval '10 hours', null);
  perform pg_temp.ticket('SV-VISIT-TMRW', 'NEW', 'CUSTOMER', 'ONSITE', v_today + interval '1 day 10 hours', null);
  perform pg_temp.ticket('SV-DONE', 'READY', 'CUSTOMER', 'STORE', null, now());
  -- Piutang servis: diserahkan kemarin dengan sisa tagihan 150000 (tagihan 200000, dibayar 50000).
  v_t := pg_temp.ticket('SV-OWED', 'READY', 'CUSTOMER', 'STORE', null, null);
  update private.service_tickets set completed_at = v_today - interval '1 day', receivable_note = 'Bayar akhir bulan'
    where id = v_t;
  v_inv := pg_temp.inv('SV-OWED-INV', 'SERVICE', v_today - interval '1 day', 200000, v_t);
  perform pg_temp.pay('IN', 'SERVICE_RECEIPT', 'CASH', 50000, v_today - interval '1 day', v_inv, v_t);

  -- Stok rendah: lampu min 5, stok 3; kabel min 0 tidak dihitung.
  update private.products set min_stock = 5 where id = 'a2000000-0000-4000-8000-000000000001';
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  perform public.post_opening_stock_v1(jsonb_build_object('operation_id', 'd4000000-0000-4000-8000-000000000001',
    'reason', 'awal', 'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
      'qty', '3', 'acquisition_cost', '30000'))));

  insert into private.cash_sessions(cashbox_id, opened_by, business_date, opening_amount)
    values ('SHOP_DRAWER', '22222222-2222-4222-8222-222222222222', private.local_today(), 200000);
  insert into private.backup_runs(status, started_at, completed_at, backup_label)
    values ('SUCCEEDED', now() - interval '3 hours', now() - interval '2 hours', 'uji'),
           ('FAILED', now() - interval '1 hour', now() - interval '1 hour', 'uji-gagal');
end $$;

do $$
declare v jsonb; v_drawer jsonb;
begin
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  v := public.get_dashboard_v1('{}');
  if v->'today'->'sales'->>'invoice_total' <> '15000' or v->>'sales_total' <> '15000' or (v->>'sales_count')::integer <> 4 then
    raise exception 'Dashboard: penjualan hari ini seharusnya 15000/4, dapat %', v->'today'->'sales';
  end if;
  if v->'today'->'service'->>'net' <> '150000' then raise exception 'Dashboard: nilai servis hari ini salah'; end if;
  if v->'today'->'customer_receipts'->'by_method' <> '{"CASH":"1000","QRIS":"2000","TRANSFER":"4000"}'::jsonb
     or v->>'receipts_cash' <> '1000' or v->>'receipts_transfer' <> '6000' or v->>'refund_total' <> '500' then
    raise exception 'Dashboard: penerimaan/refund salah %', v->'today';
  end if;
  if (v->'service'->>'not_picked_up_count')::integer <> 1 or v->'service'->'not_picked_up'->0->>'number' <> 'SV-READY' then
    raise exception 'Dashboard: belum diambil salah %', v->'service';
  end if;
  if jsonb_array_length(v->'service'->'scheduled_today') <> 1 or v->'service'->'scheduled_today'->0->>'number' <> 'SV-VISIT' then
    raise exception 'Dashboard: kunjungan hari ini salah %', v->'service'->'scheduled_today';
  end if;
  if (v->'service'->'active_by_status'->>'READY')::integer <> 1 or (v->'service'->>'active_total')::integer <> 3 then
    raise exception 'Dashboard: servis aktif salah %', v->'service';
  end if;
  if (v->'service'->>'receivable_count')::integer <> 1 or v->'service'->>'receivable_total' <> '150000'
     or v->'service'->'receivables'->0->>'number' <> 'SV-OWED' or v->'service'->'receivables'->0->>'outstanding' <> '150000'
     or v->'service'->'receivables'->0->>'note' <> 'Bayar akhir bulan' then
    raise exception 'Dashboard: piutang servis salah %', v->'service';
  end if;
  if (v->>'low_stock')::integer <> 1 or v->'low_stock_items'->0->>'stock_shop' <> '3.000' then
    raise exception 'Dashboard: stok rendah salah %', v->'low_stock_items';
  end if;
  select e into v_drawer from jsonb_array_elements(v->'cash_sessions') e where e->>'cashbox' = 'SHOP_DRAWER';
  if not (v_drawer->>'open')::boolean or v_drawer->>'expected_amount' <> '200000' or not (v->>'cash_session_open')::boolean then
    raise exception 'Dashboard: kas laci salah %', v->'cash_sessions';
  end if;
  if (select e->>'open' from jsonb_array_elements(v->'cash_sessions') e where e->>'cashbox' = 'FATHER_WALLET') <> 'false' then
    raise exception 'Dashboard: dompet ayah seharusnya tertutup';
  end if;
  if v->'backup'->>'last_status' <> 'FAILED' or (v->'backup'->>'stale')::boolean or (v->'backup'->>'age_hours')::numeric <> 2.0 then
    raise exception 'Dashboard: status backup salah %', v->'backup';
  end if;
  if v->>'server_date' <> private.local_today()::text or v->>'refreshed_at' is null then
    raise exception 'Dashboard: tanggal server salah';
  end if;

  -- STAFF: tanpa saldo seharusnya/modal.
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  v := public.get_dashboard_v1('{}');
  if v::text ~* '(expected_amount|cost|cogs|gross)' or v->>'sales_total' <> '15000' then
    raise exception 'Dashboard STAFF bocor/salah: %', v;
  end if;
  perform pg_temp.act('44444444-4444-4444-8444-444444444444');
  begin
    perform public.get_dashboard_v1('{}');
    raise exception 'Dashboard: akun nonaktif harus ditolak';
  exception when others then
    if position('ACCOUNT_INACTIVE' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

-- Backup kedaluwarsa (>24 jam) ditandai stale.
do $$
declare v jsonb;
begin
  update private.backup_runs set started_at = now() - interval '30 hours', completed_at = now() - interval '29 hours' where status = 'SUCCEEDED';
  perform pg_temp.act('33333333-3333-4333-8333-333333333333');
  v := public.get_dashboard_v1('{}');
  if not (v->'backup'->>'stale')::boolean then raise exception 'Dashboard: backup >24 jam harus stale'; end if;
end $$;

rollback;
