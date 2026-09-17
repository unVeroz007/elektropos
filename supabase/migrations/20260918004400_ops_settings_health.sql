-- Perbaikan audit 2026-09: profil, pengaturan toko, kesehatan, catatan backup (T09/D4).

-- get_current_profile_v1 ---------------------------------------------------------

create or replace function public.get_current_profile_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_p private.app_profiles%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select * into v_p from private.app_profiles where id = v_actor;
  -- Kemampuan hanya panduan tampilan UI; server tetap memeriksa setiap perintah.
  return jsonb_build_object('id', v_p.id, 'display_name', v_p.display_name, 'role', v_p.role,
    'active', v_p.active, 'version', v_p.version,
    'capabilities', jsonb_build_object(
      'view_cost', v_p.role in ('OWNER', 'MAINTAINER'),
      'view_revenue', true,
      'manage_stock', v_p.role = 'OWNER',
      'sell', v_p.role in ('OWNER', 'STAFF'),
      'export_invoices', true,
      'export_products', v_p.role in ('OWNER', 'MAINTAINER'),
      'manage_settings', v_p.role = 'OWNER',
      'view_health_detail', v_p.role in ('OWNER', 'MAINTAINER')));
end $$;
revoke all on function public.get_current_profile_v1() from public, anon, authenticated;
grant execute on function public.get_current_profile_v1() to authenticated;

-- Pengaturan toko ------------------------------------------------------------------

create or replace function public.get_shop_settings_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_s private.shop_settings%rowtype;
begin
  perform private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select * into v_s from private.shop_settings where id;
  return jsonb_build_object('name', v_s.name, 'address', v_s.address, 'phone', v_s.phone,
    'currency', v_s.currency, 'timezone', v_s.timezone, 'receipt_width', v_s.receipt_width,
    'configured', v_s.configured_at is not null, 'configured_at', v_s.configured_at, 'version', v_s.version);
end $$;
revoke all on function public.get_shop_settings_v1() from public, anon, authenticated;
grant execute on function public.get_shop_settings_v1() to authenticated;

create or replace function public.update_shop_settings_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_op uuid; v_old jsonb; v_s private.shop_settings%rowtype;
  v_name text; v_address text; v_phone text; v_width integer;
begin
  v_actor := private.require_role(array['OWNER']);
  v_op := private.ops_operation_id(p_input);
  perform private.ops_allowed_keys(p_input, array['operation_id', 'expected_version', 'name', 'address', 'phone', 'receipt_width']);
  v_old := private.operation_result('update_shop_settings_v1', p_input);
  if v_old is not null then return v_old; end if;

  select * into v_s from private.shop_settings where id for update;
  if v_s.version <> private.ops_int(p_input->'expected_version', 'expected_version') then
    raise exception 'VERSION_CONFLICT: Pengaturan sudah diubah di perangkat lain. Muat ulang.' using errcode = '40001';
  end if;
  v_name := case when p_input ? 'name' then private.ops_text(p_input->'name', 'Nama toko', 100, true) else v_s.name end;
  v_address := case when p_input ? 'address' then coalesce(private.ops_text(p_input->'address', 'Alamat', 300), '') else v_s.address end;
  v_phone := case when p_input ? 'phone' then coalesce(private.ops_text(p_input->'phone', 'Telepon', 40), '') else v_s.phone end;
  if p_input ? 'receipt_width' then
    begin
      v_width := private.ops_int(p_input->'receipt_width', 'Lebar struk');
    exception when sqlstate '22023' then
      v_width := -1;
    end;
  else
    v_width := v_s.receipt_width;
  end if;
  if v_width not in (58, 80) then
    raise exception 'INVALID_INPUT: Lebar struk harus 58 atau 80 mm' using errcode = '22023';
  end if;
  if v_phone !~ '^[0-9+() .-]*$' then
    raise exception 'INVALID_INPUT: Telepon hanya boleh angka, spasi, +, -, titik, kurung' using errcode = '22023';
  end if;

  update private.shop_settings set name = v_name, address = v_address, phone = v_phone,
    receipt_width = v_width,
    configured_at = case when v_name <> '' then coalesce(configured_at, now()) else configured_at end,
    version = version + 1
    where id returning * into v_s;
  insert into private.audit_events(actor_id, action, entity_type, entity_id)
    values (v_actor, 'UPDATE_SHOP_SETTINGS', 'SHOP_SETTINGS', null);

  return private.finish_operation('update_shop_settings_v1', p_input, jsonb_build_object(
    'ok', true, 'operation_id', v_op, 'server_time', now(), 'schema_version', 2,
    'version', v_s.version, 'configured', v_s.configured_at is not null));
end $$;
revoke all on function public.update_shop_settings_v1(jsonb) from public, anon, authenticated;
grant execute on function public.update_shop_settings_v1(jsonb) to authenticated;

-- Catatan backup ----------------------------------------------------------------------

alter table private.backup_runs add column if not exists backup_label text;
alter table private.backup_runs add column if not exists photo_count integer;
alter table private.backup_runs add column if not exists total_bytes bigint;
alter table private.backup_runs add column if not exists mirror_status text;
create index if not exists backup_runs_started on private.backup_runs(started_at desc);

-- get_health_v1 ------------------------------------------------------------------
-- STAFF: status backup ringkas. OWNER: ringkasan + ukuran. MAINTAINER: detail teknis.

create or replace function public.get_health_v1()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_last private.backup_runs%rowtype; v_ok private.backup_runs%rowtype;
  v_result jsonb; v_size bigint;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  select * into v_last from private.backup_runs order by started_at desc limit 1;
  select * into v_ok from private.backup_runs where status = 'SUCCEEDED' order by started_at desc limit 1;

  v_result := jsonb_build_object('server_time', now(), 'schema_version', 2,
    'last_backup', case when v_last.id is null then null else jsonb_build_object(
      'status', v_last.status, 'started_at', v_last.started_at, 'completed_at', v_last.completed_at,
      'restore_verified_at', v_last.restore_verified_at) end,
    'last_successful_backup_at', coalesce(v_ok.completed_at, v_ok.started_at),
    'backup_stale', v_ok.id is null or now() - coalesce(v_ok.completed_at, v_ok.started_at) > interval '24 hours');
  if v_role = 'STAFF' then
    return v_result;
  end if;

  v_size := pg_database_size(current_database());
  v_result := v_result || jsonb_build_object('db_size_bytes', v_size, 'db_size_mb', round(v_size / 1048576.0, 2),
    'detail', jsonb_build_object(
      'products', (select count(*) from private.products where active),
      'invoices', (select count(*) from private.invoices),
      'tickets', (select count(*) from private.service_tickets),
      'attachments', (select count(*) from private.attachments where state = 'READY'),
      'pending_attachments', (select count(*) from private.attachments
        where state = 'PENDING' and created_at > now() - private.attachment_pending_ttl()),
      'expired_pending_attachments', (select count(*) from private.attachments
        where state = 'PENDING' and created_at <= now() - private.attachment_pending_ttl()),
      'photo_bytes', (select coalesce(sum(byte_size), 0) from private.attachments where state = 'READY'),
      'last_backup_photo_count', v_ok.photo_count, 'last_backup_total_bytes', v_ok.total_bytes,
      'last_backup_mirror_status', v_ok.mirror_status,
      'last_restore_verified_at', (select max(restore_verified_at) from private.backup_runs)));
  if v_role = 'MAINTAINER' then
    v_result := v_result || jsonb_build_object('technical', jsonb_build_object(
      'postgres_version', current_setting('server_version'),
      'last_backup_label', v_last.backup_label,
      'last_backup_error', v_last.redacted_error,
      'recent_backups', (select coalesce(jsonb_agg(jsonb_build_object('status', b.status, 'started_at', b.started_at,
          'completed_at', b.completed_at, 'label', b.backup_label, 'error', b.redacted_error) order by b.started_at desc), '[]'::jsonb)
        from (select * from private.backup_runs order by started_at desc limit 10) b),
      'largest_tables', (select coalesce(jsonb_agg(jsonb_build_object('table', t.relname, 'bytes', t.bytes) order by t.bytes desc), '[]'::jsonb)
        from (select c.relname, pg_total_relation_size(c.oid) bytes from pg_catalog.pg_class c
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'private' and c.relkind = 'r'
              order by pg_total_relation_size(c.oid) desc limit 8) t)));
  end if;
  return v_result;
end $$;
revoke all on function public.get_health_v1() from public, anon, authenticated;
grant execute on function public.get_health_v1() to authenticated;
