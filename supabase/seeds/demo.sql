-- Setup demo ElektroPOS (idempoten, hanya untuk lingkungan uji)
-- Dipanggil oleh scripts/setup-demo.mjs setelah akun auth dibuat.

do $$
declare
  v_owner uuid;
  v_staff uuid;
  v_admin uuid;
  v_session uuid;
  v_res jsonb;
begin
  -- Profil peran
  select id into v_owner from auth.users where email = 'owner@elektropos.local';
  select id into v_staff from auth.users where email = 'staff@elektropos.local';
  select id into v_admin from auth.users where email = 'admin@elektropos.local';

  if v_owner is null then raise exception 'Akun owner belum dibuat'; end if;

  insert into private.app_profiles (id, display_name, role, active) values
    (v_owner, 'Ayah Owner', 'OWNER', true)
  on conflict (id) do update set display_name = excluded.display_name, role = excluded.role, active = true;

  if v_staff is not null then
    insert into private.app_profiles (id, display_name, role, active) values
      (v_staff, 'Budi Staff', 'STAFF', true)
    on conflict (id) do update set display_name = excluded.display_name, role = excluded.role, active = true;
  end if;

  if v_admin is not null then
    insert into private.app_profiles (id, display_name, role, active) values
      (v_admin, 'Dev Admin', 'MAINTAINER', true)
    on conflict (id) do update set display_name = excluded.display_name, role = excluded.role, active = true;
  end if;

  -- Identitas toko. Penanda "(DEMO)" dipakai setup-demo untuk menolak berjalan di data toko nyata.
  update private.shop_settings set
    name = 'Toko Listrik Sinar Jaya (DEMO)',
    address = 'Jl. Merdeka No. 45, Bandung',
    phone = '022-1234567',
    receipt_width = 80,
    configured_at = now()
  where id;

  -- Simulasi pemakai = owner
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
end $$;

-- Katalog contoh (skip jika sudah ada)
do $$
declare v_exists integer; v_pid uuid; v_uid uuid;
begin
  select count(*) into v_exists from private.products where sku = 'DEMO-LAMPU-12W';
  if v_exists = 0 then
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf)
    values ('DEMO-LAMPU-12W', 'Lampu LED 12 Watt', 'Cool Daylight 220V', 'pcs', 1, false, 'A-01')
    returning id into v_pid;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_pid, 'pcs', 1, 1, 18000, true) returning id into v_uid;
    insert into private.product_barcodes(product_id, product_unit_id, code)
    values (v_pid, v_uid, '8991001001001');
  end if;

  select count(*) into v_exists from private.products where sku = 'DEMO-SAKLAR';
  if v_exists = 0 then
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf)
    values ('DEMO-SAKLAR', 'Saklar Tunggal', 'Inbow putih', 'pcs', 1, false, 'A-02')
    returning id into v_pid;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_pid, 'pcs', 1, 1, 22000, true) returning id into v_uid;
    insert into private.product_barcodes(product_id, product_unit_id, code)
    values (v_pid, v_uid, '8991001001002');
  end if;

  select count(*) into v_exists from private.products where sku = 'DEMO-KABEL-15';
  if v_exists = 0 then
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf)
    values ('DEMO-KABEL-15', 'Kabel NYA 1.5mm', 'Tembaga engkel merah', 'm', 0.1, true, 'B-01')
    returning id into v_pid;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_pid, 'm', 1, 0.1, 8500, true) returning id into v_uid;
    insert into private.product_barcodes(product_id, product_unit_id, code)
    values (v_pid, v_uid, '8991001001003');
  end if;

  select count(*) into v_exists from private.products where sku = 'DEMO-TANG';
  if v_exists = 0 then
    insert into private.products(sku, name, specification, base_unit, quantity_step, track_segments, shelf)
    values ('DEMO-TANG', 'Tang Kombinasi 8 inch', 'Besi tempa', 'pcs', 1, false, 'C-01')
    returning id into v_pid;
    insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
    values (v_pid, 'pcs', 1, 1, 45000, true) returning id into v_uid;
    insert into private.product_barcodes(product_id, product_unit_id, code)
    values (v_pid, v_uid, '8991001001004');
  end if;
end $$;

-- Satuan roll utuh kabel: hanya dapat dijual dari roll yang masih bersegel (BR-03).
insert into private.product_units(product_id, label, factor_base, sale_step, sell_price, is_default)
select p.id, 'roll 100m', 100, 1, 780000, false
from private.products p
where p.sku = 'DEMO-KABEL-15'
  and not exists (select 1 from private.product_units u where u.product_id = p.id and u.label = 'roll 100m' and u.active);

-- Batas stok minimum contoh agar beranda menampilkan stok menipis.
update private.products set min_stock = 5 where sku in ('DEMO-LAMPU-12W', 'DEMO-SAKLAR') and min_stock = 0;
update private.products set min_stock = 30 where sku = 'DEMO-KABEL-15' and min_stock = 0;
