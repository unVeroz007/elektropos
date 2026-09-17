-- Uji baca nota: K03 (tanggal WIB), pencarian nomor, status bayar, petugas, S08 (data struk), peran.
\set ON_ERROR_STOP on

begin;
\ir sales_helpers.psql

create function pg_temp.invoice(p_number text, p_posted timestamptz, p_total numeric) returns uuid language sql as $$
  insert into private.invoices(number, kind, actor_id, posted_at, subtotal_net_lines, discount_total, total, operation_id)
  values (p_number, 'SALE', '22222222-2222-4222-8222-222222222222', p_posted, p_total, 0, p_total, gen_random_uuid())
  returning id
$$;
create function pg_temp.pay(p_invoice uuid, p_dir text, p_purpose text, p_amount numeric, p_original uuid default null)
returns uuid language sql as $$
  insert into private.payments(direction, purpose, invoice_id, method, amount, original_payment_id, actor_id, operation_id)
  values (p_dir, p_purpose, p_invoice, 'TRANSFER', p_amount, p_original, '11111111-1111-4111-8111-111111111111', gen_random_uuid())
  returning id
$$;
create function pg_temp.numbers(p_list jsonb) returns text language sql as $$
  select coalesce(string_agg(e->>'number', ',' order by e->>'number'), '') from jsonb_array_elements(p_list) e
$$;

-- K03: nota 00:30 dan 13:30 WIB tanggal 10 Maret harus muncul; 23:59:59 tanggal 9 dan 00:00 tanggal 11 tidak.
do $$
declare v_res jsonb;
begin
  perform pg_temp.invoice('UJI-0309-2359', '2026-03-09 23:59:59+07', 1000);
  perform pg_temp.invoice('UJI-0310-0030', '2026-03-10 00:30:00+07', 1000);
  perform pg_temp.invoice('UJI-0310-1330', '2026-03-10 13:30:00+07', 1000);
  perform pg_temp.invoice('UJI-0311-0000', '2026-03-11 00:00:00+07', 1000);

  v_res := pg_temp.call('staff', 'list_invoices_v1', '{"start_date":"2026-03-10","end_date":"2026-03-10"}');
  perform pg_temp.eq(pg_temp.numbers(v_res), 'UJI-0310-0030,UJI-0310-1330', 'K03: batas hari WIB');
  v_res := pg_temp.call('owner', 'list_invoices_v1', '{"start_date":"2026-03-09","end_date":"2026-03-11"}');
  perform pg_temp.eq(jsonb_array_length(v_res), 4, 'rentang 3 hari');
  v_res := pg_temp.call('maintainer', 'list_invoices_v1', '{"query":"0310"}');
  perform pg_temp.eq(pg_temp.numbers(v_res), 'UJI-0310-0030,UJI-0310-1330', 'pencarian nomor nota');
  v_res := pg_temp.call('staff', 'list_invoices_v1', '{"query":"uji-0311","limit":1}');
  perform pg_temp.eq(pg_temp.numbers(v_res), 'UJI-0311-0000', 'pencarian tanpa beda huruf');
  perform pg_temp.eq(v_res->0->>'cashier_name', 'Budi Staff', 'nama petugas');

  perform pg_temp.expect_error('disabled', 'list_invoices_v1', '{}', 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('staff', 'list_invoices_v1', '{"start_date":"2026-03-10"}', 'INVALID_DATE');
  perform pg_temp.expect_error('staff', 'list_invoices_v1', '{"start_date":"10/03/2026","end_date":"2026-03-10"}', 'INVALID_DATE');
  perform pg_temp.expect_error('staff', 'list_invoices_v1', '{"limit":500}', 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'list_invoices_v1', '{"sort":"cost"}', 'INVALID_INPUT');
end $$;

-- Status bayar: koreksi pembayaran, credit note, refund.
do $$
declare v_inv uuid; v_p uuid; v_res jsonb; v_cn uuid;
begin
  -- Belum dibayar.
  perform pg_temp.invoice('UJI-ST-UNPAID', '2026-04-01 10:00+07', 5000);
  -- Dibayar lalu dikoreksi metode (reversal + replacement): tetap lunas.
  v_inv := pg_temp.invoice('UJI-ST-CORR', '2026-04-01 10:00+07', 5000);
  v_p := pg_temp.pay(v_inv, 'IN', 'SALE_RECEIPT', 5000);
  perform pg_temp.pay(v_inv, 'OUT', 'PAYMENT_REVERSAL', 5000, v_p);
  perform pg_temp.pay(v_inv, 'IN', 'PAYMENT_REPLACEMENT', 5000, v_p);
  -- Dibayar 5.000, credit note 2.000 belum direfund: kelebihan bayar → REFUND_DUE.
  v_inv := pg_temp.invoice('UJI-ST-DUE', '2026-04-01 10:00+07', 5000);
  perform pg_temp.pay(v_inv, 'IN', 'SALE_RECEIPT', 5000);
  insert into private.credit_notes(number, invoice_id, kind, total, actor_id, operation_id)
  values ('UJI-CN-1', v_inv, 'PRICE_CORRECTION', 2000, pg_temp.uid('owner'), gen_random_uuid());
  -- Sama tetapi refund sudah dibayar: lunas.
  v_inv := pg_temp.invoice('UJI-ST-REF', '2026-04-01 10:00+07', 5000);
  v_p := pg_temp.pay(v_inv, 'IN', 'SALE_RECEIPT', 5000);
  insert into private.credit_notes(number, invoice_id, kind, total, actor_id, operation_id)
  values ('UJI-CN-2', v_inv, 'PRICE_CORRECTION', 2000, pg_temp.uid('owner'), gen_random_uuid());
  perform pg_temp.pay(v_inv, 'OUT', 'CUSTOMER_REFUND', 2000, v_p);

  v_res := pg_temp.call('owner', 'list_invoices_v1', '{"start_date":"2026-04-01","end_date":"2026-04-01"}');
  perform pg_temp.eq((select string_agg((e->>'number') || '=' || (e->>'payment_status'), ',' order by e->>'number')
    from jsonb_array_elements(v_res) e), 'UJI-ST-CORR=PAID,UJI-ST-DUE=REFUND_DUE,UJI-ST-REF=PAID,UJI-ST-UNPAID=UNPAID',
    'status bayar');
  perform pg_temp.eq((select e->>'net_received' from jsonb_array_elements(v_res) e where e->>'number' = 'UJI-ST-REF'), '3000',
    'penerimaan bersih setelah refund');
end $$;

-- S08: data struk lengkap dari penjualan nyata; STAFF tanpa modal.
do $$
declare v_sale jsonb; v_res jsonb; v_number text;
begin
  perform pg_temp.stock('a2000000-0000-4000-8000-000000000001', 5, 50000, '2026-01-01 08:00+07');
  perform pg_temp.open_drawer(0);
  v_sale := pg_temp.call('staff', 'finalize_sale_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '2')),
    'payment', jsonb_build_object('method', 'CASH', 'tendered', '50000')));
  v_number := v_sale->>'document_number';

  v_res := pg_temp.call('staff', 'get_invoice_v1', jsonb_build_object('number', v_number));
  perform pg_temp.eq(v_res->>'cashier_name', 'Budi Staff', 'struk: petugas');
  perform pg_temp.eq(v_res->'items'->0->>'unit_label', 'pcs', 'struk: satuan');
  perform pg_temp.eq(v_res->'items'->0->>'qty_sell', '2.000', 'struk: qty jual');
  perform pg_temp.eq(v_res->'items'->0->>'line_discount', '0', 'struk: diskon baris');
  perform pg_temp.eq((v_res->'payments'->0->>'method') || '/' || (v_res->'payments'->0->>'amount') || '/' ||
    (v_res->'payments'->0->>'tendered') || '/' || (v_res->'payments'->0->>'change'), 'CASH/30000/50000/20000',
    'struk: metode, dibayar, kembalian untuk staff');
  perform pg_temp.eq(v_res->'money'->>'payment_status', 'PAID', 'struk: status');
  perform pg_temp.assert(v_res::text not ilike '%cost%', 'STAFF tidak menerima modal');

  v_res := pg_temp.call('owner', 'get_invoice_v1', jsonb_build_object('invoice_id', v_sale->>'entity_id'));
  perform pg_temp.eq(v_res->'items'->0->'cost_allocations'->0->>'cost_amount', '20000.000000', 'owner melihat modal');
  perform pg_temp.call('maintainer', 'get_invoice_v1', jsonb_build_object('invoice_id', v_sale->>'entity_id'));

  -- Retur tercermin di struk: credit note, refund, qty dapat diretur.
  perform pg_temp.call('owner', 'return_sale_v1', jsonb_build_object('operation_id', gen_random_uuid(),
    'invoice_id', v_sale->>'entity_id', 'reason', 'Rusak', 'refund_method', 'CASH',
    'items', jsonb_build_array(jsonb_build_object('invoice_item_id', v_res->'items'->0->>'id', 'qty_base', '1',
      'disposition', 'DAMAGED'))));
  v_res := pg_temp.call('staff', 'get_invoice_v1', jsonb_build_object('invoice_id', v_sale->>'entity_id'));
  perform pg_temp.eq(v_res->'items'->0->>'returnable_qty', '1.000', 'qty tersisa dapat diretur');
  perform pg_temp.eq(v_res->'credits'->0->'refunds'->0->>'amount', '15000', 'refund di struk');
  perform pg_temp.eq(v_res->'money'->>'net_received', '15000', 'penerimaan bersih');
  perform pg_temp.eq(v_res->'money'->>'payment_status', 'PAID', 'tetap lunas setelah retur');
  perform pg_temp.assert(v_res::text not ilike '%cost%', 'STAFF tidak menerima modal (credit note)');

  perform pg_temp.expect_error('disabled', 'get_invoice_v1', jsonb_build_object('number', v_number), 'ACCOUNT_INACTIVE');
  perform pg_temp.expect_error('staff', 'get_invoice_v1', jsonb_build_object('number', 'TIDAK-ADA'), 'NOT_FOUND');
  perform pg_temp.expect_error('staff', 'get_invoice_v1', jsonb_build_object('number', v_number,
    'invoice_id', v_sale->>'entity_id'), 'INVALID_INPUT');
  perform pg_temp.expect_error('staff', 'get_invoice_v1', '{"invoice_id":"bukan-uuid"}', 'INVALID_INPUT');
end $$;

rollback;
