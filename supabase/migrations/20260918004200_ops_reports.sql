-- Perbaikan audit 2026-09: laporan (BR-13, D2), beranda (FR-RPT-01) dan ekspor CSV.
-- Temuan: K03 (jendela tanggal bergeser 14 jam), S02 (neto/COGS/peran), S03 (pagination
-- ekspor rusak, escape CSV). Semua rentang memakai private.date_range_input /
-- private.local_day_start sehingga periode bersebelahan tidak tumpang tindih.

create or replace function private.ops_money(p_value numeric)
returns text language sql immutable set search_path = '' as $$
  select round(coalesce(p_value, 0), 0)::text
$$;
revoke all on function private.ops_money(numeric) from public, anon, authenticated;

-- Ringkasan pendapatan dan uang pelanggan pada [start, end). Tanpa data modal,
-- sehingga aman untuk semua peran yang boleh melihat omzet (D2).
-- Titik perluasan: retur distributor (D5) ditambahkan sebagai bagian terpisah di
-- private.ops_cost_summary setelah dokumennya tersedia; jangan dicampur ke omzet.
create or replace function private.ops_sales_summary(p_start timestamptz, p_end timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_sale_inv numeric; v_sale_inv_n integer; v_sale_cn numeric; v_sale_cn_n integer;
  v_srv_inv numeric; v_srv_inv_n integer; v_srv_cn numeric; v_srv_cn_n integer;
  p record;
begin
  select coalesce(sum(total) filter (where kind = 'SALE'), 0), count(*) filter (where kind = 'SALE'),
         coalesce(sum(total) filter (where kind = 'SERVICE'), 0), count(*) filter (where kind = 'SERVICE')
    into v_sale_inv, v_sale_inv_n, v_srv_inv, v_srv_inv_n
    from private.invoices where posted_at >= p_start and posted_at < p_end;
  select coalesce(sum(cn.total) filter (where i.kind = 'SALE'), 0), count(*) filter (where i.kind = 'SALE'),
         coalesce(sum(cn.total) filter (where i.kind = 'SERVICE'), 0), count(*) filter (where i.kind = 'SERVICE')
    into v_sale_cn, v_sale_cn_n, v_srv_cn, v_srv_cn_n
    from private.credit_notes cn join private.invoices i on i.id = cn.invoice_id
    where cn.posted_at >= p_start and cn.posted_at < p_end;

  select
    coalesce(sum(amount) filter (where rc), 0) rc_total,
    coalesce(sum(amount) filter (where rc and method = 'CASH'), 0) rc_cash,
    coalesce(sum(amount) filter (where rc and method = 'TRANSFER'), 0) rc_transfer,
    coalesce(sum(amount) filter (where rc and method = 'QRIS'), 0) rc_qris,
    coalesce(sum(amount) filter (where rc and purpose = 'SALE_RECEIPT'), 0) rc_sale,
    coalesce(sum(amount) filter (where rc and purpose = 'SERVICE_RECEIPT'), 0) rc_service,
    coalesce(sum(amount) filter (where rc and dp), 0) dp_total,
    coalesce(sum(amount) filter (where rc and dp and method = 'CASH'), 0) dp_cash,
    coalesce(sum(amount) filter (where rc and dp and method = 'TRANSFER'), 0) dp_transfer,
    coalesce(sum(amount) filter (where rc and dp and method = 'QRIS'), 0) dp_qris,
    coalesce(sum(amount) filter (where rf), 0) rf_total,
    coalesce(sum(amount) filter (where rf and method = 'CASH'), 0) rf_cash,
    coalesce(sum(amount) filter (where rf and method = 'TRANSFER'), 0) rf_transfer,
    coalesce(sum(amount) filter (where rf and method = 'QRIS'), 0) rf_qris,
    coalesce(sum(amount) filter (where rf and invoice_id is not null), 0) rf_sale,
    coalesce(sum(amount) filter (where rf and invoice_id is null), 0) rf_service,
    coalesce(sum(amount) filter (where purpose = 'PAYMENT_REVERSAL'), 0) rv_total,
    coalesce(sum(amount) filter (where purpose = 'PAYMENT_REPLACEMENT'), 0) rp_total,
    coalesce(sum(case purpose when 'PAYMENT_REPLACEMENT' then amount when 'PAYMENT_REVERSAL' then -amount end)
      filter (where method = 'CASH'), 0) cr_cash,
    coalesce(sum(case purpose when 'PAYMENT_REPLACEMENT' then amount when 'PAYMENT_REVERSAL' then -amount end)
      filter (where method = 'TRANSFER'), 0) cr_transfer,
    coalesce(sum(case purpose when 'PAYMENT_REPLACEMENT' then amount when 'PAYMENT_REVERSAL' then -amount end)
      filter (where method = 'QRIS'), 0) cr_qris
  into p
  from (
    select x.*,
      (x.direction = 'IN' and x.purpose in ('SALE_RECEIPT', 'SERVICE_RECEIPT')) rc,
      (x.direction = 'OUT' and x.purpose = 'CUSTOMER_REFUND') rf,
      -- DP: penerimaan servis sebelum tagihan final tiket tersebut diposting.
      (x.purpose = 'SERVICE_RECEIPT' and not exists (
        select 1 from private.invoices i where i.kind = 'SERVICE'
          and i.service_ticket_id = x.service_ticket_id and i.posted_at <= x.occurred_at)) dp
    from private.payments x
    where x.occurred_at >= p_start and x.occurred_at < p_end
      and x.purpose in ('SALE_RECEIPT', 'SERVICE_RECEIPT', 'CUSTOMER_REFUND', 'PAYMENT_REVERSAL', 'PAYMENT_REPLACEMENT')
  ) x;

  return jsonb_build_object(
    'sales', jsonb_build_object('invoice_total', v_sale_inv::text, 'invoice_count', v_sale_inv_n,
      'credit_total', v_sale_cn::text, 'credit_count', v_sale_cn_n, 'net', (v_sale_inv - v_sale_cn)::text),
    'service', jsonb_build_object('invoice_total', v_srv_inv::text, 'invoice_count', v_srv_inv_n,
      'credit_total', v_srv_cn::text, 'credit_count', v_srv_cn_n, 'net', (v_srv_inv - v_srv_cn)::text),
    'customer_receipts', jsonb_build_object('total', p.rc_total::text,
      'by_method', jsonb_build_object('CASH', p.rc_cash::text, 'TRANSFER', p.rc_transfer::text, 'QRIS', p.rc_qris::text),
      'sale', p.rc_sale::text, 'service', p.rc_service::text,
      'deposit_total', p.dp_total::text,
      'deposit_by_method', jsonb_build_object('CASH', p.dp_cash::text, 'TRANSFER', p.dp_transfer::text, 'QRIS', p.dp_qris::text)),
    'customer_refunds', jsonb_build_object('total', p.rf_total::text,
      'by_method', jsonb_build_object('CASH', p.rf_cash::text, 'TRANSFER', p.rf_transfer::text, 'QRIS', p.rf_qris::text),
      'sale', p.rf_sale::text, 'service', p.rf_service::text),
    'net_customer_receipts', (p.rc_total - p.rf_total)::text,
    'payment_corrections', jsonb_build_object('reversal_total', p.rv_total::text,
      'replacement_total', p.rp_total::text, 'net', (p.rp_total - p.rv_total)::text,
      'net_by_method', jsonb_build_object('CASH', p.cr_cash::text, 'TRANSFER', p.cr_transfer::text, 'QRIS', p.cr_qris::text)),
    'net_by_method', jsonb_build_object(
      'CASH', (p.rc_cash - p.rf_cash + p.cr_cash)::text,
      'TRANSFER', (p.rc_transfer - p.rf_transfer + p.cr_transfer)::text,
      'QRIS', (p.rc_qris - p.rf_qris + p.cr_qris)::text));
end $$;
revoke all on function private.ops_sales_summary(timestamptz, timestamptz) from public, anon, authenticated;

-- Modal/COGS/laba kotor: HANYA untuk OWNER/MAINTAINER.
-- COGS barang  = alokasi modal invoice SALE yang diposting di periode
--                - cost_reversal_amount credit note SALE yang diposting di periode.
-- COGS servis  = service_cost_recognitions invoice SERVICE diposting di periode
--                - cost_reversal_amount credit note SERVICE yang diposting di periode.
-- reversed_cost pada cost_allocations sengaja TIDAK dipakai (akan menulis ulang periode jual).
create or replace function private.ops_cost_summary(p_start timestamptz, p_end timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_sale_alloc numeric; v_sale_rev numeric; v_srv_rec numeric; v_srv_rev numeric;
  v_sale_net numeric; v_srv_net numeric; v_rev_sale numeric; v_rev_srv numeric;
  v_disposal numeric; v_adj_in numeric; v_adj_out numeric; v_gross numeric;
begin
  select coalesce(sum(ca.cost_amount), 0) into v_sale_alloc
    from private.cost_allocations ca
    join private.invoice_items ii on ii.id = ca.invoice_item_id
    join private.invoices i on i.id = ii.invoice_id
    where i.kind = 'SALE' and i.posted_at >= p_start and i.posted_at < p_end;
  select coalesce(sum(cni.cost_reversal_amount) filter (where i.kind = 'SALE'), 0),
         coalesce(sum(cni.cost_reversal_amount) filter (where i.kind = 'SERVICE'), 0)
    into v_sale_rev, v_srv_rev
    from private.credit_note_items cni
    join private.credit_notes cn on cn.id = cni.credit_note_id
    join private.invoices i on i.id = cn.invoice_id
    where cn.posted_at >= p_start and cn.posted_at < p_end;
  select coalesce(sum(r.cost_amount), 0) into v_srv_rec
    from private.service_cost_recognitions r join private.invoices i on i.id = r.invoice_id
    where i.kind = 'SERVICE' and i.posted_at >= p_start and i.posted_at < p_end;

  select coalesce(sum(i.total) filter (where i.kind = 'SALE'), 0), coalesce(sum(i.total) filter (where i.kind = 'SERVICE'), 0)
    into v_rev_sale, v_rev_srv
    from private.invoices i where i.posted_at >= p_start and i.posted_at < p_end;
  select v_rev_sale - coalesce(sum(cn.total) filter (where i.kind = 'SALE'), 0),
         v_rev_srv - coalesce(sum(cn.total) filter (where i.kind = 'SERVICE'), 0)
    into v_rev_sale, v_rev_srv
    from private.credit_notes cn join private.invoices i on i.id = cn.invoice_id
    where cn.posted_at >= p_start and cn.posted_at < p_end;

  select coalesce(-sum(cost_delta) filter (where kind = 'DISPOSAL'), 0),
         coalesce(sum(cost_delta) filter (where kind in ('ADJUST_IN', 'COUNT_IN')), 0),
         coalesce(-sum(cost_delta) filter (where kind in ('ADJUST_OUT', 'COUNT_OUT')), 0)
    into v_disposal, v_adj_in, v_adj_out
    from private.stock_movements where occurred_at >= p_start and occurred_at < p_end
      and kind in ('DISPOSAL', 'ADJUST_IN', 'COUNT_IN', 'ADJUST_OUT', 'COUNT_OUT');

  v_sale_net := v_sale_alloc - v_sale_rev;
  v_srv_net := v_srv_rec - v_srv_rev;
  v_gross := (v_rev_sale + v_rev_srv) - (v_sale_net + v_srv_net);
  -- Nilai modal dihitung 6 desimal lalu dibulatkan pada agregat (BR-05).
  return jsonb_build_object(
    'cost', jsonb_build_object(
      'sale_cogs_allocated', private.ops_money(v_sale_alloc),
      'sale_cogs_reversed', private.ops_money(v_sale_rev),
      'sale_cogs_net', private.ops_money(v_sale_net),
      'service_cogs_recognized', private.ops_money(v_srv_rec),
      'service_cogs_reversed', private.ops_money(v_srv_rev),
      'service_cogs_net', private.ops_money(v_srv_net),
      'cogs_net', private.ops_money(v_sale_net + v_srv_net),
      'rounding', 'Dihitung 6 desimal, dibulatkan ke Rupiah pada total'),
    'gross_profit', jsonb_build_object(
      'sale', private.ops_money(v_rev_sale - v_sale_net),
      'service', private.ops_money(v_rev_srv - v_srv_net),
      'total', private.ops_money(v_gross),
      'note', 'Laba kotor = penjualan neto + servis neto - COGS neto. BUKAN laba bersih: belum dikurangi biaya operasional, kerugian disposal/koreksi stok, gaji, pajak.'),
    'stock_losses', jsonb_build_object(
      'disposal_cost', private.ops_money(v_disposal),
      'adjustment_out_cost', private.ops_money(v_adj_out),
      'adjustment_in_cost', private.ops_money(v_adj_in),
      'note', 'Kerugian disposal dan koreksi stok dicatat terpisah, tidak masuk laba kotor.'),
    'cogs', private.ops_money(v_sale_net + v_srv_net));
end $$;
revoke all on function private.ops_cost_summary(timestamptz, timestamptz) from public, anon, authenticated;

-- get_report_v1 ---------------------------------------------------------------

create or replace function public.get_report_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_role text; r record; v_sales jsonb; v_result jsonb;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(p_input, array['start_date', 'end_date']);
  select * into r from private.date_range_input(p_input, 366);
  v_sales := private.ops_sales_summary(r.start_at, r.end_at);

  v_result := jsonb_build_object(
    'schema_version', 2, 'server_time', now(), 'timezone', 'Asia/Jakarta',
    'period', jsonb_build_object('start_date', r.start_date, 'end_date', r.end_date,
      'start_at', r.start_at, 'end_at', r.end_at),
    'start', r.start_date, 'end', r.end_date,
    -- Kunci ringkas kompatibel dengan UI lama.
    'sales_net', v_sales->'sales'->>'net', 'service_net', v_sales->'service'->>'net',
    'credit_total', ((v_sales->'sales'->>'credit_total')::numeric + (v_sales->'service'->>'credit_total')::numeric)::text,
    'receipts', v_sales->'customer_receipts'->>'total', 'refunds', v_sales->'customer_refunds'->>'total')
    || v_sales;

  -- STAFF: kunci modal tidak dikirim sama sekali (D2).
  if v_role in ('OWNER', 'MAINTAINER') then
    v_result := v_result || private.ops_cost_summary(r.start_at, r.end_at);
  end if;
  return v_result;
end $$;
revoke all on function public.get_report_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_report_v1(jsonb) to authenticated;

-- get_dashboard_v1 --------------------------------------------------------------

create or replace function public.get_dashboard_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_today date; v_start timestamptz; v_end timestamptz;
  v_sales jsonb; v_cash jsonb; v_backup private.backup_runs%rowtype; v_last_ok timestamptz;
  v_terminal text[] := array['READY', 'UNREPAIRABLE', 'CANCELLED', 'ONSITE_DONE'];
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(coalesce(p_input, '{}'::jsonb), array[]::text[]);
  v_today := private.local_today();
  v_start := private.local_day_start(v_today);
  v_end := private.local_day_start(v_today + 1);
  v_sales := private.ops_sales_summary(v_start, v_end);

  select coalesce(jsonb_agg(jsonb_build_object('cashbox', b.code, 'label', b.label,
      'open', s.id is not null, 'session_id', s.id, 'opened_at', s.opened_at,
      'business_date', s.business_date, 'opened_by', ap.display_name)
      || case when v_role in ('OWNER', 'MAINTAINER') and s.id is not null
           then jsonb_build_object('expected_amount', private.cash_session_expected(s.id)::text)
           else '{}'::jsonb end
      order by b.code desc), '[]'::jsonb) into v_cash
    from private.cashboxes b
    left join private.cash_sessions s on s.cashbox_id = b.code and s.status = 'OPEN'
    left join private.app_profiles ap on ap.id = s.opened_by
    where b.active;

  select * into v_backup from private.backup_runs order by started_at desc limit 1;
  select max(coalesce(completed_at, started_at)) into v_last_ok from private.backup_runs where status = 'SUCCEEDED';

  return jsonb_build_object(
    'schema_version', 2, 'refreshed_at', now(), 'server_date', v_today, 'timezone', 'Asia/Jakarta',
    'today', v_sales,
    -- Kunci ringkas kompatibel dengan UI lama.
    'sales_total', v_sales->'sales'->>'net', 'sales_count', (v_sales->'sales'->>'invoice_count')::integer,
    'service_total', v_sales->'service'->>'net',
    'refund_total', v_sales->'customer_refunds'->>'total',
    'receipts_cash', v_sales->'customer_receipts'->'by_method'->>'CASH',
    'receipts_transfer', ((v_sales->'customer_receipts'->'by_method'->>'TRANSFER')::numeric
      + (v_sales->'customer_receipts'->'by_method'->>'QRIS')::numeric)::text,
    'cash_session_open', exists (select 1 from private.cash_sessions where cashbox_id = 'SHOP_DRAWER' and status = 'OPEN'),
    'cash_sessions', v_cash,
    'service', jsonb_build_object(
      'active_by_status', (select coalesce(jsonb_object_agg(work_status, n), '{}'::jsonb) from (
        select work_status, count(*) n from private.service_tickets where closed_at is null group by work_status) x),
      'active_total', (select count(*) from private.service_tickets where closed_at is null),
      -- BR-11: status terminal dan alat masih di toko/ayah, walau sudah lunas.
      'not_picked_up_count', (select count(*) from private.service_tickets
        where work_status = any (v_terminal) and custody_location in ('SHOP', 'FATHER')),
      'not_picked_up', (select coalesce(jsonb_agg(x.j order by x.created_at), '[]'::jsonb) from (
        select t.created_at, jsonb_build_object('ticket_id', t.id, 'number', t.number, 'customer_name', c.name,
          'equipment_type', t.equipment_type, 'work_status', t.work_status, 'custody_location', t.custody_location) j
        from private.service_tickets t left join private.customers c on c.id = t.customer_id
        where t.work_status = any (v_terminal) and t.custody_location in ('SHOP', 'FATHER')
        order by t.created_at limit 10) x),
      'scheduled_today', (select coalesce(jsonb_agg(x.j order by x.scheduled_at), '[]'::jsonb) from (
        select t.scheduled_at, jsonb_build_object('ticket_id', t.id, 'number', t.number, 'customer_name', c.name,
          'address', t.address, 'scheduled_at', t.scheduled_at, 'work_status', t.work_status) j
        from private.service_tickets t left join private.customers c on c.id = t.customer_id
        where t.scheduled_at >= v_start and t.scheduled_at < v_end and t.closed_at is null
        order by t.scheduled_at limit 20) x)),
    'low_stock', (select count(*) from private.products p where p.active and p.min_stock > 0 and
      (select coalesce(sum(s.qty_base), 0) from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
       where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE') < p.min_stock),
    'low_stock_items', (select coalesce(jsonb_agg(x.j order by x.ratio, x.name), '[]'::jsonb) from (
      select p.name, q.qty / p.min_stock ratio, jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name', p.name,
        'base_unit', p.base_unit, 'stock_shop', q.qty::text, 'min_stock', p.min_stock::text) j
      from private.products p
      cross join lateral (select coalesce(sum(s.qty_base), 0) qty from private.stock_positions s
        join private.inventory_lots l on l.id = s.lot_id
        where l.product_id = p.id and s.location = 'SHOP' and s.condition = 'SALEABLE') q
      where p.active and p.min_stock > 0 and q.qty < p.min_stock
      order by q.qty / p.min_stock, p.name limit 10) x),
    'backup', jsonb_build_object(
      'last_status', v_backup.status, 'last_started_at', v_backup.started_at,
      'last_completed_at', v_backup.completed_at, 'last_success_at', v_last_ok,
      'age_hours', case when v_last_ok is not null then round(extract(epoch from now() - v_last_ok) / 3600.0, 1) end,
      'stale', v_last_ok is null or now() - v_last_ok > interval '24 hours'));
end $$;
revoke all on function public.get_dashboard_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_dashboard_v1(jsonb) to authenticated;

-- CSV ---------------------------------------------------------------------------

-- SEC-04: netralkan formula. Termasuk teks diawali tab/CR, atau diawali
-- spasi/kontrol lalu karakter formula.
create or replace function private.csv_safe(p_text text)
returns text language plpgsql immutable set search_path = '' as $$
begin
  if p_text is null then return null; end if;
  if p_text ~ '^[=+@\t\r-]' or p_text ~ '^[[:space:][:cntrl:]]+[=+@-]' then
    return '''' || p_text;
  end if;
  return p_text;
end $$;
revoke all on function private.csv_safe(text) from public, anon, authenticated;

-- Satu sel CSV RFC 4180: selalu dikutip, tanda kutip digandakan.
create or replace function private.ops_csv_cell(p_text text)
returns text language sql immutable set search_path = '' as $$
  select '"' || replace(coalesce(p_text, ''), '"', '""') || '"'
$$;
revoke all on function private.ops_csv_cell(text) from public, anon, authenticated;

create or replace function private.ops_csv_line(p_row jsonb, p_columns text[])
returns text language sql immutable set search_path = '' as $$
  select string_agg(private.ops_csv_cell(p_row->>c), ',' order by n)
  from unnest(p_columns) with ordinality u(c, n)
$$;
revoke all on function private.ops_csv_line(jsonb, text[]) from public, anon, authenticated;

-- export_csv_v1: halaman diambil dulu (LIMIT+1 berurutan stabil), baru diagregasi.
create or replace function public.export_csv_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_dataset text; v_limit integer; v_offset integer; v_cursor jsonb;
  v_include_cost boolean; r record; v_columns text[]; v_rows jsonb; v_n integer; v_page jsonb;
  v_last jsonb; v_next jsonb; v_c_time timestamptz; v_c_key text; v_c_id uuid;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.ops_allowed_keys(p_input, array['dataset', 'start_date', 'end_date', 'limit', 'offset', 'cursor', 'include_cost']);
  v_dataset := p_input->>'dataset';
  v_limit := coalesce(private.ops_int(p_input->'limit', 'limit', false), 1000);
  v_offset := coalesce(private.ops_int(p_input->'offset', 'offset', false), 0);
  v_include_cost := private.ops_bool(p_input->'include_cost');
  if v_limit not between 1 and 1000 then
    raise exception 'INVALID_INPUT: limit 1-1000 baris per halaman' using errcode = '22023';
  end if;
  v_cursor := case when jsonb_typeof(p_input->'cursor') = 'object' then p_input->'cursor' end;
  if p_input ? 'cursor' and jsonb_typeof(p_input->'cursor') not in ('object', 'null') then
    raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
  end if;
  if v_cursor is not null and v_offset > 0 then
    raise exception 'INVALID_INPUT: Gunakan cursor atau offset, bukan keduanya' using errcode = '22023';
  end if;

  if v_dataset = 'invoices' then
    -- D2: omzet boleh untuk STAFF; dataset ini tidak memuat modal.
    if v_include_cost then
      raise exception 'INVALID_INPUT: Dataset nota tidak memiliki kolom modal' using errcode = '22023';
    end if;
    select * into r from private.date_range_input(p_input, 366);
    if v_cursor is not null then
      begin
        v_c_time := (v_cursor->>'posted_at')::timestamptz;
        v_c_id := (v_cursor->>'id')::uuid;
      exception when others then
        raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
      end;
      if v_c_time is null or v_c_id is null then
        raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
      end if;
    end if;
    v_columns := array['number', 'kind', 'posted_at', 'customer', 'petugas', 'payment_methods',
      'subtotal', 'discount', 'total'];
    select coalesce(jsonb_agg(x.j order by x.posted_at, x.id), '[]'::jsonb), count(*) into v_rows, v_n from (
      select i.id, i.posted_at, jsonb_build_object(
        '_cursor', jsonb_build_object('posted_at', i.posted_at, 'id', i.id),
        'number', private.csv_safe(i.number), 'kind', i.kind,
        'posted_at', to_char(i.posted_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'),
        'customer', private.csv_safe(coalesce(c.name, '')),
        'petugas', private.csv_safe(coalesce(ap.display_name, '')),
        'payment_methods', coalesce((
          select string_agg(distinct p.method, '+' order by p.method) from private.payments p
          where p.direction = 'IN' and p.purpose in ('SALE_RECEIPT', 'SERVICE_RECEIPT', 'PAYMENT_REPLACEMENT')
            and ((i.kind = 'SALE' and p.invoice_id = i.id)
              or (i.kind = 'SERVICE' and p.service_ticket_id = i.service_ticket_id))
            and not exists (select 1 from private.payments rv where rv.original_payment_id = p.id
                            and rv.purpose = 'PAYMENT_REVERSAL')), ''),
        'subtotal', i.subtotal_net_lines::text, 'discount', i.discount_total::text, 'total', i.total::text) j
      from private.invoices i
      left join private.customers c on c.id = i.customer_id
      left join private.app_profiles ap on ap.id = i.actor_id
      where i.posted_at >= r.start_at and i.posted_at < r.end_at
        and (v_cursor is null or (i.posted_at, i.id) > (v_c_time, v_c_id))
      order by i.posted_at, i.id
      limit v_limit + 1 offset v_offset
    ) x;

  elsif v_dataset = 'products' then
    if v_role not in ('OWNER', 'MAINTAINER') then
      raise exception 'FORBIDDEN: Ekspor katalog hanya untuk owner/maintainer' using errcode = '42501';
    end if;
    if v_include_cost and v_role <> 'OWNER' then
      raise exception 'FORBIDDEN: Ekspor nilai modal hanya untuk owner' using errcode = '42501';
    end if;
    if p_input ? 'start_date' or p_input ? 'end_date' then
      perform private.date_range_input(p_input, 366);
    end if;
    if v_cursor is not null then
      v_c_key := v_cursor->>'sku_key';
      begin
        v_c_id := (v_cursor->>'id')::uuid;
      exception when others then
        raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
      end;
      if v_c_key is null or v_c_id is null then
        raise exception 'INVALID_INPUT: cursor tidak sah' using errcode = '22023';
      end if;
    end if;
    v_columns := array['sku', 'name', 'specification', 'category', 'base_unit', 'default_unit', 'sell_price',
      'stock_shop', 'stock_field', 'stock_damaged', 'min_stock', 'shelf', 'active']
      || case when v_include_cost then array['inventory_cost'] else array[]::text[] end;
    select coalesce(jsonb_agg(x.j order by x.k, x.id), '[]'::jsonb), count(*) into v_rows, v_n from (
      select lower(p.sku) k, p.id, jsonb_build_object(
        '_cursor', jsonb_build_object('sku_key', lower(p.sku), 'id', p.id),
        'sku', private.csv_safe(p.sku), 'name', private.csv_safe(p.name),
        'specification', private.csv_safe(p.specification),
        'category', private.csv_safe(coalesce(cat.name, p.category, '')),
        'base_unit', private.csv_safe(p.base_unit), 'default_unit', private.csv_safe(u.label),
        'sell_price', u.sell_price::text,
        'stock_shop', st.shop::text, 'stock_field', st.field::text, 'stock_damaged', st.damaged::text,
        'min_stock', p.min_stock::text, 'shelf', private.csv_safe(coalesce(p.shelf, '')),
        'active', case when p.active then 'ya' else 'tidak' end)
        || case when v_include_cost then jsonb_build_object('inventory_cost', private.ops_money(
             (select sum(l.remaining_cost) from private.inventory_lots l where l.product_id = p.id))) else '{}'::jsonb end j
      from private.products p
      left join private.categories cat on cat.id = p.category_id
      left join private.product_units u on u.product_id = p.id and u.is_default and u.active
      cross join lateral (
        select coalesce(sum(s.qty_base) filter (where s.location = 'SHOP' and s.condition = 'SALEABLE'), 0) shop,
               coalesce(sum(s.qty_base) filter (where s.location = 'FIELD_FATHER' and s.condition = 'SALEABLE'), 0) field,
               coalesce(sum(s.qty_base) filter (where s.condition = 'DAMAGED'), 0) damaged
        from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id where l.product_id = p.id) st
      where v_cursor is null or (lower(p.sku), p.id) > (v_c_key, v_c_id)
      order by lower(p.sku), p.id
      limit v_limit + 1 offset v_offset
    ) x;
  else
    raise exception 'INVALID_INPUT: Dataset ekspor tidak dikenal' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(e - '_cursor' order by n), '[]'::jsonb), (array_agg(e->'_cursor' order by n desc))[1]
    into v_page, v_last
    from jsonb_array_elements(v_rows) with ordinality t(e, n) where n <= v_limit;
  v_next := case when v_n > v_limit then v_last end;

  return jsonb_build_object('ok', true, 'dataset', v_dataset, 'schema_version', 2,
    'timezone', 'Asia/Jakarta', 'columns', to_jsonb(v_columns), 'rows', v_page,
    'count', jsonb_array_length(v_page), 'offset', v_offset,
    'has_more', v_n > v_limit, 'next_cursor', v_next,
    'next_offset', case when v_n > v_limit and v_cursor is null then v_offset + v_limit end,
    'csv_header', (select string_agg(private.ops_csv_cell(c), ',' order by n) from unnest(v_columns) with ordinality u(c, n)),
    'csv_rows', (select coalesce(string_agg(private.ops_csv_line(e, v_columns), E'\r\n' order by n), '')
      from jsonb_array_elements(v_page) with ordinality t(e, n)));
end $$;
revoke all on function public.export_csv_v1(jsonb) from public, anon, authenticated;
grant execute on function public.export_csv_v1(jsonb) to authenticated;
