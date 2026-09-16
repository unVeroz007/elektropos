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
