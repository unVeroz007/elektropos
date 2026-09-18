-- R03: indeks ganda pada cost_allocations (sisa beberapa kali perubahan indeks).
-- Masing-masing sudah dicakup indeks lain yang tetap dipertahankan:
--   cost_allocations_lot_idx        = cost_allocations_lot (lot_id)
--   cost_allocations_item_idx       ⊂ cost_allocations_item (invoice_item_id)
--   cost_allocations_part_event_idx ⊂ cost_allocations_part_event_unique (service_part_event_id, unik)
drop index if exists private.cost_allocations_lot_idx;
drop index if exists private.cost_allocations_item_idx;
drop index if exists private.cost_allocations_part_event_idx;
