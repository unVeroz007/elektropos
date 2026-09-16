-- Storage: bucket privat untuk foto tiket/servis
-- Bucket dibuat via SQL agar tercatat di version control dan idempoten.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ticket-photos',
  'ticket-photos',
  false,
  1048576,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = 1048576,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- Helper: apakah user aktif dengan peran yang boleh baca foto
create or replace function private.can_read_attachment(p_object_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1
    from private.app_profiles ap
    join private.attachments a on a.object_key = p_object_key and a.state = 'READY'
    where ap.id = auth.uid() and ap.active
      and ap.role in ('OWNER', 'STAFF', 'MAINTAINER')
  )
$$;
revoke all on function private.can_read_attachment(text) from public, anon, authenticated;

-- Helper: apakah user aktif pemilik slot upload yang belum difinalisasi
create or replace function private.can_write_attachment(p_object_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1
    from private.app_profiles ap
    join private.attachments a on a.object_key = p_object_key
    where ap.id = auth.uid() and ap.active
      and ap.role in ('OWNER', 'STAFF')
      and a.created_by = auth.uid()
      and a.state = 'PENDING'
  )
$$;
revoke all on function private.can_write_attachment(text) from public, anon, authenticated;

-- Policy: hanya authenticated; anon tidak mendapat akses apa pun
drop policy if exists attachment_read on storage.objects;
drop policy if exists attachment_insert on storage.objects;

create policy attachment_read on storage.objects
  for select to authenticated
  using (bucket_id = 'ticket-photos' and private.can_read_attachment(name));

create policy attachment_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'ticket-photos' and private.can_write_attachment(name));

-- Tidak ada policy UPDATE/DELETE: objek foto immutable dari sisi klien.
-- Pembersihan orphan dilakukan runner server (service role), bukan browser.
