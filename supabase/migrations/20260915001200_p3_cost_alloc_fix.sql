-- P3 fix: cost_allocations harus mendukung sumber service_part_event
-- sesuai DATA-05 (invoice_item_id nullable, service_part_event_id nullable,
-- tepat satu sumber).

alter table private.cost_allocations
  alter column invoice_item_id drop not null;

alter table private.cost_allocations
  add column if not exists service_part_event_id uuid
    references private.service_part_events(id);

create index if not exists cost_allocations_part_event
  on private.cost_allocations(service_part_event_id)
  where service_part_event_id is not null;

-- Tepat satu sumber (invoice item atau part event)
alter table private.cost_allocations
  drop constraint if exists cost_allocations_source_check;

alter table private.cost_allocations
  add constraint cost_allocations_source_check check (
    (invoice_item_id is not null) <> (service_part_event_id is not null));

-- Satu alokasi per invoice item / part event
create unique index if not exists cost_allocations_invoice_item_unique
  on private.cost_allocations(invoice_item_id)
  where invoice_item_id is not null;

create unique index if not exists cost_allocations_part_event_unique
  on private.cost_allocations(service_part_event_id)
  where service_part_event_id is not null;
