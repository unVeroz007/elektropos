-- Servis: uang. K09 (kas), BR-10 status, AT-20/AT-21 refund, credit note, koreksi pembayaran.
\set ON_ERROR_STOP on
begin;
\ir service_helpers.psql

-- K09: tunai wajib sesi terbuka milik cashbox; tidak menerima cash_session_id/change dari klien.
do $$
declare v_t uuid; v jsonb; v_closed uuid;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Kas', '081211110000');
  perform pg_temp.as_user('staff');
  -- Bukti bug: CASH 50.000 tanpa sesi dulu diterima tanpa masuk laci.
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '50000',
    'method', 'CASH', 'tendered', '50000'), 'CASH_SESSION_CLOSED');
  -- Bukti bug: staff menulis ke sesi FATHER_WALLET tertutup lewat cash_session_id.
  v_closed := pg_temp.open_cash('FATHER_WALLET', 0);
  update private.cash_sessions set status = 'CLOSED', closed_at = now() where id = v_closed;
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '70000',
    'method', 'CASH', 'tendered', '70000', 'cash_session_id', v_closed), 'INVALID_INPUT');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '70000',
    'method', 'CASH', 'tendered', '70000', 'cashbox', 'FATHER_WALLET'), 'FORBIDDEN');
  perform pg_temp.as_user('owner');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '70000',
    'method', 'CASH', 'tendered', '70000', 'cashbox', 'FATHER_WALLET'), 'CASH_SESSION_CLOSED');
  perform pg_temp.check(not exists (select 1 from private.cash_movements where session_id = v_closed), 'sesi tertutup tidak berubah');

  perform pg_temp.open_cash('SHOP_DRAWER', 100000);
  perform pg_temp.as_user('staff');
  -- Bukti bug: tendered=1 change=999999 dulu tersimpan.
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '50000',
    'method', 'CASH', 'tendered', '1', 'change', '999999'), 'INVALID_INPUT');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '50000',
    'method', 'CASH', 'tendered', '1'), 'INSUFFICIENT_TENDERED');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '50000',
    'method', 'CASH'), 'TENDERED_REQUIRED');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '0',
    'method', 'QRIS', 'confirmed', true), 'INVALID_NUMBER');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '5000',
    'method', 'DEBIT', 'confirmed', true), 'INVALID_INPUT');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '5000',
    'method', 'QRIS', 'confirmed', true, 'tendered', '5000'), 'INVALID_INPUT');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '5000',
    'method', 'QRIS', 'confirmed', true, 'purpose', 'SETTLEMENT'), 'INVALID_INPUT');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '50000',
    'method', 'CASH', 'tendered', '60000'));
  perform pg_temp.check(v->>'change' = '10000' and v->>'cashbox' = 'SHOP_DRAWER', 'kembalian dihitung server');
  perform pg_temp.check((select tendered = 60000 and change = 10000 and cash_session_id is not null from private.payments
    where id = (v->>'payment_id')::uuid), 'tersimpan konsisten');
  perform pg_temp.check(pg_temp.cash_expected('SHOP_DRAWER') = 150000, 'laci +50.000 (bukan tendered)');
  -- DP kedua boleh sebelum final.
  perform pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '30000',
    'method', 'QRIS', 'confirmed', true, 'reference', 'QR-123'));
  -- intent sama tidak boleh dua pembayaran.
  perform pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'QRIS', 'confirmed', true, 'payment_intent_id', 'dddddddd-0000-4000-8000-000000000001'));
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'QRIS', 'confirmed', true, 'payment_intent_id', 'dddddddd-0000-4000-8000-000000000001'), 'IDEMPOTENCY_CONFLICT');
  perform pg_temp.check((pg_temp.state(v_t))->>'net_received' = '81000' and (pg_temp.state(v_t))->>'status' = 'UNPRICED', 'DP 81.000 UNPRICED');

  -- Sebelum final: refund hanya untuk tiket batal.
  perform pg_temp.as_user('owner');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'CASH', 'reason', 'Salah catat'), 'INVOICE_REQUIRED');
end $$;

-- AT-20/AT-21: DP 100.000, final 80.000 -> REFUND_DUE 20.000; refund lintas dua receipt; revenue tetap.
do $$
declare v_t uuid; v jsonb; v_s jsonb; v_r1 uuid; v_r2 uuid;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('DP Lebih', '081222220000');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '10000',
    'method', 'CASH', 'tendered', '10000'));
  v_r1 := (v->>'payment_id')::uuid;
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '90000',
    'method', 'TRANSFER', 'confirmed', true));
  v_r2 := (v->>'payment_id')::uuid;
  -- Dalam satu transaksi uji now() sama; DP pertama dibuat lebih awal agar urutan alokasi pasti.
  update private.payments set occurred_at = now() - interval '1 day' where id = v_r1;
  perform pg_temp.to_working(v_t, '150000', '150000');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Kipas berputar normal'));
  v := pg_temp.finalize(v_t, pg_temp.labor('80000'), jsonb_build_object('approved_estimate_revision', 1));
  v_s := v->'payment';
  perform pg_temp.check(v_s->>'status' = 'REFUND_DUE' and v_s->>'refund_due' = '20000' and v_s->>'outstanding' = '0', 'REFUND_DUE 20.000');

  -- Pembayaran setelah lunas ditolak; serah terima ditolak sampai refund.
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'QRIS', 'confirmed', true), 'ALREADY_SETTLED');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'X'), 'REFUND_DUE');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '20001',
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'Kelebihan DP'), 'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '20000',
    'reason', 'Kelebihan DP'), 'INVALID_INPUT');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '20000',
    'method', 'TRANSFER', 'reason', 'Kelebihan DP'), 'CONFIRMATION_REQUIRED');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '20000',
    'method', 'TRANSFER', 'confirmed', true), 'INVALID_INPUT');

  -- Refund tunai dengan saldo kurang ditolak atomik; setelah dana ditambah, operasi identik berhasil.
  perform pg_temp.open_cash('FATHER_WALLET', 5000);
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('operation_id', 'eeeeeeee-0000-4000-8000-000000000001',
    'ticket_id', v_t, 'amount', '20000', 'method', 'CASH', 'cashbox', 'FATHER_WALLET', 'reason', 'Kelebihan DP'), 'INSUFFICIENT_CASH');
  perform pg_temp.check(not exists (select 1 from private.payments where service_ticket_id = v_t and direction = 'OUT'), 'tidak ada efek parsial');
  insert into private.cash_movements(session_id, direction, kind, amount, reason, actor_id, operation_id)
  select id, 'IN', 'OWNER_ADD', 50000, 'Tambah modal laci', '11111111-1111-4111-8111-111111111111', gen_random_uuid()
    from private.cash_sessions where cashbox_id = 'FATHER_WALLET' and status = 'OPEN';
  v := pg_temp.call('refund_service_payment_v1', jsonb_build_object('operation_id', 'eeeeeeee-0000-4000-8000-000000000001',
    'ticket_id', v_t, 'amount', '20000', 'method', 'CASH', 'cashbox', 'FATHER_WALLET', 'reason', 'Kelebihan DP'));
  perform pg_temp.check(jsonb_array_length(v->'allocations') = 2, 'refund dialokasikan ke dua receipt');
  perform pg_temp.check((select amount from private.refund_allocations where original_payment_id = v_r1) = 10000
    and (select amount from private.refund_allocations where original_payment_id = v_r2) = 10000, 'alokasi 10.000 + 10.000');
  perform pg_temp.check(v->'payment'->>'status' = 'PAID' and v->'payment'->>'refund_due' = '0', 'setelah refund PAID');
  perform pg_temp.check(pg_temp.cash_expected('FATHER_WALLET') = 5000 + 50000 - 20000
    and pg_temp.cash_expected('SHOP_DRAWER') = 160000, 'dompet berkurang 20.000, laci tetap');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'CASH', 'reason', 'Lagi'), 'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.check((select total from private.invoices where service_ticket_id = v_t) = 80000, 'revenue tetap 80.000');

  -- Credit note: kurangi tagihan 30.000 -> refund_due derived 30.000.
  perform pg_temp.fail('credit_service_invoice_v1', jsonb_build_object('invoice_id', (v->'payment'->>'invoice_id'),
    'expected_version', pg_temp.ver(v_t), 'lines', jsonb_build_array(jsonb_build_object('invoice_item_id',
      (select id from private.invoice_items where invoice_id = (v->'payment'->>'invoice_id')::uuid), 'amount', '30000'))),
    'INVALID_INPUT');
  perform pg_temp.fail('credit_service_invoice_v1', jsonb_build_object('invoice_id', (v->'payment'->>'invoice_id'),
    'expected_version', pg_temp.ver(v_t), 'reason', 'Diskon', 'lines', jsonb_build_array(jsonb_build_object('invoice_item_id',
      (select id from private.invoice_items where invoice_id = (v->'payment'->>'invoice_id')::uuid), 'amount', '80001'))),
    'REFUND_LIMIT_EXCEEDED');
  v := pg_temp.call('credit_service_invoice_v1', jsonb_build_object('invoice_id', (v->'payment'->>'invoice_id'),
    'expected_version', pg_temp.ver(v_t), 'reason', 'Jasa dikurangi', 'lines', jsonb_build_array(jsonb_build_object('invoice_item_id',
      (select id from private.invoice_items where invoice_id = (v->'payment'->>'invoice_id')::uuid), 'amount', '30000'))));
  perform pg_temp.check(v->'payment'->>'invoice_net' = '50000' and v->'payment'->>'refund_due' = '30000'
    and v->'payment'->>'status' = 'REFUND_DUE', 'credit note -> refund_due');
  perform pg_temp.fail('credit_service_invoice_v1', jsonb_build_object('invoice_id', (v->'payment'->>'invoice_id'),
    'expected_version', pg_temp.ver(v_t), 'reason', 'Lagi', 'lines', jsonb_build_array(jsonb_build_object('invoice_item_id',
      (select id from private.invoice_items where invoice_id = (v->'payment'->>'invoice_id')::uuid), 'amount', '50001'))),
    'REFUND_LIMIT_EXCEEDED');
  v := pg_temp.call('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '30000',
    'method', 'TRANSFER', 'confirmed', true, 'reason', 'Kompensasi potongan'));
  perform pg_temp.check(v->'payment'->>'status' = 'PAID', 'refund credit selesai');
  perform pg_temp.check((select coalesce(sum(amount), 0) from private.refund_allocations where original_payment_id = v_r1) <= 10000
    and (select coalesce(sum(amount), 0) from private.refund_allocations where original_payment_id = v_r2) <= 90000, 'refund <= receipt');
  perform pg_temp.call('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Pemilik'));
end $$;

-- AT-21: pembatalan DP 100.000 + invoice 0 -> refund 100.000; sebelum final hanya batal.
do $$
declare v_t uuid; v jsonb;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Batal DP', '081233330000');
  perform pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '100000',
    'method', 'QRIS', 'confirmed', true));
  perform pg_temp.set_status(v_t, 'CANCELLED', jsonb_build_object('reason', 'Pelanggan batal'));
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '100001',
    'method', 'QRIS', 'confirmed', true, 'reason', 'Batal'), 'REFUND_LIMIT_EXCEEDED');
  v := pg_temp.finalize(v_t, '[]'::jsonb, jsonb_build_object('waiver_reason', 'Batal sebelum dikerjakan'));
  perform pg_temp.check(v->'payment'->>'status' = 'REFUND_DUE' and v->'payment'->>'refund_due' = '100000', 'DP tidak hangus');
  v := pg_temp.call('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '100000',
    'method', 'QRIS', 'confirmed', true, 'reason', 'Batal'));
  perform pg_temp.check(v->'payment'->>'status' = 'PAID' and v->'payment'->>'net_received' = '0', 'batal selesai');
end $$;

-- BR-10: koreksi metode pembayaran (PAYMENT_REVERSAL/REPLACEMENT) ikut net_received; receipt terbalik tidak direfund.
do $$
declare v_t uuid; v jsonb; v_orig uuid; v_repl uuid;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Koreksi', '081244440000');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '60000',
    'method', 'TRANSFER', 'confirmed', true));
  v_orig := (v->>'payment_id')::uuid;
  insert into private.payments(direction, purpose, service_ticket_id, method, amount, original_payment_id, actor_id, operation_id)
  values ('OUT', 'PAYMENT_REVERSAL', v_t, 'TRANSFER', 60000, v_orig, '11111111-1111-4111-8111-111111111111', gen_random_uuid());
  insert into private.payments(direction, purpose, service_ticket_id, method, amount, original_payment_id, actor_id, operation_id)
  values ('IN', 'PAYMENT_REPLACEMENT', v_t, 'QRIS', 60000, v_orig, '11111111-1111-4111-8111-111111111111', gen_random_uuid())
  returning id into v_repl;
  perform pg_temp.check((pg_temp.state(v_t))->>'net_received' = '60000' and (pg_temp.state(v_t))->>'correction_net' = '0',
    'koreksi tidak mengubah net_received');
  perform pg_temp.to_working(v_t, '50000', '50000');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Normal kembali'));
  perform pg_temp.finalize(v_t, pg_temp.labor('50000'), jsonb_build_object('approved_estimate_revision', 1));
  v := pg_temp.call('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '10000',
    'method', 'QRIS', 'confirmed', true, 'reason', 'Kelebihan'));
  perform pg_temp.check(v->'allocations'->0->>'payment_id' = v_repl::text and jsonb_array_length(v->'allocations') = 1,
    'refund mengacu receipt pengganti');

  -- Status UNPAID/PARTIAL/PAID.
  v_t := pg_temp.new_store_ticket('Status', '081255550000');
  perform pg_temp.check((pg_temp.state(v_t))->>'status' = 'UNPRICED' and (pg_temp.state(v_t))->'outstanding' = 'null'::jsonb, 'UNPRICED');
  perform pg_temp.to_working(v_t, '90000', '90000');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Normal kembali'));
  perform pg_temp.finalize(v_t, pg_temp.labor('90000'), jsonb_build_object('approved_estimate_revision', 1));
  perform pg_temp.check((pg_temp.state(v_t))->>'status' = 'UNPAID' and (pg_temp.state(v_t))->>'outstanding' = '90000', 'UNPAID');
  -- Setelah final tidak boleh cicil.
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '45000',
    'method', 'QRIS', 'confirmed', true), 'PAYMENT_AMOUNT_MISMATCH');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '90001',
    'method', 'QRIS', 'confirmed', true), 'PAYMENT_AMOUNT_MISMATCH');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '90000',
    'method', 'QRIS', 'confirmed', true, 'purpose', 'DEPOSIT'), 'INVALID_INPUT');
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('get_service_payment_status_v1', jsonb_build_object('ticket_id', gen_random_uuid()), 'NOT_FOUND');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '90000',
    'method', 'QRIS', 'confirmed', true));
  perform pg_temp.check(v->>'purpose' = 'SETTLEMENT' and v->'payment'->>'status' = 'PAID', 'staff pelunasan tepat -> PAID');
end $$;

rollback;
