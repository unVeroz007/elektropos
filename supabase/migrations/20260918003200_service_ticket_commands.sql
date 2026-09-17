-- Perbaikan audit domain SERVIS (2/5): tiket, status, detail, jadwal, custody, estimasi.
-- Temuan: T06 (BR-09), FR-SRV-01, BR-11 custody awal, konvensi require_role/idempotensi.

-- create_service_ticket_v1 — OWNER/STAFF ---------------------------------------
create or replace function public.create_service_ticket_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'create_service_ticket_v1';
  v_actor uuid;
  v_old jsonb;
  v_customer private.customers%rowtype;
  v_customer_id uuid;
  v_parent private.service_tickets%rowtype;
  v_parent_id uuid;
  v_location text;
  v_phone text;
  v_alt text;
  v_condition text;
  v_accessories text;
  v_address text;
  v_scheduled timestamptz;
  v_mechanic uuid;
  v_ticket private.service_tickets%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  perform private.srv_keys(p_input, array['operation_id', 'customer_id', 'customer_name', 'customer_phone',
    'customer_alt_contact', 'customer_address', 'parent_ticket_id', 'service_location', 'equipment_type',
    'equipment_brand', 'equipment_model', 'equipment_serial', 'complaint', 'initial_condition',
    'accessories', 'address', 'scheduled_at']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_location := coalesce(private.srv_text(p_input, 'service_location', 10), 'STORE');
  if v_location not in ('STORE', 'ONSITE') then
    raise exception 'INVALID_INPUT: Jenis layanan harus STORE (titip toko) atau ONSITE (kunjungan rumah)' using errcode = '22023';
  end if;

  -- Keluhan kembali: tiket asal hanya dibaca, tidak diubah (BR-11/WF-07).
  v_parent_id := private.srv_uuid(p_input, 'parent_ticket_id', false);
  if v_parent_id is not null then
    select * into v_parent from private.service_tickets where id = v_parent_id;
    if not found then
      raise exception 'NOT_FOUND: Tiket asal keluhan kembali tidak ditemukan' using errcode = 'P0002';
    end if;
  end if;

  -- Pelanggan: pilih yang ada, buat baru, atau pakai pelanggan tiket asal.
  v_customer_id := private.srv_uuid(p_input, 'customer_id', false);
  if v_customer_id is not null then
    if p_input ?| array['customer_name', 'customer_phone', 'customer_alt_contact', 'customer_address'] then
      raise exception 'INVALID_INPUT: Pilih pelanggan yang ada ATAU isi data pelanggan baru, bukan keduanya' using errcode = '22023';
    end if;
    select * into v_customer from private.customers where id = v_customer_id and active;
    if not found then
      raise exception 'NOT_FOUND: Pelanggan tidak ditemukan' using errcode = 'P0002';
    end if;
  elsif private.srv_text(p_input, 'customer_name', 120) is not null then
    v_phone := private.srv_phone(private.srv_text(p_input, 'customer_phone', 40));
    v_alt := private.srv_text(p_input, 'customer_alt_contact', 120);
    if v_phone is null and v_alt is null then
      raise exception 'CONTACT_REQUIRED: Isi nomor HP atau kontak lain pelanggan' using errcode = '22023';
    end if;
    insert into private.customers(name, phone_normalized, alternate_contact, address)
    values (private.srv_text(p_input, 'customer_name', 120), v_phone, v_alt,
      private.srv_text(p_input, 'customer_address', 500))
    returning * into v_customer;
  elsif v_parent_id is not null and v_parent.customer_id is not null then
    select * into v_customer from private.customers where id = v_parent.customer_id;
  else
    raise exception 'CUSTOMER_REQUIRED: Nama pelanggan wajib diisi' using errcode = '22023';
  end if;
  if v_customer.phone_normalized is null and v_customer.alternate_contact is null then
    raise exception 'CONTACT_REQUIRED: Pelanggan belum punya nomor HP atau kontak lain. Lengkapi data pelanggan dahulu.' using errcode = '22023';
  end if;

  v_condition := private.srv_text(p_input, 'initial_condition', 1000);
  v_accessories := private.srv_text(p_input, 'accessories', 500);
  if v_location = 'STORE' then
    if v_condition is null then
      raise exception 'INVALID_INPUT: Kondisi alat saat diterima wajib diisi untuk servis titip' using errcode = '22023';
    end if;
    if p_input ?| array['address', 'scheduled_at'] and
       (private.srv_text(p_input, 'address', 500) is not null or private.srv_text(p_input, 'scheduled_at', 40) is not null) then
      raise exception 'INVALID_INPUT: Alamat dan jadwal hanya untuk kunjungan rumah' using errcode = '22023';
    end if;
  else
    v_address := coalesce(private.srv_text(p_input, 'address', 500), v_customer.address);
    if v_address is null then
      raise exception 'ADDRESS_REQUIRED: Alamat kunjungan wajib diisi' using errcode = '22023';
    end if;
    v_scheduled := private.srv_ts(p_input, 'scheduled_at', false);
    if v_scheduled is null then
      raise exception 'SCHEDULE_REQUIRED: Jadwal kunjungan wajib diisi' using errcode = '22023';
    end if;
  end if;

  select id into v_mechanic from private.app_profiles
    where role = 'OWNER' and active order by created_at, id limit 1;

  insert into private.service_tickets(number, customer_id, mechanic_id, parent_ticket_id,
    service_location, custody_location, equipment_type, equipment_brand, equipment_model,
    equipment_serial, complaint, initial_condition, accessories, address, scheduled_at)
  values (private.next_stock_number('SRV'), v_customer.id, coalesce(v_mechanic, v_actor), v_parent_id,
    v_location, case when v_location = 'STORE' then 'SHOP' else 'CUSTOMER' end,
    private.srv_text(p_input, 'equipment_type', 80, true),
    private.srv_text(p_input, 'equipment_brand', 80),
    private.srv_text(p_input, 'equipment_model', 80),
    private.srv_text(p_input, 'equipment_serial', 80),
    private.srv_text(p_input, 'complaint', 1000, true),
    v_condition, v_accessories, v_address, v_scheduled)
  returning * into v_ticket;

  insert into private.service_status_events(ticket_id, from_status, to_status, kind, actor_id)
  values (v_ticket.id, null, 'NEW', 'TRANSITION', v_actor);

  -- Titip toko: alat berpindah dari pelanggan ke toko saat diterima.
  -- Kunjungan rumah: alat tetap di pelanggan, tidak ada event custody.
  if v_location = 'STORE' then
    insert into private.service_custody_events(ticket_id, from_location, to_location,
      condition_note, accessories_note, actor_id)
    values (v_ticket.id, 'CUSTOMER', 'SHOP', v_condition, v_accessories, v_actor);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CREATE_TICKET', 'SERVICE_TICKET', v_ticket.id,
    case when v_parent_id is not null then 'Keluhan kembali dari ' || v_parent.number end);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'ticket_id', v_ticket.id,
    'number', v_ticket.number, 'document_number', v_ticket.number,
    'version', v_ticket.version, 'customer_id', v_customer.id,
    'parent_ticket_id', v_parent_id, 'work_status', v_ticket.work_status,
    'service_location', v_ticket.service_location, 'custody_location', v_ticket.custody_location));
end $$;

-- transition_service_v1 — OWNER --------------------------------------------------
create or replace function public.transition_service_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'transition_service_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_target text;
  v_reason text;
  v_test text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version',
    'target_status', 'reason', 'test_result']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; pekerjaan tambahan dicatat sebagai tiket baru' using errcode = '22023';
  end if;

  v_target := private.srv_text(p_input, 'target_status', 30, true);
  v_reason := private.srv_text(p_input, 'reason', 500);
  v_test := private.srv_text(p_input, 'test_result', 500);

  if not (v_target = any (private.srv_allowed_targets(v_ticket.work_status))) then
    raise exception 'INVALID_TRANSITION: Status % tidak dapat diubah menjadi %', v_ticket.work_status, v_target
      using errcode = '22023';
  end if;
  if v_target in ('WORKING', 'WAITING_PARTS') then
    perform private.srv_require_active_approval(v_ticket.id);
  end if;
  if v_target = 'READY' then
    if v_test is null or length(v_test) < 3 then
      raise exception 'TEST_RESULT_REQUIRED: Tuliskan hasil uji alat sebelum menandai selesai (minimal 3 huruf)' using errcode = '22023';
    end if;
  elsif v_test is not null then
    raise exception 'INVALID_INPUT: Hasil uji hanya diisi saat menandai selesai (READY)' using errcode = '22023';
  end if;
  if v_target in ('AWAITING_APPROVAL', 'WAITING_PARTS', 'UNREPAIRABLE', 'CANCELLED') and v_reason is null then
    raise exception 'REASON_REQUIRED: Alasan/hasil pemeriksaan wajib diisi' using errcode = '22023';
  end if;

  update private.service_tickets set
    test_result = case when v_target = 'READY' then v_test else test_result end,
    terminal_reason = case when v_target in ('UNREPAIRABLE', 'CANCELLED') then v_reason else terminal_reason end,
    version = version + 1
  where id = v_ticket.id;
  perform private.srv_set_status(v_ticket.id, v_ticket.work_status, v_target, 'TRANSITION',
    coalesce(v_reason, v_test), v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSITION_TICKET', 'SERVICE_TICKET', v_ticket.id,
    v_ticket.work_status || ' -> ' || v_target || coalesce(': ' || v_reason, ''));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'from_status', v_ticket.work_status, 'to_status', v_target,
    'version', v_ticket.version + 1));
end $$;

-- correct_service_status_v1 — OWNER; hanya status akhir sebelum tagihan final ------
create or replace function public.correct_service_status_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'correct_service_status_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_reason text;
  v_prev text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if not private.srv_is_terminal(v_ticket.work_status) then
    raise exception 'INVALID_TRANSITION: Koreksi hanya untuk status akhir (selesai/tidak bisa diperbaiki/batal)' using errcode = '22023';
  end if;
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; koreksi status tidak diizinkan' using errcode = '22023';
  end if;
  v_reason := private.srv_text(p_input, 'reason', 500, true);

  -- Status tepat sebelum masuk status akhir menurut log.
  select e.from_status into v_prev from private.service_status_events e
    where e.ticket_id = v_ticket.id and e.to_status = v_ticket.work_status
    order by e.id desc limit 1;
  if v_prev is null or private.srv_is_terminal(v_prev) then
    raise exception 'INVALID_TRANSITION: Status sebelumnya tidak dapat ditentukan dari riwayat' using errcode = '22023';
  end if;

  update private.service_tickets set
    test_result = case when v_ticket.work_status = 'READY' then null else test_result end,
    terminal_reason = null,
    version = version + 1
  where id = v_ticket.id;
  perform private.srv_set_status(v_ticket.id, v_ticket.work_status, v_prev, 'CORRECTION', v_reason, v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CORRECT_SERVICE_STATUS', 'SERVICE_TICKET', v_ticket.id, v_reason);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'from_status', v_ticket.work_status, 'to_status', v_prev,
    'version', v_ticket.version + 1));
end $$;

-- update_service_details_v1 — OWNER; STAFF hanya saat NEW ----------------------------
create or replace function public.update_service_details_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'update_service_details_v1';
  c_fields constant text[] := array['equipment_type', 'equipment_brand', 'equipment_model',
    'equipment_serial', 'complaint', 'initial_condition', 'accessories', 'address'];
  v_actor uuid;
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_new private.service_tickets%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'reason'] || c_fields);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; data tiket tidak dapat diubah' using errcode = '22023';
  end if;
  if v_role = 'STAFF' and v_ticket.work_status <> 'NEW' then
    raise exception 'FORBIDDEN: Karyawan hanya dapat mengubah data penerimaan sebelum pemeriksaan dimulai' using errcode = '42501';
  end if;
  if not (p_input ?| c_fields) then
    raise exception 'INVALID_INPUT: Tidak ada data yang diubah' using errcode = '22023';
  end if;

  v_new := v_ticket;
  if p_input ? 'equipment_type' then v_new.equipment_type := private.srv_text(p_input, 'equipment_type', 80, true); end if;
  if p_input ? 'equipment_brand' then v_new.equipment_brand := private.srv_text(p_input, 'equipment_brand', 80); end if;
  if p_input ? 'equipment_model' then v_new.equipment_model := private.srv_text(p_input, 'equipment_model', 80); end if;
  if p_input ? 'equipment_serial' then v_new.equipment_serial := private.srv_text(p_input, 'equipment_serial', 80); end if;
  if p_input ? 'complaint' then v_new.complaint := private.srv_text(p_input, 'complaint', 1000, true); end if;
  if p_input ? 'initial_condition' then
    v_new.initial_condition := private.srv_text(p_input, 'initial_condition', 1000, v_ticket.service_location = 'STORE');
  end if;
  if p_input ? 'accessories' then v_new.accessories := private.srv_text(p_input, 'accessories', 500); end if;
  if p_input ? 'address' then
    if v_ticket.service_location <> 'ONSITE' then
      raise exception 'INVALID_INPUT: Alamat kunjungan hanya untuk kunjungan rumah' using errcode = '22023';
    end if;
    v_new.address := private.srv_text(p_input, 'address', 500, true);
  end if;

  update private.service_tickets set
    equipment_type = v_new.equipment_type, equipment_brand = v_new.equipment_brand,
    equipment_model = v_new.equipment_model, equipment_serial = v_new.equipment_serial,
    complaint = v_new.complaint, initial_condition = v_new.initial_condition,
    accessories = v_new.accessories, address = v_new.address,
    version = version + 1
  where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'UPDATE_TICKET_DETAILS', 'SERVICE_TICKET', v_ticket.id,
    coalesce(private.srv_text(p_input, 'reason', 500), '') || ' [' ||
      (select string_agg(k, ',' order by k) from jsonb_object_keys(p_input) k where k = any (c_fields)) || ']');

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- update_service_schedule_v1 — OWNER; hanya kunjungan rumah --------------------------
create or replace function public.update_service_schedule_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'update_service_schedule_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_when timestamptz;
  v_reason text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'scheduled_at', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if v_ticket.service_location <> 'ONSITE' then
    raise exception 'INVALID_INPUT: Jadwal hanya untuk kunjungan rumah' using errcode = '22023';
  end if;
  v_when := private.srv_ts(p_input, 'scheduled_at', true);
  v_reason := private.srv_text(p_input, 'reason', 500, true);

  update private.service_tickets set scheduled_at = v_when, version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RESCHEDULE_TICKET', 'SERVICE_TICKET', v_ticket.id,
    v_reason || ' (jadwal lama: ' || coalesce(v_ticket.scheduled_at::text, '-') || ', baru: ' || v_when::text || ')');

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'scheduled_at', v_when, 'version', v_ticket.version + 1));
end $$;

-- transfer_service_custody_v1 — OWNER; STAFF hanya terima alat ke toko saat NEW ---------
create or replace function public.transfer_service_custody_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'transfer_service_custody_v1';
  v_actor uuid;
  v_role text;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_to text;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version', 'to_location',
    'condition_note', 'accessories_note', 'reason']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);

  v_to := private.srv_text(p_input, 'to_location', 10, true);
  if v_to = 'CUSTOMER' then
    raise exception 'INVALID_INPUT: Pengembalian alat ke pelanggan memakai Serah Terima' using errcode = '22023';
  end if;
  if v_to not in ('SHOP', 'FATHER') then
    raise exception 'INVALID_INPUT: Lokasi alat harus SHOP (toko) atau FATHER (dibawa ayah)' using errcode = '22023';
  end if;
  if v_to = v_ticket.custody_location then
    raise exception 'INVALID_INPUT: Alat sudah berada di lokasi tersebut' using errcode = '22023';
  end if;
  if v_role = 'STAFF' and not (v_to = 'SHOP' and v_ticket.work_status = 'NEW' and v_ticket.custody_location = 'CUSTOMER') then
    raise exception 'FORBIDDEN: Karyawan hanya dapat mencatat penerimaan alat di toko untuk tiket baru' using errcode = '42501';
  end if;

  update private.service_tickets set custody_location = v_to, version = version + 1 where id = v_ticket.id;
  insert into private.service_custody_events(ticket_id, from_location, to_location,
    condition_note, accessories_note, actor_id)
  values (v_ticket.id, v_ticket.custody_location, v_to,
    private.srv_text(p_input, 'condition_note', 1000), private.srv_text(p_input, 'accessories_note', 500), v_actor);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSFER_CUSTODY', 'SERVICE_TICKET', v_ticket.id,
    v_ticket.custody_location || ' -> ' || v_to || coalesce(': ' || private.srv_text(p_input, 'reason', 500), ''));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_ticket.id, 'from_location', v_ticket.custody_location, 'custody_location', v_to,
    'version', v_ticket.version + 1));
end $$;

-- record_estimate_v1 — OWNER --------------------------------------------------------
create or replace function public.record_estimate_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'record_estimate_v1';
  v_actor uuid;
  v_old jsonb;
  v_ticket private.service_tickets%rowtype;
  v_desc text;
  v_min numeric;
  v_max numeric;
  v_rev integer;
  v_est_id uuid;
  v_status text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'ticket_id', 'expected_version',
    'description', 'min_amount', 'max_amount']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.srv_lock_ticket(private.srv_uuid(p_input, 'ticket_id'),
    private.srv_int(p_input, 'expected_version', true, 1, 2147483647));
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final; estimasi tidak dapat ditambah' using errcode = '22023';
  end if;

  v_desc := private.srv_text(p_input, 'description', 1000, true);
  v_max := private.decimal_input(p_input->'max_amount', 0, 9999999999999999, false);
  v_min := private.decimal_input_opt(p_input->'min_amount', 0, 9999999999999999, false);
  if v_min is not null and v_min > v_max then
    raise exception 'INVALID_INPUT: Estimasi minimal tidak boleh melebihi maksimal' using errcode = '22023';
  end if;

  update private.service_estimates set status = 'SUPERSEDED', version = version + 1
    where ticket_id = v_ticket.id and status in ('DRAFT', 'PROPOSED');
  select coalesce(max(revision), 0) + 1 into v_rev from private.service_estimates where ticket_id = v_ticket.id;
  insert into private.service_estimates(ticket_id, revision, description, min_amount, max_amount, status)
  values (v_ticket.id, v_rev, v_desc, v_min, v_max, 'PROPOSED')
  returning id into v_est_id;

  -- Estimasi baru berarti menunggu persetujuan (biaya baru perlu persetujuan, WF-05).
  v_status := v_ticket.work_status;
  if v_status = 'NEW' then
    perform private.srv_set_status(v_ticket.id, 'NEW', 'INSPECTING', 'TRANSITION', 'Estimasi dicatat', v_actor);
    v_status := 'INSPECTING';
  end if;
  if v_status in ('INSPECTING', 'WAITING_PARTS', 'WORKING') then
    perform private.srv_set_status(v_ticket.id, v_status, 'AWAITING_APPROVAL', 'TRANSITION',
      'Estimasi revisi ' || v_rev, v_actor);
    v_status := 'AWAITING_APPROVAL';
  end if;
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'RECORD_ESTIMATE', 'SERVICE_ESTIMATE', v_est_id, 'Revisi ' || v_rev);

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_est_id, 'estimate_id', v_est_id, 'revision', v_rev, 'estimate_version', 1,
    'work_status', v_status, 'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

-- approve_estimate_v1 — OWNER ---------------------------------------------------------
create or replace function public.approve_estimate_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_cmd constant text := 'approve_estimate_v1';
  v_actor uuid;
  v_old jsonb;
  v_est private.service_estimates%rowtype;
  v_ticket private.service_tickets%rowtype;
  v_limit numeric;
  v_method text;
  v_note text;
  v_latest integer;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.srv_keys(p_input, array['operation_id', 'estimate_id', 'expected_version',
    'agreed_limit', 'method', 'consent_note']);
  v_old := private.srv_begin(c_cmd, p_input);
  if v_old is not null then return v_old; end if;

  select * into v_est from private.service_estimates where id = private.srv_uuid(p_input, 'estimate_id');
  if not found then
    raise exception 'NOT_FOUND: Estimasi tidak ditemukan' using errcode = 'P0002';
  end if;
  -- Urutan kunci: tiket lalu estimasi.
  v_ticket := private.srv_lock_ticket(v_est.ticket_id, null);
  select * into v_est from private.service_estimates where id = v_est.id for update;
  if v_est.version <> private.srv_int(p_input, 'expected_version', true, 1, 2147483647) then
    raise exception 'VERSION_CONFLICT: Estimasi sudah berubah. Muat ulang lalu periksa kembali.' using errcode = '40001';
  end if;
  perform private.srv_require_open(v_ticket);
  if private.srv_has_invoice(v_ticket.id) then
    raise exception 'ALREADY_FINALIZED: Tagihan sudah final' using errcode = '22023';
  end if;
  select max(revision) into v_latest from private.service_estimates where ticket_id = v_ticket.id;
  if v_est.revision <> v_latest then
    raise exception 'VERSION_CONFLICT: Ada revisi estimasi yang lebih baru' using errcode = '40001';
  end if;
  if v_est.status <> 'PROPOSED' then
    raise exception 'INVALID_TRANSITION: Estimasi ini tidak sedang menunggu persetujuan' using errcode = '22023';
  end if;

  v_limit := private.decimal_input(p_input->'agreed_limit', 0, 9999999999999999, false);
  if v_limit > v_est.max_amount then
    raise exception 'INVALID_INPUT: Batas disetujui melebihi estimasi maksimal. Catat revisi estimasi baru.' using errcode = '22023';
  end if;
  v_method := private.srv_text(p_input, 'method', 20, true);
  if v_method not in ('IN_PERSON', 'PHONE', 'WHATSAPP', 'OTHER') then
    raise exception 'INVALID_INPUT: Cara persetujuan harus IN_PERSON, PHONE, WHATSAPP atau OTHER' using errcode = '22023';
  end if;
  v_note := private.srv_text(p_input, 'consent_note', 500, v_method = 'OTHER');

  update private.service_estimates set status = 'SUPERSEDED', version = version + 1
    where ticket_id = v_ticket.id and status = 'APPROVED';
  update private.service_estimates set
    status = 'APPROVED', approved_limit = v_limit, approved_method = v_method,
    approved_at = now(), approved_by = v_actor, customer_consent_note = v_note,
    version = version + 1
  where id = v_est.id;
  update private.service_tickets set version = version + 1 where id = v_ticket.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'APPROVE_ESTIMATE', 'SERVICE_ESTIMATE', v_est.id,
    'Revisi ' || v_est.revision || ' via ' || v_method || coalesce(': ' || v_note, ''));

  return private.finish_operation(c_cmd, p_input, jsonb_build_object(
    'ok', true, 'operation_id', p_input->>'operation_id', 'server_time', now(),
    'entity_id', v_est.id, 'estimate_id', v_est.id, 'revision', v_est.revision,
    'approved_limit', v_limit::text, 'estimate_version', v_est.version + 1,
    'ticket_id', v_ticket.id, 'version', v_ticket.version + 1));
end $$;

do $$ declare f text; begin
  foreach f in array array['create_service_ticket_v1', 'transition_service_v1', 'correct_service_status_v1',
    'update_service_details_v1', 'update_service_schedule_v1', 'transfer_service_custody_v1',
    'record_estimate_v1', 'approve_estimate_v1']
  loop
    execute format('revoke all on function public.%I(jsonb) from public, anon, authenticated', f);
    execute format('grant execute on function public.%I(jsonb) to authenticated', f);
  end loop;
end $$;
