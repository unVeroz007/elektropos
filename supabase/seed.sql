-- Fixture khusus pengujian ElektroPOS
-- TIDAK UNTUK PRODUKSI

-- Fixture memakai cluster PostgreSQL uji (bootstrap.sql) atau Supabase lokal.
-- Asumsi: schema auth dan auth.uid() sudah disediakan bootstrap/Supabase.

truncate table
  private.operations,
  private.audit_events,
  private.stock_movements,
  private.stock_count_items,
  private.stock_counts,
  private.stock_positions,
  private.inventory_lots,
  private.stock_document_items,
  private.stock_documents,
  private.purchase_payments,
  private.document_sequences,
  private.product_barcodes,
  private.product_price_history,
  private.product_units,
  private.products,
  private.suppliers,
  private.app_profiles
  cascade;
delete from auth.users;

-- Users:
-- Owner:      11111111-1111-4111-8111-111111111111
-- Staff:      22222222-2222-4222-8222-222222222222
-- Maintainer: 33333333-3333-4333-8333-333333333333
-- Disabled:   44444444-4444-4444-8444-444444444444

insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'owner@test.local'),
  ('22222222-2222-4222-8222-222222222222', 'staff@test.local'),
  ('33333333-3333-4333-8333-333333333333', 'maintainer@test.local'),
  ('44444444-4444-4444-8444-444444444444', 'disabled@test.local');

insert into private.app_profiles (id, display_name, role, active) values
  ('11111111-1111-4111-8111-111111111111', 'Ayah Owner', 'OWNER', true),
  ('22222222-2222-4222-8222-222222222222', 'Budi Staff', 'STAFF', true),
  ('33333333-3333-4333-8333-333333333333', 'Dev Maintainer', 'MAINTAINER', true),
  ('44444444-4444-4444-8444-444444444444', 'Eko Disabled', 'STAFF', false);

-- Products:
-- Lampu LED 10W (bulk pcs): a2000000-0000-4000-8000-000000000001
-- Kabel NYA 1.5mm (roll/m): a2000000-0000-4000-8000-000000000002

insert into private.products (id, sku, name, specification, base_unit, quantity_step, track_segments, shelf) values
  ('a2000000-0000-4000-8000-000000000001', 'LMP-LED-10W', 'Lampu LED 10 Watt', 'Warm White 220V', 'pcs', 1.000, false, 'A-01'),
  ('a2000000-0000-4000-8000-000000000002', 'KBL-NYA-1.5', 'Kabel NYA 1.5mm', 'Tembaga Engkel Red', 'm', 0.100, true, 'B-03');

-- Product Units:
insert into private.product_units (id, product_id, label, factor_base, sale_step, sell_price, is_default, whole_roll) values
  ('a1000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001', 'pcs', 1.000, 1.000, 15000.000000, true, false),
  ('a1000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002', 'm', 1.000, 0.100, 7500.000000, true, false),
  ('a1000000-0000-4000-8000-000000000003', 'a2000000-0000-4000-8000-000000000002', 'roll 100m', 100.000, 1.000, 650000.000000, false, true);

-- Barcodes (termasuk kode dengan nol depan untuk AT-03):
insert into private.product_barcodes (product_id, product_unit_id, code) values
  ('a2000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', '8991234567890'),
  ('a2000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000003', '0012345678901');
