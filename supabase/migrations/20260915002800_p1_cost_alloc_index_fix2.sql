-- Fix: hapus index unik yang terlalu ketat pada cost_allocations.
--
-- Alasan: finalize_sale_v1 memodifikasi stock_positions IN PLACE (qty dikurangi),
-- sehingga id posisi tetap. Penjualan berikutnya dari posisi yang sama akan
-- menghasilkan alokasi baru dengan (lot_id, origin_position_id) yang sama.
--
-- Satu invoice item juga dapat memakai beberapa posisi (multi-potongan, AT-06),
-- sehingga unique per invoice_item_id juga salah.
--
-- Cost allocation bersifat append-only ledger; keunikan dijaga oleh alur RPC,
-- bukan oleh constraint. Cukup sediakan index biasa untuk penelusuran.

drop index if exists private.cost_allocations_invoice_item_unique;
drop index if exists private.cost_allocations_lot_position;
drop index if exists private.cost_allocations_item_lot;
drop index if exists private.cost_allocations_part_event;

create index if not exists cost_allocations_lot_idx
  on private.cost_allocations(lot_id);

create index if not exists cost_allocations_item_idx
  on private.cost_allocations(invoice_item_id)
  where invoice_item_id is not null;

create index if not exists cost_allocations_part_event_idx
  on private.cost_allocations(service_part_event_id)
  where service_part_event_id is not null;
