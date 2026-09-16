-- P3 fix: stock_movements perlu service_part_event_id
alter table private.stock_movements
  add column if not exists service_part_event_id uuid
    references private.service_part_events(id);

-- Update source check: stock_document_item_id ATAU invoice_item_id ATAU service_part_event_id
-- (tepat satu sumber)
alter table private.stock_movements
  drop constraint if exists stock_movements_source_check;

alter table private.stock_movements
  add constraint stock_movements_source_check check (
    ((stock_document_item_id is not null)::int +
     (invoice_item_id is not null)::int +
     (service_part_event_id is not null)::int) = 1);
