-- AT-29: setup checklist, kesehatan, dan backup manifest
\set ON_ERROR_STOP on

begin;

-- Persiapkan: toko kosong + satu backup sukses (session default = postgres)
update private.shop_settings set name = '', configured_at = null, version = version + 1 where id;
insert into private.backup_runs(status, completed_at, content_hash, restore_verified_at)
values ('SUCCEEDED', now(), 'test-hash', now());

-- AT-29: toko kosong -> belum configured; setelah nama diisi -> configured
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

  v_res := public.get_shop_settings_v1();
  if (v_res->>'configured')::boolean is true then
    raise exception 'AT-29: toko kosong seharusnya belum configured';
  end if;

  v_res := public.update_shop_settings_v1(jsonb_build_object(
    'operation_id', 'e2900000-0000-4000-8000-000000000001',
    'name', 'Toko Uji', 'address', 'Jl. Uji', 'phone', '022-000', 'receipt_width', 80,
    'expected_version', (select version from private.shop_settings where id)));
  if not (v_res->>'ok')::boolean then raise exception 'AT-29: update settings gagal'; end if;
  if (v_res->>'configured')::boolean is not true then
    raise exception 'AT-29: setelah nama diisi harus configured';
  end if;
end $$;

-- AT-29: validasi lebar struk tidak sah
do $$
declare v_ver integer;
begin
  select version into v_ver from private.shop_settings where id;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object(
      'operation_id', 'e2900000-0000-4000-8000-000000000002',
      'receipt_width', 60, 'expected_version', v_ver));
    raise exception 'AT-29: lebar 60 harus ditolak';
  exception when others then
    if position('Lebar struk' in sqlerrm) = 0 then raise; end if;
  end;
end $$;

-- AT-29: staff tidak boleh mengubah pengaturan
do $$
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  begin
    perform public.update_shop_settings_v1(jsonb_build_object(
      'operation_id', 'e2900000-0000-4000-8000-000000000003', 'name', 'Hack'));
    raise exception 'AT-29: staff harus ditolak';
  exception when insufficient_privilege then null;
  end;
end $$;

-- AT-29: health mengembalikan ukuran DB dan status backup
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v_res := public.get_health_v1();
  if (v_res->>'db_size_bytes') is null then raise exception 'AT-29: health harus punya ukuran DB'; end if;
  if (v_res->'last_backup'->>'status') <> 'SUCCEEDED' then
    raise exception 'AT-29: status backup salah, dapat %', v_res->'last_backup'->>'status';
  end if;
end $$;

-- AT-29: staff health tidak memuat detail internal
do $$
declare v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  v_res := public.get_health_v1();
  if (v_res->'detail') is not null then
    raise exception 'AT-29: staff tidak boleh menerima detail health';
  end if;
end $$;

-- Perbaikan audit: validasi pengaturan, versi wajib, command idempotensi, akun nonaktif.
do $$
declare v_ver integer; v_res jsonb;
begin
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  select version into v_ver from private.shop_settings where id;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'name', 'Tanpa versi'));
    raise exception 'settings: expected_version wajib';
  exception when others then if position('INVALID_INPUT' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver,
      'name', repeat('x', 101)));
    raise exception 'settings: nama >100 harus ditolak';
  exception when others then if position('INVALID_INPUT' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver,
      'address', repeat('x', 301)));
    raise exception 'settings: alamat >300 harus ditolak';
  exception when others then if position('INVALID_INPUT' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver,
      'receipt_width', 'lebar'));
    raise exception 'settings: lebar teks harus ditolak';
  exception when others then if position('Lebar struk' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver,
      'name', '   '));
    raise exception 'settings: nama kosong harus ditolak';
  exception when others then if position('INVALID_INPUT' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver,
      'timezone', 'UTC'));
    raise exception 'settings: field teknis harus ditolak';
  exception when others then if position('INVALID_INPUT' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.update_shop_settings_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'expected_version', v_ver - 1,
      'phone', '0812'));
    raise exception 'settings: versi lama harus ditolak';
  exception when others then if position('VERSION_CONFLICT' in sqlerrm) = 0 then raise; end if; end;

  v_res := public.update_shop_settings_v1(jsonb_build_object('operation_id', 'e2900000-0000-4000-8000-000000000010',
    'expected_version', v_ver, 'receipt_width', '58', 'phone', '(022) 123-45'));
  if (v_res->>'version')::integer <> v_ver + 1 then raise exception 'settings: versi tidak naik'; end if;
  v_res := public.get_shop_settings_v1();
  if (v_res->>'receipt_width')::integer <> 58 or v_res->>'name' <> 'Toko Uji' or v_res->>'phone' <> '(022) 123-45' then
    raise exception 'settings: nilai tersimpan salah %', v_res;
  end if;
  if not (public.get_operation_v1(jsonb_build_object('command', 'update_shop_settings_v1',
      'operation_id', 'e2900000-0000-4000-8000-000000000010'))->>'found')::boolean then
    raise exception 'get_operation_v1 update_shop_settings_v1 tidak ditemukan';
  end if;

  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  begin
    perform public.get_shop_settings_v1();
    raise exception 'settings: akun nonaktif harus ditolak';
  exception when others then if position('ACCOUNT_INACTIVE' in sqlerrm) = 0 then raise; end if; end;
  begin
    perform public.get_health_v1();
    raise exception 'health: akun nonaktif harus ditolak';
  exception when others then if position('ACCOUNT_INACTIVE' in sqlerrm) = 0 then raise; end if; end;
end $$;

-- Kesehatan per peran: STAFF status ringkas, OWNER ringkasan + ukuran, MAINTAINER detail teknis.
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  v := public.get_health_v1();
  if v ? 'db_size_bytes' or v ? 'detail' or v ? 'technical' or v->'last_backup'->>'status' <> 'SUCCEEDED'
     or (v->>'backup_stale')::boolean then
    raise exception 'health STAFF salah %', v;
  end if;
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  v := public.get_health_v1();
  if not (v ? 'detail') or v ? 'technical' then raise exception 'health OWNER salah %', v; end if;
  perform set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
  v := public.get_health_v1();
  if v->'technical'->>'postgres_version' is null or jsonb_array_length(v->'technical'->'recent_backups') <> 1 then
    raise exception 'health MAINTAINER salah %', v;
  end if;
end $$;

-- Profil: kemampuan UI mengikuti peran.
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
  v := public.get_current_profile_v1();
  if v->>'role' <> 'STAFF' or (v->'capabilities'->>'view_cost')::boolean or not (v->'capabilities'->>'view_revenue')::boolean then
    raise exception 'profil STAFF salah %', v;
  end if;
  perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  if not (public.get_current_profile_v1()->'capabilities'->>'manage_stock')::boolean then
    raise exception 'profil OWNER salah';
  end if;
end $$;

-- AT-29: anon tidak dapat health
do $$
begin
  perform set_config('role', 'anon', true);
  begin
    perform public.get_health_v1();
    raise exception 'AT-29: anon tidak boleh health';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
