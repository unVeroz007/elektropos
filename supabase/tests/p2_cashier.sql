-- AT-07/09/10/11/13/24/25: pengujian kasir P2.
\set ON_ERROR_STOP on

begin;

select set_config('role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

-- AT-24: buka kas laci SHOP_DRAWER Rp200.000
do $$
declare v_res jsonb;
begin
  v_res := public.open_cash_session_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000001',
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '200000'));
  if not (v_res->>'ok')::boolean then raise exception 'Gagal buka kas'; end if;
end $$;

-- AT-09/15: stok awal dulu untuk penjualan
do $$
begin
  perform public.post_opening_stock_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000002',
    'reason', 'Stok untuk kasir',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
        'qty', '10', 'acquisition_cost', '100000'))));
end $$;

-- AT-09: finalisasi penjualan tunai (1 pcs lampu Rp15.000, bayar Rp20.000, kembalian Rp5.000)
do $$
declare v_res jsonb;
begin
  v_res := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000003',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1')),
    'payment', jsonb_build_object('method', 'CASH', 'tendered', '20000')));
  if not (v_res->>'ok')::boolean then raise exception 'Finalisasi sale gagal'; end if;
  if v_res->>'total' <> '15000' then raise exception 'Total salah: %', v_res->>'total'; end if;
  if v_res->>'change' <> '5000' then raise exception 'Kembalian salah: %', v_res->>'change'; end if;
end $$;

-- AT-10: retry dengan key & payload sama -> idempoten
do $$
declare v_res1 jsonb; v_res2 jsonb;
begin
  v_res1 := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000003',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '1')),
    'payment', jsonb_build_object('method', 'CASH', 'tendered', '20000')));
  if v_res1->>'document_number' is null then raise exception 'Idempotency gagal'; end if;
end $$;

-- AT-07: diskon item & nota oleh owner
do $$
declare v_res jsonb;
begin
  v_res := public.finalize_sale_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000004',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
        'qty', '2', 'discount_mode', 'amount', 'discount_value', '5000')), -- gross 30000 - 5000 = 25000
    'discount_mode', 'amount', 'discount_value', '2000', -- total 23000
    'payment', jsonb_build_object('method', 'CASH', 'tendered', '25000')));
  if v_res->>'total' <> '23000' then raise exception 'Diskon total salah: %', v_res->>'total'; end if;
end $$;

-- AT-13: retur parsial
select set_config('role', 'postgres', true);
do $$
declare v_inv_id uuid; v_item_id uuid; v_res jsonb;
begin
  select id into v_inv_id from private.invoices where operation_id = 'd0000000-0000-4000-8000-000000000003';
  select id into v_item_id from private.invoice_items where invoice_id = v_inv_id limit 1;

  perform set_config('role', 'authenticated', true);
  v_res := public.return_sale_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000005',
    'invoice_id', v_inv_id,
    'refund_method', 'CASH',
    'reason', 'Salah beli',
    'items', jsonb_build_array(
      jsonb_build_object('invoice_item_id', v_item_id, 'qty_base', '1', 'disposition', 'SALEABLE'))));
  perform set_config('role', 'postgres', true);
  if not (v_res->>'ok')::boolean then raise exception 'Retur gagal'; end if;
  if v_res->>'refund_total' <> '15000' then raise exception 'Refund total salah: %', v_res->>'refund_total'; end if;
end $$;
select set_config('role', 'authenticated', true);

-- AT-24: kas laci terhitung: buka 200rb + masuk 15rb + masuk 23rb - refund 15rb = 223rb
select set_config('role', 'postgres', true);

do $$
declare v_exp numeric;
begin
  v_exp := private.cash_session_expected((select id from private.cash_sessions where status='OPEN'));
  if v_exp <> 223000 then
    raise exception 'Expected cashbox salah: seharusnya 223000, dapat %', v_exp;
  end if;
end $$;

select set_config('role', 'authenticated', true);

-- AT-25: tutup kas dengan counted 222.000 -> selisih -1.000 (perlu note)
select set_config('role', 'postgres', true);
do $$
declare v_sess_id uuid; v_ver integer; v_res jsonb;
begin
  select id, version into v_sess_id, v_ver from private.cash_sessions where status='OPEN';
  perform set_config('role', 'authenticated', true);
  v_res := public.close_cash_session_v1(jsonb_build_object(
    'operation_id', 'd0000000-0000-4000-8000-000000000006',
    'session_id', v_sess_id, 'expected_version', v_ver,
    'counted_amount', '222000', 'note', 'Selisih Rp1.000 hilang'));
  if not (v_res->>'ok')::boolean then raise exception 'Tutup kas gagal'; end if;
  if v_res->>'variance' <> '-1000' then raise exception 'Variance salah: %', v_res->>'variance'; end if;
end $$;

rollback;
