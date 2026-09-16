create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.app_profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text not null check (length(trim(display_name)) between 1 and 100),
  role text not null check (role in ('OWNER', 'STAFF', 'MAINTAINER')),
  active boolean not null default true,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now()
);
alter table private.app_profiles enable row level security;
revoke all on private.app_profiles from public, anon, authenticated;

create table private.audit_events (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  reason text,
  occurred_at timestamptz not null default now()
);
alter table private.audit_events enable row level security;
revoke all on private.audit_events from public, anon, authenticated;

create or replace function private.current_role()
returns text language plpgsql security definer set search_path = '' as $$
declare v_role text;
begin
  select role into v_role from private.app_profiles
  where id = auth.uid() and active;
  if v_role is null then
    raise exception 'Akses akun ditolak' using errcode = '42501';
  end if;
  return v_role;
end $$;
revoke all on function private.current_role() from public, anon, authenticated;

create or replace function public.get_current_profile_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_profile private.app_profiles%rowtype;
begin
  perform private.current_role();
  select * into v_profile from private.app_profiles where id = auth.uid();
  return jsonb_build_object('id', v_profile.id, 'display_name', v_profile.display_name,
    'role', v_profile.role, 'active', v_profile.active, 'version', v_profile.version);
end $$;
revoke all on function public.get_current_profile_v1() from public, anon, authenticated;
grant execute on function public.get_current_profile_v1() to authenticated;
