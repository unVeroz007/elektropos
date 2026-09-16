-- P4: attachments (foto privat), backup_runs, health

create table if not exists private.attachments (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references private.service_tickets(id),
  product_id uuid references private.products(id),
  object_key text not null unique,
  mime text not null check (mime in ('image/jpeg','image/png','image/webp')),
  byte_size bigint not null check (byte_size > 0 and byte_size <= 1048576),
  state text not null default 'PENDING' check (state in ('PENDING','READY','FAILED')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  check ((ticket_id is not null)::int + (product_id is not null)::int = 1)
);
create index if not exists attachments_ticket on private.attachments(ticket_id) where ticket_id is not null;

alter table private.attachments enable row level security;
revoke all on private.attachments from public, anon, authenticated;

create table if not exists private.backup_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'RUNNING' check (status in ('RUNNING','SUCCEEDED','FAILED')),
  db_manifest text,
  object_manifest text,
  row_counts jsonb,
  content_hash text,
  redacted_error text,
  restore_verified_at timestamptz
);
alter table private.backup_runs enable row level security;
revoke all on private.backup_runs from public, anon, authenticated;

-- prepare_attachment_v1
create or replace function public.prepare_attachment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_id uuid;
  v_key text;
  v_mime text;
  v_size bigint;
  v_ticket uuid;
  v_product uuid;
  v_count integer;
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('prepare_attachment_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_ticket := nullif(p_input->>'ticket_id', '')::uuid;
  v_product := nullif(p_input->>'product_id', '')::uuid;
  if (v_ticket is null) = (v_product is null) then
    raise exception 'Tepat satu target (tiket atau produk) wajib' using errcode = '22023';
  end if;

  v_mime := p_input->>'mime';
  if v_mime not in ('image/jpeg','image/png','image/webp') then
    raise exception 'ATTACHMENT_INVALID: tipe file harus JPEG/PNG/WebP' using errcode = '22023';
  end if;

  v_size := (p_input->>'byte_size')::bigint;
  if v_size is null or v_size <= 0 or v_size > 1048576 then
    raise exception 'ATTACHMENT_INVALID: ukuran maksimal 1 MiB' using errcode = '22023';
  end if;

  if v_ticket is not null then
    if not exists (select 1 from private.service_tickets where id = v_ticket) then
      raise exception 'Tiket tidak ditemukan' using errcode = '22023';
    end if;
    select count(*) into v_count from private.attachments where ticket_id = v_ticket;
    if v_count >= 5 then
      raise exception 'STORAGE_LIMIT: maksimal 5 foto per tiket' using errcode = '22023';
    end if;
  end if;

  v_key := v_actor::text || '/' || gen_random_uuid()::text;

  insert into private.attachments(ticket_id, product_id, object_key, mime, byte_size, created_by)
  values (v_ticket, v_product, v_key, v_mime, v_size, v_actor)
  returning id into v_id;

  return private.finish_operation('prepare_attachment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_id, 'object_key', v_key,
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.prepare_attachment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.prepare_attachment_v1(jsonb) to authenticated;

-- finalize_attachment_v1
create or replace function public.finalize_attachment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid();
  v_old jsonb;
  v_attachment private.attachments%rowtype;
begin
  if private.current_role() not in ('OWNER', 'STAFF') then
    raise exception 'Peran tidak diizinkan' using errcode = '42501';
  end if;
  v_old := private.operation_result('finalize_attachment_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_attachment from private.attachments
    where id = nullif(p_input->>'attachment_id', '')::uuid for update;
  if not found then raise exception 'Lampiran tidak ditemukan' using errcode = '22023'; end if;
  if v_attachment.state = 'READY' then
    raise exception 'ALREADY_FINALIZED' using errcode = '40001';
  end if;

  update private.attachments set state = 'READY', finalized_at = now()
    where id = v_attachment.id;

  insert into private.audit_events(actor_id, action, entity_type, entity_id)
  values (v_actor, 'FINALIZE_ATTACHMENT', 'ATTACHMENT', v_attachment.id);

  return private.finish_operation('finalize_attachment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_attachment.id, 'state', 'READY',
    'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.finalize_attachment_v1(jsonb) from public,anon,authenticated;
grant execute on function public.finalize_attachment_v1(jsonb) to authenticated;

-- get_attachment_url_v1 — kembalikan object_key; signed URL dibuat klien
create or replace function public.get_attachment_url_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_attachment private.attachments%rowtype;
begin
  v_role := private.current_role();
  select * into v_attachment from private.attachments
    where id = nullif(p_input->>'attachment_id', '')::uuid;
  if not found then raise exception 'NOT_FOUND' using errcode = '22023'; end if;
  if v_attachment.state <> 'READY' then
    raise exception 'NOT_FOUND' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'object_key', v_attachment.object_key,
    'bucket', 'ticket-photos',
    'expires_seconds', 300,
    'mime', v_attachment.mime);
end $$;
revoke all on function public.get_attachment_url_v1(jsonb) from public,anon,authenticated;
grant execute on function public.get_attachment_url_v1(jsonb) to authenticated;

-- list_attachments_v1
create or replace function public.list_attachments_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform private.current_role();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'object_key', a.object_key, 'mime', a.mime,
    'state', a.state, 'created_at', a.created_at
  ) order by a.created_at), '[]'::jsonb) into v_result
  from private.attachments a
  where a.ticket_id = nullif(p_input->>'ticket_id', '')::uuid
    and a.state = 'READY';
  return v_result;
end $$;
revoke all on function public.list_attachments_v1(jsonb) from public,anon,authenticated;
grant execute on function public.list_attachments_v1(jsonb) to authenticated;

-- get_health_v1
create or replace function public.get_health_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_db_size bigint;
  v_last_backup private.backup_runs%rowtype;
begin
  v_role := private.current_role();

  select pg_database_size(current_database()) into v_db_size;
  select * into v_last_backup from private.backup_runs order by started_at desc limit 1;

  return jsonb_build_object(
    'server_time', now(),
    'db_size_bytes', v_db_size,
    'db_size_mb', round(v_db_size / 1048576.0, 2),
    'last_backup', case when v_last_backup.id is null then null else jsonb_build_object(
      'status', v_last_backup.status,
      'started_at', v_last_backup.started_at,
      'completed_at', v_last_backup.completed_at,
      'restore_verified_at', v_last_backup.restore_verified_at
    ) end)
  || case when v_role in ('OWNER','MAINTAINER') then jsonb_build_object(
      'detail', jsonb_build_object(
        'products', (select count(*) from private.products where active),
        'invoices', (select count(*) from private.invoices),
        'tickets', (select count(*) from private.service_tickets),
        'attachments', (select count(*) from private.attachments),
        'pending_attachments', (select count(*) from private.attachments where state = 'PENDING')
      ))
    else '{}'::jsonb end;
end $$;
revoke all on function public.get_health_v1() from public,anon,authenticated;
grant execute on function public.get_health_v1() to authenticated;
