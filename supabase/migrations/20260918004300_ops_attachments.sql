-- Perbaikan audit 2026-09: foto tiket (K13, S07).
-- Bug: policy storage.objects memanggil private.can_*_attachment yang EXECUTE-nya
-- dicabut dan schema private tanpa USAGE -> upload/signed URL 403.
-- Perbaikan: helper pindah ke schema khusus storage_access (USAGE+EXECUTE hanya
-- authenticated, SECURITY DEFINER, search_path kosong, cek akun aktif).

create schema if not exists storage_access;
revoke all on schema storage_access from public, anon;
grant usage on schema storage_access to authenticated;
alter default privileges in schema storage_access revoke execute on functions from public;

-- Masa berlaku slot PENDING; slot kedaluwarsa tidak menghitung kuota dan tidak bisa diunggah.
create or replace function private.attachment_pending_ttl()
returns interval language sql immutable set search_path = '' as $$ select interval '30 minutes' $$;
revoke all on function private.attachment_pending_ttl() from public, anon, authenticated;

-- Baca objek: foto READY untuk akun aktif; pembuat slot PENDING yang masih berlaku juga
-- boleh (Storage API membaca baris baru saat INSERT ... RETURNING).
create or replace function storage_access.can_read_ticket_photo(p_object_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.app_profiles ap
    join private.attachments a on a.object_key = p_object_key
    where ap.id = auth.uid() and ap.active
      and ap.role in ('OWNER', 'STAFF', 'MAINTAINER')
      and (a.state = 'READY'
        or (a.state = 'PENDING' and a.created_by = ap.id
            and a.created_at > now() - private.attachment_pending_ttl()))
  )
$$;

-- Unggah objek: hanya pembuat slot PENDING yang belum kedaluwarsa, akun aktif OWNER/STAFF.
create or replace function storage_access.can_upload_ticket_photo(p_object_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.app_profiles ap
    join private.attachments a on a.object_key = p_object_key
    where ap.id = auth.uid() and ap.active
      and ap.role in ('OWNER', 'STAFF')
      and a.created_by = ap.id
      and a.state = 'PENDING'
      and a.created_at > now() - private.attachment_pending_ttl()
  )
$$;

revoke all on function storage_access.can_read_ticket_photo(text) from public, anon;
revoke all on function storage_access.can_upload_ticket_photo(text) from public, anon;
grant execute on function storage_access.can_read_ticket_photo(text) to authenticated;
grant execute on function storage_access.can_upload_ticket_photo(text) to authenticated;

drop policy if exists attachment_read on storage.objects;
drop policy if exists attachment_insert on storage.objects;
create policy attachment_read on storage.objects
  for select to authenticated
  using (bucket_id = 'ticket-photos' and storage_access.can_read_ticket_photo(name));
create policy attachment_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'ticket-photos' and storage_access.can_upload_ticket_photo(name));
-- Tidak ada policy UPDATE/DELETE: objek immutable dari sisi klien.

drop function if exists private.can_read_attachment(text);
drop function if exists private.can_write_attachment(text);

create index if not exists attachments_ticket_state on private.attachments(ticket_id, state, created_at)
  where ticket_id is not null;

-- prepare_attachment_v1 ----------------------------------------------------------

create or replace function public.prepare_attachment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_op uuid; v_old jsonb; v_id uuid; v_key text; v_mime text; v_size bigint;
  v_ticket uuid; v_product uuid; v_count integer; v_expires timestamptz;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'ticket_id', 'product_id', 'mime', 'byte_size']);
  v_old := private.operation_result('prepare_attachment_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := private.ops_uuid(p_input->'ticket_id', 'ticket_id', false);
  v_product := private.ops_uuid(p_input->'product_id', 'product_id', false);
  if (v_ticket is null) = (v_product is null) then
    raise exception 'INVALID_INPUT: Tepat satu target (tiket atau produk) wajib' using errcode = '22023';
  end if;
  v_mime := p_input->>'mime';
  if v_mime is null or v_mime not in ('image/jpeg', 'image/png', 'image/webp') then
    raise exception 'ATTACHMENT_INVALID: Tipe file harus JPEG/PNG/WebP' using errcode = '22023';
  end if;
  begin
    v_size := private.ops_int(p_input->'byte_size', 'Ukuran file');
  exception when sqlstate '22023' then
    raise exception 'ATTACHMENT_INVALID: Ukuran file tidak sah' using errcode = '22023';
  end;
  if v_size <= 0 or v_size > 1048576 then
    raise exception 'ATTACHMENT_INVALID: Ukuran foto maksimal 1 MiB' using errcode = '22023';
  end if;

  if v_ticket is not null then
    if not exists (select 1 from private.service_tickets where id = v_ticket) then
      raise exception 'NOT_FOUND: Tiket tidak ditemukan' using errcode = '22023';
    end if;
    -- Serialisasi kuota per tiket tanpa mengunci baris tiket (versi tiket tidak terganggu).
    perform pg_advisory_xact_lock(hashtextextended('attachment_quota:' || v_ticket::text, 0));
    select count(*) into v_count from private.attachments
      where ticket_id = v_ticket
        and (state = 'READY' or (state = 'PENDING' and created_at > now() - private.attachment_pending_ttl()));
    if v_count >= 5 then
      raise exception 'STORAGE_LIMIT: Maksimal 5 foto per tiket' using errcode = '22023';
    end if;
  else
    if v_role <> 'OWNER' then
      raise exception 'FORBIDDEN: Foto produk hanya untuk owner' using errcode = '42501';
    end if;
    if not exists (select 1 from private.products where id = v_product) then
      raise exception 'NOT_FOUND: Produk tidak ditemukan' using errcode = '22023';
    end if;
  end if;

  -- Kunci objek acak; tidak memuat nama/nomor pelanggan.
  v_key := gen_random_uuid()::text || '/' || gen_random_uuid()::text
    || case v_mime when 'image/jpeg' then '.jpg' when 'image/png' then '.png' else '.webp' end;
  insert into private.attachments(ticket_id, product_id, object_key, mime, byte_size, created_by)
    values (v_ticket, v_product, v_key, v_mime, v_size, v_actor)
    returning id, created_at + private.attachment_pending_ttl() into v_id, v_expires;

  return private.finish_operation('prepare_attachment_v1', p_input, jsonb_build_object(
    'ok', true, 'operation_id', v_op, 'entity_id', v_id, 'server_time', now(), 'schema_version', 2,
    'bucket', 'ticket-photos', 'object_key', v_key, 'mime', v_mime, 'byte_size', v_size,
    'state', 'PENDING', 'upload_expires_at', v_expires));
end $$;
revoke all on function public.prepare_attachment_v1(jsonb) from public, anon, authenticated;
grant execute on function public.prepare_attachment_v1(jsonb) to authenticated;

-- finalize_attachment_v1 ---------------------------------------------------------

create or replace function public.finalize_attachment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_op uuid; v_old jsonb; v_a private.attachments%rowtype;
  v_obj_size bigint; v_obj_mime text; v_found boolean; v_count integer;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'attachment_id']);
  v_old := private.operation_result('finalize_attachment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_a from private.attachments
    where id = private.ops_uuid(p_input->'attachment_id', 'attachment_id') for update;
  -- Slot milik orang lain tidak dibocorkan keberadaannya kepada STAFF.
  if not found or (v_a.created_by <> v_actor and v_role <> 'OWNER') then
    raise exception 'NOT_FOUND: Lampiran tidak ditemukan' using errcode = '22023';
  end if;
  if v_a.state = 'READY' then
    raise exception 'ALREADY_FINALIZED: Foto sudah tersimpan' using errcode = '22023';
  end if;
  if v_a.state <> 'PENDING' then
    raise exception 'ATTACHMENT_INVALID: Slot foto tidak dapat difinalisasi' using errcode = '22023';
  end if;

  select true, (o.metadata->>'size')::bigint, o.metadata->>'mimetype'
    into v_found, v_obj_size, v_obj_mime
    from storage.objects o where o.bucket_id = 'ticket-photos' and o.name = v_a.object_key;
  if v_found is null then
    raise exception 'ATTACHMENT_INVALID: Berkas foto belum terunggah' using errcode = '22023';
  end if;
  if v_obj_size is null or v_obj_size <> v_a.byte_size or v_obj_size > 1048576
     or v_obj_mime is null or v_obj_mime <> v_a.mime then
    raise exception 'ATTACHMENT_INVALID: Ukuran/tipe berkas yang terunggah tidak sesuai slot' using errcode = '22023';
  end if;

  if v_a.ticket_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('attachment_quota:' || v_a.ticket_id::text, 0));
    select count(*) into v_count from private.attachments
      where ticket_id = v_a.ticket_id and state = 'READY' and id <> v_a.id;
    if v_count >= 5 then
      raise exception 'STORAGE_LIMIT: Maksimal 5 foto per tiket' using errcode = '22023';
    end if;
  end if;

  update private.attachments set state = 'READY', finalized_at = now() where id = v_a.id;
  insert into private.audit_events(actor_id, action, entity_type, entity_id)
    values (v_actor, 'FINALIZE_ATTACHMENT', 'ATTACHMENT', v_a.id);

  return private.finish_operation('finalize_attachment_v1', p_input, jsonb_build_object(
    'ok', true, 'operation_id', v_op, 'entity_id', v_a.id, 'server_time', now(), 'schema_version', 2,
    'state', 'READY', 'object_key', v_a.object_key));
end $$;
revoke all on function public.finalize_attachment_v1(jsonb) from public, anon, authenticated;
grant execute on function public.finalize_attachment_v1(jsonb) to authenticated;

-- Baca -------------------------------------------------------------------------

create or replace function public.get_attachment_url_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_a private.attachments%rowtype;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.ops_allowed_keys(p_input, array['attachment_id']);
  select * into v_a from private.attachments
    where id = private.ops_uuid(p_input->'attachment_id', 'attachment_id') and state = 'READY';
  if not found then
    raise exception 'NOT_FOUND: Foto tidak ditemukan' using errcode = '22023';
  end if;
  -- Signed URL dibuat klien via Storage API; policy attachment_read memvalidasi ulang.
  return jsonb_build_object('attachment_id', v_a.id, 'bucket', 'ticket-photos', 'object_key', v_a.object_key,
    'expires_seconds', 300, 'mime', v_a.mime);
end $$;
revoke all on function public.get_attachment_url_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_attachment_url_v1(jsonb) to authenticated;

create or replace function public.list_attachments_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_ticket uuid; v_product uuid; v_result jsonb;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  perform private.ops_allowed_keys(p_input, array['ticket_id', 'product_id']);
  v_ticket := private.ops_uuid(p_input->'ticket_id', 'ticket_id', false);
  v_product := private.ops_uuid(p_input->'product_id', 'product_id', false);
  if (v_ticket is null) = (v_product is null) then
    raise exception 'INVALID_INPUT: Tepat satu target (tiket atau produk) wajib' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'object_key', a.object_key, 'mime', a.mime,
      'byte_size', a.byte_size, 'state', a.state, 'created_at', a.created_at, 'finalized_at', a.finalized_at)
      order by a.created_at, a.id), '[]'::jsonb) into v_result
    from private.attachments a
    where a.state = 'READY'
      and ((v_ticket is not null and a.ticket_id = v_ticket) or (v_product is not null and a.product_id = v_product));
  return v_result;
end $$;
revoke all on function public.list_attachments_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_attachments_v1(jsonb) to authenticated;
