-- Servis: peran, akun nonaktif, tabel transisi WF-05 (AT-18), persetujuan (T06), K08, K07, validasi intake.
\set ON_ERROR_STOP on
begin;
\ir service_helpers.psql

-- Peran & akun nonaktif.
do $$
declare v_t uuid; v jsonb;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket();

  perform pg_temp.as_user('off');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'X', 'customer_phone', '0811111111',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'ACCOUNT_INACTIVE');
  perform pg_temp.fail('get_service_ticket_v1', jsonb_build_object('ticket_id', v_t), 'ACCOUNT_INACTIVE');
  perform pg_temp.fail('list_service_tickets_v1', '{}'::jsonb, 'ACCOUNT_INACTIVE');
  perform pg_temp.fail('search_customers_v1', '{}'::jsonb, 'ACCOUNT_INACTIVE');

  perform pg_temp.as_user('maint');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'X', 'customer_phone', '0811111111',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'FORBIDDEN');
  perform pg_temp.fail('record_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'QRIS', 'confirmed', true), 'FORBIDDEN');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'receiver_name', 'X'), 'FORBIDDEN');
  perform pg_temp.fail('upsert_customer_v1', jsonb_build_object('name', 'X', 'phone', '0811111111'), 'FORBIDDEN');
  v := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_t));
  perform pg_temp.check(v->>'number' is not null and v->'customer'->'phone' = 'null'::jsonb, 'maintainer baca tanpa kontak');

  perform pg_temp.as_user('staff');
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'target_status', 'INSPECTING'), 'FORBIDDEN');
  perform pg_temp.fail('record_estimate_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'description', 'x', 'max_amount', '1000'), 'FORBIDDEN');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1), 'FORBIDDEN');
  perform pg_temp.fail('refund_service_payment_v1', jsonb_build_object('ticket_id', v_t, 'amount', '1000',
    'method', 'QRIS', 'reason', 'x'), 'FORBIDDEN');
  perform pg_temp.fail('close_onsite_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1), 'FORBIDDEN');
  perform pg_temp.fail('correct_service_status_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'reason', 'x'), 'FORBIDDEN');
  perform pg_temp.fail('update_service_schedule_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'scheduled_at', '2026-10-01T10:00:00+07:00', 'reason', 'x'), 'FORBIDDEN');

  -- STAFF boleh ubah detail intake saat NEW; kolom tak dikenal ditolak.
  v := pg_temp.call('update_service_details_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'accessories', 'Remote + kabel'));
  perform pg_temp.check((v->>'version')::int = 2, 'staff ubah detail saat NEW');
  perform pg_temp.fail('update_service_details_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 2,
    'work_status', 'READY'), 'INVALID_INPUT');
  perform pg_temp.fail('update_service_details_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'accessories', 'x'), 'VERSION_CONFLICT');
  perform pg_temp.fail('get_service_ticket_v1', jsonb_build_object('ticket_id', gen_random_uuid()), 'NOT_FOUND');

  -- anon tidak dapat mengeksekusi RPC servis.
  perform set_config('role', 'anon', true);
  begin
    perform public.list_service_tickets_v1('{}'::jsonb);
    raise exception 'GAGAL: anon dapat membaca daftar tiket';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user('owner');
  perform pg_temp.check(jsonb_typeof(public.list_service_tickets_v1('{}'::jsonb)->'items') = 'array', 'authenticated boleh');
  perform set_config('role', 'postgres', true);
end $$;

-- AT-18: tabel transisi seluruh pasangan status (tanpa pintasan).
do $$
declare
  c_all constant text[] := array['NEW', 'INSPECTING', 'AWAITING_APPROVAL', 'WAITING_PARTS', 'WORKING',
    'READY', 'UNREPAIRABLE', 'CANCELLED'];
  c_allowed constant jsonb := '{"NEW":["INSPECTING","CANCELLED"],"INSPECTING":["AWAITING_APPROVAL","UNREPAIRABLE","CANCELLED"],
    "AWAITING_APPROVAL":["WORKING","WAITING_PARTS","CANCELLED"],
    "WAITING_PARTS":["WORKING","AWAITING_APPROVAL","UNREPAIRABLE","CANCELLED"],
    "WORKING":["READY","WAITING_PARTS","AWAITING_APPROVAL","UNREPAIRABLE","CANCELLED"],
    "READY":[],"UNREPAIRABLE":[],"CANCELLED":[]}';
  v_from text; v_to text; v_t uuid; v_ok boolean; v_err text; v_n int := 0;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Transisi', '081299990000');
  -- Persetujuan aktif agar syarat persetujuan tidak mengaburkan uji tabel.
  perform pg_temp.call('record_estimate_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'description', 'x', 'max_amount', '100000'));
  perform pg_temp.call('approve_estimate_v1', jsonb_build_object('estimate_id',
    (select id from private.service_estimates where ticket_id = v_t), 'expected_version', 1, 'agreed_limit', '100000',
    'method', 'IN_PERSON'));
  foreach v_from in array c_all loop
    foreach v_to in array c_all loop
      update private.service_tickets set work_status = v_from where id = v_t;
      begin
        perform pg_temp.call('transition_service_v1', jsonb_build_object('ticket_id', v_t,
          'expected_version', pg_temp.ver(v_t), 'target_status', v_to, 'reason', 'Uji tabel')
          || case when v_to = 'READY' then jsonb_build_object('test_result', 'Nyala normal') else '{}' end);
        v_ok := true;
      exception when others then
        v_ok := false; v_err := sqlerrm;
        if position('INVALID_TRANSITION:' in sqlerrm) <> 1 then
          raise exception 'GAGAL: % -> % error tak terduga: %', v_from, v_to, sqlerrm;
        end if;
      end;
      if v_ok <> (c_allowed->v_from ? v_to) then
        raise exception 'GAGAL: transisi % -> % seharusnya %', v_from, v_to, c_allowed->v_from ? v_to;
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  perform pg_temp.check(v_n = 64, 'seluruh 64 pasangan diuji');
end $$;

-- T06: persetujuan wajib; READY wajib hasil uji nyata; approve hanya revisi PROPOSED terbaru.
do $$
declare v_t uuid; v jsonb; v_e1 uuid; v_e2 uuid;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Persetujuan', '081288880000');
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'target_status', 'WORKING'), 'INVALID_TRANSITION');
  perform pg_temp.set_status(v_t, 'INSPECTING');
  perform pg_temp.set_status(v_t, 'AWAITING_APPROVAL', jsonb_build_object('reason', 'Kapasitor bocor'));
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'WORKING'), 'APPROVAL_REQUIRED');

  v := pg_temp.call('record_estimate_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'description', 'Ganti kapasitor', 'min_amount', '80000', 'max_amount', '120000'));
  v_e1 := (v->>'estimate_id')::uuid;
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'WORKING'), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 1,
    'agreed_limit', '130000', 'method', 'PHONE'), 'INVALID_INPUT');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 1,
    'agreed_limit', '100000'), 'INVALID_INPUT');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 1,
    'agreed_limit', '100000.5', 'method', 'PHONE'), 'INVALID_NUMBER');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 1,
    'agreed_limit', 100000, 'method', 'PHONE'), 'INVALID_NUMBER');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 1,
    'agreed_limit', '100000', 'method', 'SMS'), 'INVALID_INPUT');

  -- Revisi baru menggantikan revisi lama; revisi lama tidak dapat disetujui.
  v := pg_temp.call('record_estimate_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'description', 'Ganti kapasitor + fuse', 'max_amount', '100000'));
  v_e2 := (v->>'estimate_id')::uuid;
  perform pg_temp.check((select status from private.service_estimates where id = v_e1) = 'SUPERSEDED', 'revisi lama superseded');
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e1, 'expected_version', 2,
    'agreed_limit', '100000', 'method', 'PHONE'), 'VERSION_CONFLICT');
  perform pg_temp.call('approve_estimate_v1', jsonb_build_object('estimate_id', v_e2, 'expected_version', 1,
    'agreed_limit', '100000', 'method', 'WHATSAPP', 'consent_note', 'Chat 09.12'));
  perform pg_temp.fail('approve_estimate_v1', jsonb_build_object('estimate_id', v_e2, 'expected_version', 2,
    'agreed_limit', '100000', 'method', 'PHONE'), 'INVALID_TRANSITION');
  perform pg_temp.set_status(v_t, 'WORKING');

  -- Biaya baru saat WORKING -> kembali menunggu persetujuan, WORKING ditolak sampai disetujui.
  v := pg_temp.call('record_estimate_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'description', 'Tambah ganti trafo', 'max_amount', '250000'));
  perform pg_temp.check(v->>'work_status' = 'AWAITING_APPROVAL', 'estimasi baru -> menunggu persetujuan');
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'WORKING'), 'APPROVAL_REQUIRED');
  perform pg_temp.call('approve_estimate_v1', jsonb_build_object('estimate_id', v->>'estimate_id', 'expected_version', 1,
    'agreed_limit', '200000', 'method', 'PHONE'));
  perform pg_temp.check((select status from private.service_estimates where id = v_e2) = 'SUPERSEDED', 'persetujuan lama digantikan');
  perform pg_temp.set_status(v_t, 'WORKING');

  -- READY tanpa hasil uji / hasil uji palsu pendek ditolak.
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'READY'), 'TEST_RESULT_REQUIRED');
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'READY', 'test_result', 'OK'), 'TEST_RESULT_REQUIRED');
  perform pg_temp.fail('transition_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'target_status', 'CANCELLED'), 'REASON_REQUIRED');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Nyala 1 jam, suara normal'));
  perform pg_temp.check((select test_result from private.service_tickets where id = v_t) = 'Nyala 1 jam, suara normal', 'hasil uji tersimpan');

  -- Koreksi status akhir: alasan wajib, kembali ke WORKING, test_result dihapus.
  perform pg_temp.fail('correct_service_status_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t)),
    'INVALID_INPUT');
  v := pg_temp.call('correct_service_status_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'reason', 'Ternyata masih mati'));
  perform pg_temp.check(v->>'to_status' = 'WORKING' and (select test_result is null from private.service_tickets where id = v_t),
    'koreksi ke WORKING');
  perform pg_temp.fail('correct_service_status_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'reason', 'x'), 'INVALID_TRANSITION');

  -- AT-18 K08: batas 200.000, tagihan 250.000 ditolak; tagihan 200.000 diterima tanpa menutup tiket.
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Nyala normal setelah trafo'));
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 3, 'charge_lines', pg_temp.labor('250000')), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'charge_lines', pg_temp.labor('150000')), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 2, 'charge_lines', pg_temp.labor('100000')), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 3, 'charge_lines', jsonb_build_array(jsonb_build_object('kind', 'BONUS',
      'description', 'x', 'quantity', '1', 'unit_price', '1000'))), 'INVALID_INPUT');
  v := pg_temp.finalize(v_t, pg_temp.labor('200000'), jsonb_build_object('approved_estimate_revision', 3));
  perform pg_temp.check(v->>'total' = '200000' and v->'payment'->>'status' = 'UNPAID', 'final tepat batas');
  perform pg_temp.check((select closed_at is null from private.service_tickets where id = v_t), 'final tidak menutup');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 3, 'charge_lines', pg_temp.labor('1')), 'ALREADY_FINALIZED');
  perform pg_temp.fail('correct_service_status_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'reason', 'x'), 'ALREADY_FINALIZED');

  -- K07: tiket final tapi belum dibayar tidak dapat diserahkan.
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Budi'), 'PAYMENT_OUTSTANDING');
end $$;

-- Bukti bug audit: K08 (batas 100.000, tagihan 5.000.000) dan K07 (READY tanpa invoice diserahkan).
do $$
declare v_t uuid;
begin
  perform pg_temp.as_user('owner');
  v_t := pg_temp.new_store_ticket('Bukti Bug', '081277770000');
  perform pg_temp.to_working(v_t, '100000', '100000');
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Nyala normal'));
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', pg_temp.labor('5000000')), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Siapa saja'), 'INVOICE_REQUIRED');
  perform pg_temp.fail('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Siapa saja', 'location', 'CUSTOMER'), 'INVALID_INPUT');
  perform pg_temp.check((select closed_at is null and custody_location = 'SHOP' from private.service_tickets where id = v_t),
    'tiket tetap terbuka');

  -- Pembatalan tanpa persetujuan: invoice 0 hanya dengan alasan pembebasan (AT-21).
  v_t := pg_temp.new_store_ticket('Batal Awal', '081277771111');
  perform pg_temp.set_status(v_t, 'CANCELLED', jsonb_build_object('reason', 'Pelanggan batal'));
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'charge_lines', '[]'::jsonb), 'APPROVAL_REQUIRED');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'waiver_reason', 'Gratis', 'charge_lines', pg_temp.labor('20000')), 'APPROVAL_REQUIRED');
  perform pg_temp.finalize(v_t, '[]'::jsonb, jsonb_build_object('waiver_reason', 'Belum dikerjakan, biaya dibebaskan'));
  perform pg_temp.check((pg_temp.state(v_t))->>'status' = 'PAID', 'invoice 0 + net 0 = PAID');
  perform pg_temp.as_user('staff');
  perform pg_temp.call('handover_service_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'receiver_name', 'Pemilik alat'));
end $$;

-- Validasi intake & custody (FR-SRV-01, BR-11).
do $$
declare v jsonb; v_t uuid;
begin
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'Tanpa Kontak',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'CONTACT_REQUIRED');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_phone', '081234000000',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'CUSTOMER_REQUIRED');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'HP Salah', 'customer_phone', '12ab',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x'), 'INVALID_PHONE');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'Tanpa Kondisi', 'customer_phone', '081234000000',
    'equipment_type', 'TV', 'complaint', 'x'), 'INVALID_INPUT');
  perform pg_temp.fail('create_service_ticket_v1', jsonb_build_object('customer_name', 'A', 'customer_phone', '081234000000',
    'equipment_type', 'TV', 'complaint', 'x', 'initial_condition', 'x', 'service_location', 'HOME'), 'INVALID_INPUT');
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object('customer_name', 'Kontak Lain',
    'customer_alt_contact', 'Tetangga: Bu Ani', 'equipment_type', 'Kipas', 'complaint', 'Berisik',
    'initial_condition', 'Baling retak'));
  perform pg_temp.check(v->>'ok' = 'true', 'kontak alternatif cukup');

  -- Onsite: alat dibawa pelanggan ke toko -> staff terima saat NEW; staff tidak bisa pindah ke FATHER.
  perform pg_temp.as_user('owner');
  v := pg_temp.call('create_service_ticket_v1', jsonb_build_object('customer_name', 'Rumah', 'customer_phone', '081200002222',
    'customer_address', 'Jl. Kenanga 1', 'equipment_type', 'Pompa', 'complaint', 'Mati', 'service_location', 'ONSITE',
    'scheduled_at', '2026-09-21T10:00:00+07:00'));
  v_t := (v->>'entity_id')::uuid;
  perform pg_temp.check((select address from private.service_tickets where id = v_t) = 'Jl. Kenanga 1', 'alamat dari pelanggan');
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('transfer_service_custody_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'to_location', 'FATHER'), 'FORBIDDEN');
  perform pg_temp.fail('transfer_service_custody_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'to_location', 'CUSTOMER'), 'INVALID_INPUT');
  perform pg_temp.call('transfer_service_custody_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'to_location', 'SHOP', 'condition_note', 'Dibawa pelanggan'));
  perform pg_temp.as_user('owner');
  perform pg_temp.call('update_service_schedule_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'scheduled_at', '2026-09-22T10:00:00+07:00', 'reason', 'Pelanggan minta besok'));
  perform pg_temp.call('transfer_service_custody_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'to_location', 'FATHER'));
  perform pg_temp.check((select string_agg(coalesce(from_location, '-') || '>' || to_location, ',' order by id)
    from private.service_custody_events where ticket_id = v_t) = 'CUSTOMER>SHOP,SHOP>FATHER', 'riwayat custody');
  perform pg_temp.set_status(v_t, 'INSPECTING');
  perform pg_temp.as_user('staff');
  perform pg_temp.fail('update_service_details_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'accessories', 'x'), 'FORBIDDEN');
end $$;

rollback;
