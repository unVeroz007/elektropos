-- K13/S07: foto tiket. Policy Storage dapat dievaluasi role authenticated (bug lama:
-- permission denied for function can_write_attachment), finalize hanya pembuat/OWNER dan
-- wajib objek nyata dengan ukuran/mime sesuai, kuota 5 menghitung READY + PENDING aktif.
-- Upload Storage disimulasikan dengan INSERT storage.objects sebagai authenticated.
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
-- Simulasi Storage API: INSERT ... RETURNING dengan role authenticated (RLS aktif).
create function pg_temp.upload(p_sub text, p_key text, p_size bigint, p_mime text) returns void language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('request.jwt.claim.sub', p_sub, true);
  perform set_config('role', 'authenticated', true);
  insert into storage.objects(bucket_id, name, owner, metadata)
    values ('ticket-photos', p_key, p_sub::uuid, jsonb_build_object('size', p_size, 'mimetype', p_mime))
    returning id into v_id;
  perform set_config('role', 'postgres', true);
end $$;
create function pg_temp.visible(p_sub text, p_key text) returns boolean language plpgsql as $$
declare v boolean;
begin
  perform set_config('request.jwt.claim.sub', p_sub, true);
  perform set_config('role', 'authenticated', true);
  select exists (select 1 from storage.objects where bucket_id = 'ticket-photos' and name = p_key) into v;
  perform set_config('role', 'postgres', true);
  return v;
end $$;
create function pg_temp.prepare(p_sub text, p_ticket uuid, p_size bigint default 1000) returns jsonb language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_sub, true);
  return public.prepare_attachment_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'ticket_id', p_ticket,
    'mime', 'image/jpeg', 'byte_size', p_size));
end $$;

grant select, insert on storage.objects to authenticated;
insert into storage.buckets(id, name, public) values ('ticket-photos', 'ticket-photos', false) on conflict (id) do nothing;
insert into auth.users(id, email) values ('55555555-5555-4555-8555-555555555555', 'staff2@test.local');
insert into private.app_profiles(id, display_name, role, active) values ('55555555-5555-4555-8555-555555555555', 'Staff Dua', 'STAFF', true);
create temp table t(name text primary key, id uuid, key text);
grant all on t to public;
with x as (
  insert into private.service_tickets(number, mechanic_id, service_location, custody_location, equipment_type, complaint)
  values ('FOTO-1', '11111111-1111-4111-8111-111111111111', 'STORE', 'SHOP', 'Kipas', 'Mati') returning id)
insert into t(name, id) select 'ticket', id from x;

-- Hak akses schema/helper: hanya authenticated.
do $$
begin
  if not has_schema_privilege('authenticated', 'storage_access', 'usage') or has_schema_privilege('anon', 'storage_access', 'usage')
     or not has_function_privilege('authenticated', 'storage_access.can_upload_ticket_photo(text)', 'execute')
     or not has_function_privilege('authenticated', 'storage_access.can_read_ticket_photo(text)', 'execute')
     or has_function_privilege('anon', 'storage_access.can_read_ticket_photo(text)', 'execute') then
    raise exception 'K13: hak akses storage_access salah';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and coalesce(qual, '') || coalesce(with_check, '') like '%private.%') then
    raise exception 'K13: policy Storage masih memanggil helper schema private';
  end if;
end $$;

-- Alur normal STAFF: prepare -> upload (authenticated, policy) -> finalize.
do $$
declare v_ticket uuid := (select id from t where name = 'ticket'); v jsonb; v_key text;
begin
  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 2048);
  v_key := v->>'object_key';
  insert into t values ('staff_slot', (v->>'entity_id')::uuid, v_key);
  if v->>'state' <> 'PENDING' or v_key !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$' or v->>'upload_expires_at' is null then
    raise exception 'prepare hasil salah %', v;
  end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'prepare_attachment_v1', 'operation_id', v->>'operation_id'))->>'found')::boolean then
    raise exception 'get_operation_v1 prepare_attachment_v1 tidak ditemukan';
  end if;

  -- Finalize sebelum upload ditolak (bug lama: READY tanpa objek).
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select public.finalize_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'attachment_id', v->>'entity_id')), 'ATTACHMENT_INVALID');

  -- Upload oleh akun lain / nonaktif / key tak dikenal ditolak policy (bukan permission denied fungsi).
  perform pg_temp.expect_error(format('select pg_temp.upload(%L, %L, 2048, %L)', '11111111-1111-4111-8111-111111111111', v_key, 'image/jpeg'), 'row-level security');
  perform set_config('role', 'postgres', true);
  perform pg_temp.expect_error(format('select pg_temp.upload(%L, %L, 2048, %L)', '44444444-4444-4444-8444-444444444444', v_key, 'image/jpeg'), 'row-level security');
  perform set_config('role', 'postgres', true);
  perform pg_temp.expect_error(format('select pg_temp.upload(%L, %L, 2048, %L)', '22222222-2222-4222-8222-222222222222', 'liar/key.jpg', 'image/jpeg'), 'row-level security');
  perform set_config('role', 'postgres', true);

  -- Pembuat slot boleh unggah (INSERT ... RETURNING butuh policy baca untuk slot PENDING miliknya).
  perform pg_temp.upload('22222222-2222-4222-8222-222222222222', v_key, 2048, 'image/jpeg');
  if not pg_temp.visible('22222222-2222-4222-8222-222222222222', v_key) then
    raise exception 'Pembuat slot harus dapat membaca objek PENDING miliknya';
  end if;
  if pg_temp.visible('33333333-3333-4333-8333-333333333333', v_key) then
    raise exception 'Objek PENDING tidak boleh terbaca akun lain';
  end if;

  -- Staff lain tidak boleh finalisasi slot orang lain.
  perform pg_temp.act('55555555-5555-4555-8555-555555555555');
  perform pg_temp.expect_error(format('select public.finalize_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'attachment_id', v->>'entity_id')), 'NOT_FOUND');

  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  v := public.finalize_attachment_v1(jsonb_build_object('operation_id', 'd6000000-0000-4000-8000-000000000001',
    'attachment_id', (select id from t where name = 'staff_slot')));
  if v->>'state' <> 'READY' then raise exception 'finalize gagal %', v; end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'finalize_attachment_v1',
      'operation_id', 'd6000000-0000-4000-8000-000000000001'))->>'found')::boolean then
    raise exception 'get_operation_v1 finalize_attachment_v1 tidak ditemukan';
  end if;
  perform pg_temp.expect_error(format('select public.finalize_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'attachment_id', (select id from t where name = 'staff_slot'))), 'ALREADY_FINALIZED');
  if not pg_temp.visible('33333333-3333-4333-8333-333333333333', v_key)
     or pg_temp.visible('44444444-4444-4444-8444-444444444444', v_key) then
    raise exception 'Foto READY: maintainer harus bisa baca, akun nonaktif tidak';
  end if;
end $$;

-- Objek yang ukuran/mime-nya berbeda dari slot ditolak; OWNER boleh finalisasi slot staff.
do $$
declare v_ticket uuid := (select id from t where name = 'ticket'); v jsonb;
begin
  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 5000);
  perform pg_temp.upload('22222222-2222-4222-8222-222222222222', v->>'object_key', 5001, 'image/jpeg');
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select public.finalize_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'attachment_id', v->>'entity_id')), 'ATTACHMENT_INVALID');

  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 6000);
  perform pg_temp.upload('22222222-2222-4222-8222-222222222222', v->>'object_key', 6000, 'image/png');
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select public.finalize_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'attachment_id', v->>'entity_id')), 'ATTACHMENT_INVALID');

  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 7000);
  perform pg_temp.upload('22222222-2222-4222-8222-222222222222', v->>'object_key', 7000, 'image/jpeg');
  perform pg_temp.act('11111111-1111-4111-8111-111111111111');
  if public.finalize_attachment_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'attachment_id', v->>'entity_id'))->>'state' <> 'READY' then
    raise exception 'OWNER harus boleh finalisasi slot staff';
  end if;
end $$;

-- Kuota: READY(2) + PENDING aktif(2) = 4 -> satu slot lagi boleh, berikutnya STORAGE_LIMIT.
-- Slot PENDING kedaluwarsa tidak menghalangi dan tidak bisa diunggah.
do $$
declare v_ticket uuid := (select id from t where name = 'ticket'); v jsonb; v_expired text;
begin
  -- Saat ini: READY 2, PENDING aktif 2 (ukuran/mime salah).
  update private.attachments set created_at = now() - interval '31 minutes'
    where ticket_id = v_ticket and state = 'PENDING' and byte_size = 5000 returning object_key into v_expired;
  -- READY 2 + PENDING aktif 1 = 3.
  perform pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket);
  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 9000);
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select pg_temp.prepare(%L, %L)', '22222222-2222-4222-8222-222222222222', v_ticket), 'STORAGE_LIMIT');

  -- Kedaluwarsakan satu slot lagi -> ruang kuota kembali.
  update private.attachments set created_at = now() - interval '2 hours' where id = (v->>'entity_id')::uuid;
  v := pg_temp.prepare('22222222-2222-4222-8222-222222222222', v_ticket, 9100);
  perform pg_temp.expect_error(format('select pg_temp.upload(%L, %L, 1000, %L)', '22222222-2222-4222-8222-222222222222',
    (select object_key from private.attachments where byte_size = 9000), 'image/jpeg'), 'row-level security');
  perform set_config('role', 'postgres', true);
  if (select count(*) from private.attachments where ticket_id = v_ticket) <> 7 then
    raise exception 'Kuota: jumlah slot tidak sesuai skenario';
  end if;
end $$;

-- Baca: list/get hanya READY; validasi input; anon ditolak.
do $$
declare v_ticket uuid := (select id from t where name = 'ticket'); v jsonb;
begin
  perform pg_temp.act('33333333-3333-4333-8333-333333333333');
  v := public.list_attachments_v1(jsonb_build_object('ticket_id', v_ticket));
  if jsonb_array_length(v) <> 2 or exists (select 1 from jsonb_array_elements(v) e where e->>'state' <> 'READY') then
    raise exception 'list_attachments_v1 salah %', v;
  end if;
  if public.get_attachment_url_v1(jsonb_build_object('attachment_id', v->0->>'id'))->>'bucket' <> 'ticket-photos' then
    raise exception 'get_attachment_url_v1 salah';
  end if;
  perform pg_temp.expect_error(format('select public.get_attachment_url_v1(%L)', jsonb_build_object('attachment_id',
    (select id from private.attachments where state = 'PENDING' limit 1))), 'NOT_FOUND');
  perform pg_temp.expect_error('select public.list_attachments_v1(''{}'')', 'INVALID_INPUT');
  perform pg_temp.expect_error(format('select public.prepare_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'ticket_id', v_ticket, 'mime', 'image/jpeg', 'byte_size', 10)), 'FORBIDDEN');
  perform pg_temp.act('22222222-2222-4222-8222-222222222222');
  perform pg_temp.expect_error(format('select public.prepare_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'ticket_id', v_ticket, 'mime', 'image/svg+xml', 'byte_size', 10)), 'ATTACHMENT_INVALID');
  perform pg_temp.expect_error(format('select public.prepare_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'ticket_id', v_ticket, 'mime', 'image/jpeg', 'byte_size', '1.5')), 'ATTACHMENT_INVALID');
  perform pg_temp.expect_error(format('select public.prepare_attachment_v1(%L)', jsonb_build_object(
    'operation_id', gen_random_uuid(), 'product_id', 'a2000000-0000-4000-8000-000000000001', 'mime', 'image/jpeg', 'byte_size', 10)), 'FORBIDDEN');
  perform pg_temp.act('44444444-4444-4444-8444-444444444444');
  perform pg_temp.expect_error(format('select public.list_attachments_v1(%L)', jsonb_build_object('ticket_id', v_ticket)), 'ACCOUNT_INACTIVE');
  perform set_config('role', 'anon', true);
  perform pg_temp.expect_error(format('select public.list_attachments_v1(%L)', jsonb_build_object('ticket_id', v_ticket)), 'permission denied');
  perform set_config('role', 'postgres', true);
end $$;

rollback;
