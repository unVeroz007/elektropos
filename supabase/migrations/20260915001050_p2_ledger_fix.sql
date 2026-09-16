-- P2 fix: penjualan/retur harus menulis ledger stock_movements
-- sesuai DATA-03 (kind SALE_OUT / RETURN_IN, invoice_item_id sebagai sumber).

-- 1. Izinkan stock_document_item_id null + tambah invoice_item_id
alter table private.stock_movements
  alter column stock_document_item_id drop not null;

alter table private.stock_movements
  add column if not exists invoice_item_id uuid references private.invoice_items(id);

create index if not exists stock_movements_invoice_item
  on private.stock_movements(invoice_item_id) where invoice_item_id is not null;

-- 2. Tambah kind penjualan/retur
alter table private.stock_movements
  drop constraint if exists stock_movements_kind_check;

alter table private.stock_movements
  add constraint stock_movements_kind_check check (kind in (
    'RECEIPT','OPENING','TRANSFER_OUT','TRANSFER_IN',
    'ADJUST_OUT','ADJUST_IN','COUNT_OUT','COUNT_IN','DISPOSAL',
    'SALE_OUT','RETURN_IN'));

-- 3. Sumber gerakan tepat satu (document item ATAU invoice item)
alter table private.stock_movements
  drop constraint if exists stock_movements_source_check;

alter table private.stock_movements
  add constraint stock_movements_source_check check (
    (stock_document_item_id is not null) <> (invoice_item_id is not null));
