-- Fix: cost_allocations tidak boleh unique per invoice_item_id
-- karena multi-posisi (AT-06) menghasilkan banyak alokasi per item.
-- Data-05 tidak menentukan unique per invoice_item_id.

-- Drop index yang salah
drop index if exists private.cost_allocations_invoice_item_unique;

-- Ganti dengan index yang benar: unik per posisi asal
-- Satu lot + satu posisi hanya boleh punya satu alokasi aktif
create unique index if not exists cost_allocations_lot_position
  on private.cost_allocations(lot_id, origin_position_id);
