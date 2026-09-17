-- Perbaikan audit 2026-09: baca nota.
-- Menutup K03 (filter tanggal WIB), FR-POS-03 (cari nomor nota), status bayar
-- yang benar (koreksi pembayaran & credit note), S08 (data struk lengkap),
-- K01 (peran/akun aktif pada baca).

-- Ringkasan uang sebuah nota (BR-07/BR-10). Tanpa modal.
create or replace function private.sales_invoice_money(p_invoice_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.id, i.total, i.service_ticket_id from private.invoices i where i.id = p_invoice_id
  ), pay as (
    select
      coalesce(sum(p.amount) filter (where p.direction = 'IN' and p.purpose in ('SALE_RECEIPT', 'SERVICE_RECEIPT')), 0) as received,
      coalesce(sum(p.amount) filter (where p.direction = 'OUT' and p.purpose = 'CUSTOMER_REFUND'), 0) as refunded,
      coalesce(sum(case when p.purpose = 'PAYMENT_REPLACEMENT' then p.amount
                        when p.purpose = 'PAYMENT_REVERSAL' then -p.amount else 0 end), 0) as corrections
    from inv join private.payments p
      on p.invoice_id = inv.id or (inv.service_ticket_id is not null and p.service_ticket_id = inv.service_ticket_id)
  ), cr as (
    select coalesce(sum(cn.total), 0) as credit_total
    from private.credit_notes cn where cn.invoice_id = p_invoice_id
  ), calc as (
    select inv.total, cr.credit_total, inv.total - cr.credit_total as invoice_net,
      pay.received, pay.refunded, pay.corrections,
      pay.received - pay.refunded + pay.corrections as net_received
    from inv, pay, cr
  )
  select jsonb_build_object(
    'credit_total', credit_total::text, 'invoice_net', invoice_net::text,
    'received', received::text, 'refunded', refunded::text,
    'corrections', corrections::text, 'net_received', net_received::text,
    'outstanding', greatest(invoice_net - net_received, 0)::text,
    'refund_due', greatest(net_received - invoice_net, 0)::text,
    'payment_status', case
      when net_received > invoice_net then 'REFUND_DUE'
      when net_received >= invoice_net then 'PAID'
      when net_received > 0 then 'PARTIAL'
      else 'UNPAID' end)
  from calc
$$;
revoke all on function private.sales_invoice_money(uuid) from public, anon, authenticated;

-- === get_invoice_v1 ===========================================================
create or replace function public.get_invoice_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid;
  v_role text;
  v_id uuid;
  v_number text;
  v_invoice private.invoices%rowtype;
  v_cost boolean;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  v_cost := v_role in ('OWNER', 'MAINTAINER');
  perform private.sales_reject_unknown(p_input, array['invoice_id', 'number'], 'nota');
  v_id := private.sales_uuid_input(p_input->'invoice_id', 'Nota', false);
  v_number := private.sales_text_input(p_input->'number', 'Nomor nota', 60);
  if (v_id is null) = (v_number is null) then
    raise exception 'INVALID_INPUT: Isi salah satu: invoice_id atau number' using errcode = '22023';
  end if;
  select * into v_invoice from private.invoices
    where (v_id is not null and id = v_id) or (v_number is not null and lower(number) = lower(v_number));
  if not found then
    raise exception 'NOT_FOUND: Nota tidak ditemukan' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'id', v_invoice.id, 'number', v_invoice.number, 'kind', v_invoice.kind,
    'service_ticket_id', v_invoice.service_ticket_id,
    'posted_at', v_invoice.posted_at,
    'cashier_name', (select display_name from private.app_profiles where id = v_invoice.actor_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.name)
      from private.customers c where c.id = v_invoice.customer_id),
    'subtotal_net_lines', v_invoice.subtotal_net_lines::text,
    'discount_total', v_invoice.discount_total::text,
    'total', v_invoice.total::text,
    'free_reason', v_invoice.free_reason,
    'money', private.sales_invoice_money(v_invoice.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', ii.id, 'line_no', ii.line_no, 'kind', ii.kind,
        'product_id', ii.product_id, 'product_unit_id', ii.product_unit_id,
        'description', ii.description_snapshot, 'unit_label', ii.unit_label_snapshot,
        'qty_sell', ii.qty_sell::text, 'factor', ii.factor_snapshot::text, 'qty_base', ii.qty_base::text,
        'unit_price', ii.unit_price_snapshot::text,
        'discount_mode', ii.item_discount_mode, 'discount_value', ii.item_discount_value::text,
        'gross', ii.gross_exact::text,
        'line_discount', coalesce(ii.item_discount_exact, 0)::text,
        'base_net', ii.base_net::text,
        'invoice_discount_alloc', ii.invoice_discount_alloc::text,
        'net_total', ii.net_total::text,
        'returned_qty', (select coalesce(sum(cni.qty_return_base), 0)::text
          from private.credit_note_items cni where cni.invoice_item_id = ii.id),
        'returnable_qty', (ii.qty_base - (select coalesce(sum(cni.qty_return_base), 0)
          from private.credit_note_items cni where cni.invoice_item_id = ii.id))::text)
        || case when v_cost then jsonb_build_object(
          'cost_allocations', (select coalesce(jsonb_agg(jsonb_build_object(
              'id', ca.id, 'lot_id', ca.lot_id, 'lot_posted_at', l.posted_at,
              'origin_position_id', ca.origin_position_id, 'origin_label', s.label,
              'qty_base', ca.qty_base::text, 'cost_amount', ca.cost_amount::text,
              'reversed_qty', ca.reversed_qty::text, 'reversed_cost', ca.reversed_cost::text)
              order by l.posted_at, l.id, ca.origin_position_id, ca.id), '[]'::jsonb)
            from private.cost_allocations ca
            join private.inventory_lots l on l.id = ca.lot_id
            join private.stock_positions s on s.id = ca.origin_position_id
            where ca.invoice_item_id = ii.id)) else '{}'::jsonb end
        order by ii.line_no), '[]'::jsonb)
      from private.invoice_items ii where ii.invoice_id = v_invoice.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'direction', p.direction, 'purpose', p.purpose,
        'method', p.method, 'amount', p.amount::text,
        'tendered', p.tendered::text, 'change', p.change::text,
        'reference', p.reference, 'original_payment_id', p.original_payment_id,
        'actor_name', (select display_name from private.app_profiles where id = p.actor_id),
        'occurred_at', p.occurred_at)
        order by p.occurred_at, p.id), '[]'::jsonb)
      from private.payments p
      where p.invoice_id = v_invoice.id
         or (v_invoice.service_ticket_id is not null and p.service_ticket_id = v_invoice.service_ticket_id)),
    'credits', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', cn.id, 'number', cn.number, 'kind', cn.kind, 'reason', cn.reason,
        'total', cn.total::text, 'posted_at', cn.posted_at,
        'actor_name', (select display_name from private.app_profiles where id = cn.actor_id),
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'invoice_item_id', cni.invoice_item_id, 'qty_base', cni.qty_return_base::text,
            'amount', cni.amount::text, 'disposition', cni.disposition)
            || case when v_cost then jsonb_build_object('cost_reversal', cni.cost_reversal_amount::text)
               else '{}'::jsonb end
            order by cni.line_no), '[]'::jsonb)
          from private.credit_note_items cni where cni.credit_note_id = cn.id),
        'refunds', (select coalesce(jsonb_agg(jsonb_build_object(
            'payment_id', p.id, 'method', p.method, 'amount', ra.amount::text,
            'original_payment_id', ra.original_payment_id, 'occurred_at', p.occurred_at)
            order by p.occurred_at, p.id), '[]'::jsonb)
          from private.refund_allocations ra join private.payments p on p.id = ra.refund_payment_id
          where ra.credit_note_id = cn.id))
        order by cn.posted_at, cn.id), '[]'::jsonb)
      from private.credit_notes cn where cn.invoice_id = v_invoice.id),
    'schema_version', 2);
end $$;
revoke all on function public.get_invoice_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_invoice_v1(jsonb) to authenticated;

-- === list_invoices_v1 =========================================================
create or replace function public.list_invoices_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer;
  v_offset integer;
  v_start timestamptz;
  v_end timestamptz;
  v_query text;
  v_kind text;
  v_result jsonb;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  if p_input is null then p_input := '{}'::jsonb; end if;
  perform private.sales_reject_unknown(p_input, array['start_date', 'end_date', 'query', 'kind', 'limit', 'offset'],
    'riwayat nota');
  v_limit := coalesce(private.sales_int_input(p_input->'limit', 'limit'), 25);
  v_offset := coalesce(private.sales_int_input(p_input->'offset', 'offset'), 0);
  if v_limit not between 1 and 100 then
    raise exception 'INVALID_INPUT: limit harus 1-100' using errcode = '22023';
  end if;
  if p_input ? 'start_date' or p_input ? 'end_date' then
    select r.start_at, r.end_at into v_start, v_end from private.date_range_input(p_input, 366) r;
  end if;
  v_query := private.sales_text_input(p_input->'query', 'Pencarian nomor nota', 60);
  v_kind := private.sales_text_input(p_input->'kind', 'Jenis nota', 10);
  if v_kind is not null and v_kind not in ('SALE', 'SERVICE') then
    raise exception 'INVALID_INPUT: Jenis nota harus SALE atau SERVICE' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(x.row_data order by x.posted_at desc, x.id desc), '[]'::jsonb) into v_result
  from (
    select i.id, i.posted_at,
      jsonb_build_object(
        'id', i.id, 'number', i.number, 'kind', i.kind, 'posted_at', i.posted_at,
        'subtotal_net_lines', i.subtotal_net_lines::text,
        'discount_total', i.discount_total::text, 'total', i.total::text,
        'cashier_name', pr.display_name, 'customer_name', c.name,
        'payment_methods', (select coalesce(jsonb_agg(distinct p.method), '[]'::jsonb)
          from private.payments p where p.invoice_id = i.id and p.direction = 'IN'),
        'has_return', exists (select 1 from private.credit_notes cn where cn.invoice_id = i.id))
        || m.money as row_data
    from private.invoices i
    left join private.app_profiles pr on pr.id = i.actor_id
    left join private.customers c on c.id = i.customer_id
    cross join lateral (select private.sales_invoice_money(i.id) as money) m
    where (v_start is null or i.posted_at >= v_start)
      and (v_end is null or i.posted_at < v_end)
      and (v_query is null or position(lower(v_query) in lower(i.number)) > 0)
      and (v_kind is null or i.kind = v_kind)
    order by i.posted_at desc, i.id desc
    limit v_limit offset v_offset
  ) x;
  return v_result;
end $$;
revoke all on function public.list_invoices_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_invoices_v1(jsonb) to authenticated;
