-- Servis alur penuh: AT-17, AT-19, AT-20, AT-22, AT-23 + K12 (daftar tiket) + idempotensi.
-- Keputusan pemilik 18-09-2026: tanpa uang muka, bayar setelah tagihan dibuat, boleh dicicil,
-- pemilik boleh menyerahkan alat dengan sisa tagihan (piutang servis); tiket tertutup saat lunas.
\set ON_ERROR_STOP on
begin;
\ir service_helpers.psql

do $$ begin
  perform pg_temp.as_user('owner');
  perform public.post_opening_stock_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'reason', 'Stok awal uji',
    'items', jsonb_build_array(jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001',
      'qty', '10', 'acquisition_cost', '100000'))));
  perform pg_temp.open_cash('SHOP_DRAWER', 200000);
end $$;

do $$
declare
  v jsonb; v_ticket uuid; v_pos uuid; v_use uuid; v_op uuid := gen_random_uuid();
  v_pay jsonb; v_detail jsonb; v_list jsonb; v_status jsonb;
begin
  -- AT-17: STAFF menerima alat titip; custody SHOP dengan event CUSTOMER -> SHOP.
  perform pg_temp.as_user('staff');
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object(
    'customer_name', 'Joko Susilo', 'customer_phone', '+62 812-3456-7890',
    'equipment_type', 'TV', 'equipment_brand', 'Polytron', 'complaint', 'Layar gelap',
    'initial_condition', 'Casing retak kecil', 'accessories', 'Remote', 'service_location', 'STORE'));
  v_ticket := (v->>'entity_id')::uuid;
  perform pg_temp.check(v->>'custody_location' = 'SHOP' and v->>'work_status' = 'NEW', 'tiket toko custody SHOP');
  perform pg_temp.check((select phone_normalized from private.customers where id = (v->>'customer_id')::uuid) = '081234567890',
    'HP dinormalisasi');
  perform pg_temp.check((select count(*) = 1 and bool_and(from_location = 'CUSTOMER' and to_location = 'SHOP')
    from private.service_custody_events where ticket_id = v_ticket), 'event custody awal CUSTOMER->SHOP');

  -- AT-20: tanpa uang muka. Sebelum tagihan dibuat pembayaran ditolak dan laci tidak berubah.
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '50000',
    'method', 'CASH', 'tendered', '100000'), 'INVOICE_REQUIRED');
  perform pg_temp.check(pg_temp.cash_expected('SHOP_DRAWER') = 200000, 'laci tidak berubah tanpa tagihan');

  -- Estimasi -> persetujuan -> WORKING.
  perform pg_temp.to_working(v_ticket, '200000', '150000');
  perform pg_temp.check((select work_status from private.service_tickets where id = v_ticket) = 'WORKING', 'WORKING');

  -- AT-19: part dipakai sekali.
  select s.id into v_pos from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = 'a2000000-0000-4000-8000-000000000001' and s.location = 'SHOP';
  v := pg_temp.call('use_service_part_v1', jsonb_build_object('ticket_id', v_ticket,
    'expected_version', pg_temp.ver(v_ticket), 'position_id', v_pos, 'qty', '1', 'charge_unit_price', '15000'));
  v_use := (v->>'part_event_id')::uuid;
  perform pg_temp.check(v->>'cost' = '10000.000000' or (v->>'cost')::numeric = 10000, 'modal part 10.000');
  perform pg_temp.check((select qty_base from private.stock_positions where id = v_pos) = 9, 'stok berkurang 1');

  perform pg_temp.set_status(v_ticket, 'READY', jsonb_build_object('test_result', 'Gambar normal 2 jam'));

  -- Tagihan 150.000 (jasa 135.000 + part 15.000) <= batas 150.000.
  v := pg_temp.finalize(v_ticket, jsonb_build_array(
    jsonb_build_object('kind', 'LABOR', 'description', 'Ganti kapasitor', 'quantity', '1', 'unit_price', '135000'),
    jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use, 'unit_price', '15000')),
    jsonb_build_object('approved_estimate_revision', 1));
  perform pg_temp.check(v->>'total' = '150000' and v->'payment'->>'status' = 'UNPAID'
    and v->'payment'->>'outstanding' = '150000', 'tagihan 150.000 belum dibayar');
  perform pg_temp.check((select closed_at is null from private.service_tickets where id = v_ticket), 'final tidak menutup tiket');
  perform pg_temp.check((select qty_base from private.stock_positions where id = v_pos) = 9, 'finalisasi tidak mengurangi stok lagi');
  perform pg_temp.check((select cost_amount from private.service_cost_recognitions where part_event_id = v_use) = 10000,
    'COGS servis diakui sekali');

  -- Cicilan pertama tunai 50.000: kembalian dihitung server; konvensi command = nama RPC; replay tidak menggandakan.
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '50000',
    'method', 'CASH', 'tendered', '50000', 'purpose', 'DEPOSIT'), 'INVALID_INPUT');
  v_pay := pg_temp.call('record_service_payment_v1', jsonb_build_object('operation_id', v_op,
    'ticket_id', v_ticket, 'amount', '50000', 'method', 'CASH', 'tendered', '100000'));
  perform pg_temp.check(v_pay->>'purpose' = 'SETTLEMENT' and v_pay->>'change' = '50000', 'cicilan tunai + kembalian server');
  perform pg_temp.check(v_pay->'payment'->>'status' = 'PARTIAL' and v_pay->'payment'->>'outstanding' = '100000',
    'cicilan -> PARTIAL sisa 100.000');
  perform pg_temp.check(v_pay->'closed_at' = 'null'::jsonb, 'cicilan tidak menutup tiket');
  perform pg_temp.check(pg_temp.cash_expected('SHOP_DRAWER') = 250000, 'cicilan tunai masuk laci');
  v := public.get_operation_v1(jsonb_build_object('command', 'record_service_payment_v1', 'operation_id', v_op));
  perform pg_temp.check((v->>'found')::boolean and v->'result'->>'payment_id' = v_pay->>'payment_id', 'get_operation_v1 found');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('operation_id', v_op,
    'ticket_id', v_ticket, 'amount', '50000', 'method', 'CASH', 'tendered', '100000'));
  perform pg_temp.check(v->>'payment_id' = v_pay->>'payment_id', 'replay sama');
  perform pg_temp.check((select count(*) from private.payments where service_ticket_id = v_ticket) = 1, 'replay tidak menggandakan');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('operation_id', v_op,
    'ticket_id', v_ticket, 'amount', '60000', 'method', 'CASH', 'tendered', '100000'), 'IDEMPOTENCY_CONFLICT');

  -- STAFF melihat detail tanpa modal; READY + PARTIAL tetap belum diambil.
  v_detail := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_ticket));
  perform pg_temp.check(v_detail->'customer'->>'name' = 'Joko Susilo' and v_detail->'customer'->>'phone' = '081234567890', 'detail pelanggan');
  perform pg_temp.check(jsonb_array_length(v_detail->'estimates') = 1 and v_detail->'estimates'->0->>'approved_limit' = '150000', 'detail estimasi');
  perform pg_temp.check(v_detail->'part_events'->0->>'product_name' = 'Lampu LED 10 Watt' and v_detail->'part_events'->0->'cost' = 'null'::jsonb,
    'part tanpa modal untuk staff');
  perform pg_temp.check(v_detail->'invoice'->'cost_recognized' = 'null'::jsonb, 'invoice tanpa modal untuk staff');
  perform pg_temp.check(v_detail->'payments'->0->>'cashbox' = 'SHOP_DRAWER' and v_detail->'payments'->0->>'method' = 'CASH', 'detail pembayaran');
  perform pg_temp.check((v_detail->>'not_picked_up')::boolean, 'belum diambil');

  -- Melebihi sisa ditolak; cicilan kedua 40.000 diterima (TRANSFER wajib konfirmasi).
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '100001',
    'method', 'TRANSFER', 'confirmed', true), 'PAYMENT_AMOUNT_MISMATCH');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '40000',
    'method', 'TRANSFER'), 'CONFIRMATION_REQUIRED');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '40000',
    'method', 'TRANSFER', 'confirmed', true));
  perform pg_temp.check(v->'payment'->>'status' = 'PARTIAL' and v->'payment'->>'outstanding' = '60000', 'cicilan kedua sisa 60.000');

  -- Serah terima dengan sisa tagihan: tanpa izin ditolak; karyawan tidak boleh memutuskan piutang.
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_ticket,
    'expected_version', pg_temp.ver(v_ticket), 'receiver_name', 'Joko'), 'PAYMENT_OUTSTANDING');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_ticket,
    'expected_version', pg_temp.ver(v_ticket), 'receiver_name', 'Joko', 'allow_unpaid', true,
    'unpaid_note', 'Bayar Jumat'), 'FORBIDDEN');

  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '60000',
    'method', 'TRANSFER', 'confirmed', true, 'purpose', 'SETTLEMENT'));
  perform pg_temp.check(v->'payment'->>'status' = 'PAID' and v->'payment'->>'net_received' = '150000', 'PAID 150.000');
  perform pg_temp.check(v->'closed_at' = 'null'::jsonb, 'lunas sebelum diserahkan: tiket tetap terbuka sampai diambil');
  perform pg_temp.check(pg_temp.cash_expected('SHOP_DRAWER') = 250000, 'transfer tidak mengubah laci');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '1',
    'method', 'QRIS', 'confirmed', true), 'ALREADY_SETTLED');

  -- AT-22: READY + PAID + SHOP masih belum diambil sampai serah terima.
  v_list := pg_temp.call('list_service_tickets_v1', jsonb_build_object('not_picked_up', true));
  perform pg_temp.check(jsonb_array_length(v_list->'items') = 1 and v_list->'items'->0->>'payment_status' = 'PAID', 'daftar belum diambil');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_ticket,
    'expected_version', pg_temp.ver(v_ticket)), 'INVALID_INPUT');
  v := pg_temp.call('handover_service_v1', jsonb_build_object('ticket_id', v_ticket,
    'expected_version', pg_temp.ver(v_ticket), 'receiver_name', 'Joko'));
  perform pg_temp.check(v->>'custody_location' = 'CUSTOMER' and v->>'closed_at' is not null
    and v->>'completed_at' is not null and v->>'outstanding' = '0', 'serah terima lunas menutup');
  perform pg_temp.check((select is_handover and receiver_name = 'Joko' from private.service_custody_events
    where ticket_id = v_ticket order by id desc limit 1), 'event handover');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_ticket, 'amount', '1000',
    'method', 'QRIS', 'confirmed', true), 'TICKET_CLOSED');

  -- Invariant: penerimaan 150.000 dan pendapatan 150.000 sekali.
  perform pg_temp.check((select sum(total) from private.invoices where service_ticket_id = v_ticket) = 150000, 'revenue sekali');
  perform pg_temp.check((select sum(amount) from private.payments where service_ticket_id = v_ticket) = 150000, 'penerimaan 150.000');
end $$;

-- AT-17 onsite + AT-22 tutup tanpa status diambil palsu + AT-23 keluhan kembali.
do $$
declare v jsonb; v_onsite uuid; v_parent uuid; v_child uuid; v_before private.service_tickets%rowtype;
begin
  perform pg_temp.as_user('owner');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'Sari', 'customer_phone', '085678901234',
    'equipment_type', 'AC', 'complaint', 'Tidak dingin', 'service_location', 'ONSITE',
    'scheduled_at', '2026-09-20T09:00:00+07:00'), 'ADDRESS_REQUIRED');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'Sari', 'customer_phone', '085678901234',
    'equipment_type', 'AC', 'complaint', 'Tidak dingin', 'service_location', 'ONSITE', 'address', 'Jl. Melati 3'), 'SCHEDULE_REQUIRED');
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object('customer_name', 'Sari', 'customer_phone', '085678901234',
    'equipment_type', 'AC', 'complaint', 'Tidak dingin', 'service_location', 'ONSITE', 'address', 'Jl. Melati 3',
    'scheduled_at', '2026-09-20T09:00:00+07:00'));
  v_onsite := (v->>'entity_id')::uuid;
  perform pg_temp.check(v->>'custody_location' = 'CUSTOMER', 'onsite custody CUSTOMER');
  perform pg_temp.check(not exists (select 1 from private.service_custody_events where ticket_id = v_onsite), 'tanpa event custody palsu');

  perform pg_temp.to_working(v_onsite, '100000', '100000');
  perform pg_temp.set_status(v_onsite, 'READY', jsonb_build_object('test_result', 'Dingin 18 derajat'));
  perform pg_temp.finalize(v_onsite, pg_temp.labor('100000'), jsonb_build_object('approved_estimate_revision', 1));
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_onsite,
    'expected_version', pg_temp.ver(v_onsite), 'receiver_name', 'Sari'), 'INVALID_CUSTODY');
  perform pg_temp.fail('close_onsite_service_v1', jsonb_build_object('ticket_id', v_onsite,
    'expected_version', pg_temp.ver(v_onsite)), 'PAYMENT_OUTSTANDING');
  perform pg_temp.fail('close_onsite_service_v1', jsonb_build_object('ticket_id', v_onsite,
    'expected_version', pg_temp.ver(v_onsite), 'allow_unpaid', true, 'unpaid_note', ' '), 'REASON_REQUIRED');
  perform pg_temp.open_cash('FATHER_WALLET', 0);
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_onsite, 'amount', '60000',
    'method', 'CASH', 'cashbox', 'FATHER_WALLET', 'tendered', '60000'));
  perform pg_temp.check(pg_temp.cash_expected('FATHER_WALLET') = 60000 and pg_temp.cash_expected('SHOP_DRAWER') = 250000,
    'tunai onsite masuk dompet ayah, bukan laci');
  -- Pemilik menutup kunjungan dengan sisa 40.000 (piutang); pelunasan berikutnya menutup tiket.
  v := pg_temp.call('close_onsite_service_v1', jsonb_build_object('ticket_id', v_onsite,
    'expected_version', pg_temp.ver(v_onsite), 'completion_note', 'Selesai di rumah',
    'allow_unpaid', true, 'unpaid_note', 'Sisa ditransfer besok'));
  perform pg_temp.check(v->>'outstanding' = '40000' and v->'closed_at' = 'null'::jsonb, 'kunjungan selesai dengan piutang');
  perform pg_temp.check((select completed_at is not null and closed_at is null and custody_location = 'CUSTOMER'
    from private.service_tickets where id = v_onsite)
    and not exists (select 1 from private.service_custody_events where ticket_id = v_onsite), 'tutup onsite tanpa serah terima');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_onsite, 'amount', '40000',
    'method', 'TRANSFER', 'confirmed', true));
  perform pg_temp.check(v->>'closed_at' is not null, 'piutang kunjungan lunas menutup tiket');

  -- AT-23: keluhan kembali memakai pelanggan tiket asal; tiket asal tidak berubah.
  select id into v_parent from private.service_tickets where closed_at is not null and service_location = 'STORE';
  select * into v_before from private.service_tickets where id = v_parent;
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object('parent_ticket_id', v_parent,
    'equipment_type', 'TV', 'complaint', 'Layar gelap lagi', 'initial_condition', 'Sama seperti sebelumnya'));
  v_child := (v->>'entity_id')::uuid;
  perform pg_temp.check((select customer_id from private.service_tickets where id = v_child) = v_before.customer_id, 'pelanggan tiket asal');
  perform pg_temp.check((select row(t.*)::text from private.service_tickets t where id = v_parent) = row(v_before.*)::text,
    'tiket asal tidak berubah');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('parent_ticket_id', gen_random_uuid(),
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'NOT_FOUND');
  v := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_parent));
  perform pg_temp.check(v->'child_tickets'->0->>'id' = v_child::text, 'detail tiket asal menampilkan keluhan kembali');
end $$;

-- K12: daftar tiket (filter, pencarian nomor/nama/HP, tertutup opsional, pagination).
do $$
declare v jsonb; v_all jsonb; v_number text; v_p1 jsonb; v_p2 jsonb;
begin
  perform pg_temp.as_user('staff');
  v := pg_temp.call('list_service_tickets_v1', '{}'::jsonb);
  perform pg_temp.check(jsonb_array_length(v->'items') = 1, 'default hanya tiket aktif');
  v_all := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true));
  perform pg_temp.check(jsonb_array_length(v_all->'items') = 3, 'termasuk tertutup');
  select number into v_number from private.service_tickets where service_location = 'ONSITE';
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'query', v_number));
  perform pg_temp.check(jsonb_array_length(v->'items') = 1 and v->'items'->0->>'number' = v_number, 'cari nomor');
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'query', 'sari'));
  perform pg_temp.check(jsonb_array_length(v->'items') = 1 and v->'items'->0->>'customer_name' = 'Sari', 'cari nama');
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'query', '+62 811 9999'));
  perform pg_temp.check(jsonb_array_length(v->'items') = 0, 'HP tidak cocok');
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'query', '0812-3456'));
  perform pg_temp.check(jsonb_array_length(v->'items') = 2, 'cari HP ternormalisasi');
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('status', jsonb_build_array('NEW')));
  perform pg_temp.check(jsonb_array_length(v->'items') = 1 and v->'items'->0->>'payment_status' = 'UNPRICED', 'filter status');
  v_p1 := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'limit', 2));
  perform pg_temp.check(jsonb_array_length(v_p1->'items') = 2 and v_p1->>'next_cursor' is not null, 'halaman 1');
  v_p2 := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true, 'limit', 2,
    'cursor', v_p1->>'next_cursor'));
  perform pg_temp.check(jsonb_array_length(v_p2->'items') = 1 and v_p2->'next_cursor' = 'null'::jsonb
    and v_p2->'items'->0->>'id' = v_all->'items'->2->>'id', 'halaman 2');
  perform pg_temp.as_user('maint');
  v := pg_temp.call('list_service_tickets_v1', jsonb_build_object('include_closed', true));
  perform pg_temp.check(jsonb_array_length(v->'items') = 3 and v->'items'->0->'customer_phone' = 'null'::jsonb, 'maintainer baca tanpa kontak');
end $$;

-- Piutang servis: pemilik menyerahkan alat dengan sisa tagihan; cicilan berikutnya melunasi dan menutup tiket.
do $$
declare v jsonb; v_t uuid; v_list jsonb;
begin
  perform pg_temp.as_user('staff');
  v_t := pg_temp.new_store_ticket('Budi Piutang', '081277778888');
  perform pg_temp.to_working(v_t, '80000', '80000');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Normal'));
  perform pg_temp.finalize(v_t, pg_temp.labor('80000'), jsonb_build_object('approved_estimate_revision', 1));
  perform pg_temp.as_user('staff');
  perform pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '30000',
    'method', 'CASH', 'tendered', '30000'));

  perform pg_temp.as_user('owner');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Budi', 'allow_unpaid', true), 'REASON_REQUIRED');
  v := pg_temp.call('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Budi', 'allow_unpaid', true, 'unpaid_note', 'Sisa dibayar gajian tgl 25'));
  perform pg_temp.check(v->>'completed_at' is not null and v->'closed_at' = 'null'::jsonb and v->>'outstanding' = '50000',
    'diserahkan dengan sisa 50.000, tiket belum tertutup');
  perform pg_temp.check((select a.reason like '%sisa tagihan 50000%' from private.audit_events a
    where a.entity_id = v_t and a.action = 'HANDOVER_SERVICE'), 'audit mencatat sisa tagihan');

  v := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_t));
  perform pg_temp.check((v->>'receivable')::boolean and v->>'receivable_note' = 'Sisa dibayar gajian tgl 25'
    and not (v->>'not_picked_up')::boolean and jsonb_array_length(v->'allowed_transitions') = 0, 'detail piutang');
  v_list := pg_temp.call('list_service_tickets_v1', jsonb_build_object('receivable', true));
  perform pg_temp.check(jsonb_array_length(v_list->'items') = 1 and v_list->'items'->0->>'outstanding' = '50000'
    and (v_list->'items'->0->>'receivable')::boolean, 'daftar piutang');
  v := public.get_dashboard_v1('{}');
  perform pg_temp.check((v->'service'->>'receivable_count')::integer = 1 and v->'service'->>'receivable_total' = '50000',
    'beranda piutang servis');

  -- Layanan selesai: pekerjaan/perpindahan tidak dapat diubah lagi, hanya pembayaran.
  perform pg_temp.fail('transfer_service_custody_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'to_location', 'SHOP'), 'TICKET_COMPLETED');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Budi'), 'TICKET_COMPLETED');

  perform pg_temp.as_user('staff');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '20000',
    'method', 'CASH', 'tendered', '20000'));
  perform pg_temp.check(v->'closed_at' = 'null'::jsonb and v->'payment'->>'outstanding' = '30000', 'cicilan piutang');
  v := pg_temp.call('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '30000',
    'method', 'QRIS', 'confirmed', true));
  perform pg_temp.check(v->'payment'->>'status' = 'PAID' and v->>'closed_at' is not null, 'lunas menutup tiket');
  perform pg_temp.check((select closed_at is not null and receivable_note is null from private.service_tickets where id = v_t),
    'tiket tertutup, catatan piutang dibersihkan');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1',
    'method', 'QRIS', 'confirmed', true), 'TICKET_CLOSED');
  v_list := pg_temp.call('list_service_tickets_v1', jsonb_build_object('receivable', true));
  perform pg_temp.check(jsonb_array_length(v_list->'items') = 0, 'piutang lunas hilang dari daftar');
end $$;

rollback;
