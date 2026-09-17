-- Fondasi perbaikan audit 2026-09-17.
-- Helper bersama yang dipakai seluruh RPC perbaikan. Semua pesan error memakai
-- format 'KODE: pesan awam' agar frontend dapat memetakan kode dan tetap
-- menampilkan kalimat yang dapat dipahami pengguna.

-- Fungsi baru di schema private tidak boleh otomatis dapat dieksekusi PUBLIC.
alter default privileges in schema private revoke execute on functions from public;

-- Validasi angka ----------------------------------------------------------

-- Nilai wajib: NULL/hilang ditolak (sebelumnya lolos diam-diam sebagai NULL).
create or replace function private.decimal_input(
  p_value jsonb, p_scale integer, p_max numeric, p_positive boolean default true)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_text text; v_value numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    raise exception 'INVALID_NUMBER: Angka wajib diisi' using errcode = '22023';
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    raise exception 'INVALID_NUMBER: Angka harus dikirim sebagai teks desimal' using errcode = '22023';
  end if;
  v_text := p_value #>> '{}';
  if v_text !~ '^(0|[1-9][0-9]*)(\.[0-9]+)?$'
     or length(coalesce(split_part(v_text, '.', 2), '')) > p_scale then
    raise exception 'INVALID_NUMBER: Format angka tidak sah (maksimal % desimal, tanpa pemisah ribuan)', p_scale
      using errcode = '22023';
  end if;
  v_value := v_text::numeric;
  if v_value > p_max then
    raise exception 'INVALID_NUMBER: Angka melebihi batas' using errcode = '22023';
  end if;
  if p_positive and v_value <= 0 then
    raise exception 'INVALID_NUMBER: Angka harus lebih dari nol' using errcode = '22023';
  end if;
  return v_value;
end $$;

-- Nilai opsional: hilang/null/string kosong menghasilkan NULL, selain itu divalidasi.
create or replace function private.decimal_input_opt(
  p_value jsonb, p_scale integer, p_max numeric, p_positive boolean default true)
returns numeric language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null'
     or (jsonb_typeof(p_value) = 'string' and trim(p_value #>> '{}') = '') then
    return null;
  end if;
  return private.decimal_input(p_value, p_scale, p_max, p_positive);
end $$;

-- Otorisasi ----------------------------------------------------------------

-- Wajib dipanggil di awal setiap RPC. Akun nonaktif ditolak walau JWT masih sah.
create or replace function private.require_role(p_roles text[])
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_role text;
begin
  select role into v_role from private.app_profiles where id = auth.uid() and active;
  if v_role is null then
    raise exception 'ACCOUNT_INACTIVE: Akun tidak aktif atau belum terdaftar' using errcode = '42501';
  end if;
  if not (v_role = any (p_roles)) then
    raise exception 'FORBIDDEN: Peran akun Anda tidak diizinkan melakukan tindakan ini' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- Tanggal toko -------------------------------------------------------------

-- Awal hari lokal Asia/Jakarta sebagai timestamptz. Pola lama
-- `date::timestamptz at time zone 'Asia/Jakarta'` menggeser jendela 14 jam.
create or replace function private.local_day_start(p_date date)
returns timestamptz language sql immutable set search_path = '' as $$
  select p_date::timestamp at time zone 'Asia/Jakarta'
$$;

create or replace function private.local_today()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Jakarta')::date
$$;

-- Rentang [awal start_date, awal hari setelah end_date) zona toko.
create or replace function private.date_range_input(p_input jsonb, p_max_days integer)
returns table(start_at timestamptz, end_at timestamptz, start_date date, end_date date)
language plpgsql stable set search_path = '' as $$
declare v_start date; v_end date;
begin
  begin
    v_start := (p_input->>'start_date')::date;
    v_end := (p_input->>'end_date')::date;
  exception when others then
    raise exception 'INVALID_DATE: Tanggal tidak sah (format YYYY-MM-DD)' using errcode = '22023';
  end;
  if v_start is null or v_end is null then
    raise exception 'INVALID_DATE: Tanggal awal dan akhir wajib diisi' using errcode = '22023';
  end if;
  if v_end < v_start then
    raise exception 'INVALID_DATE: Tanggal akhir tidak boleh sebelum tanggal awal' using errcode = '22023';
  end if;
  if v_end - v_start + 1 > p_max_days then
    raise exception 'INVALID_DATE: Rentang maksimal % hari', p_max_days using errcode = '22023';
  end if;
  return query select private.local_day_start(v_start), private.local_day_start(v_end + 1), v_start, v_end;
end $$;

-- Kas ----------------------------------------------------------------------

-- Kunci sesi OPEN sebuah cashbox. Status diperiksa setelah lock sehingga
-- penutupan yang bersamaan tidak dapat menelan mutasi baru.
create or replace function private.lock_open_cash_session(p_cashbox text)
returns private.cash_sessions language plpgsql security definer set search_path = '' as $$
declare v_session private.cash_sessions%rowtype;
begin
  select * into v_session from private.cash_sessions
    where cashbox_id = p_cashbox and status = 'OPEN'
    order by opened_at desc limit 1
    for update;
  if not found or v_session.status <> 'OPEN' then
    raise exception 'CASH_SESSION_CLOSED: Kas % belum dibuka. Buka kas terlebih dahulu.',
      case p_cashbox when 'FATHER_WALLET' then 'dompet ayah' else 'laci toko' end
      using errcode = '40001';
  end if;
  return v_session;
end $$;

revoke all on function private.cash_session_expected(uuid) from public, anon, authenticated;

-- Idempotensi --------------------------------------------------------------

-- Klien memeriksa hasil operasi yang statusnya belum diketahui (mis. timeout)
-- sebelum mengirim ulang dengan operation_id yang sama.
create or replace function public.get_operation_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_op private.operations%rowtype; v_key uuid;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  begin
    v_key := (p_input->>'operation_id')::uuid;
  exception when others then
    raise exception 'INVALID_INPUT: operation_id tidak sah' using errcode = '22023';
  end;
  if v_key is null or coalesce(p_input->>'command', '') = '' then
    raise exception 'INVALID_INPUT: command dan operation_id wajib' using errcode = '22023';
  end if;
  select * into v_op from private.operations
    where actor_id = v_actor and command = p_input->>'command' and operation_id = v_key;
  if not found then
    return jsonb_build_object('found', false);
  end if;
  return jsonb_build_object('found', true, 'result', v_op.result, 'committed_at', v_op.committed_at);
end $$;

revoke all on function public.get_operation_v1(jsonb) from public, anon;
grant execute on function public.get_operation_v1(jsonb) to authenticated;
