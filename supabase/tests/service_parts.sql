-- Servis: part (AT-19, S05). Pemakaian mengurangi stok+modal sekali; reverse mengembalikan stok+modal
-- kumulatif ke posisi pilihan; tagihan wajib baris PART untuk USE bersih; COGS diakui bersih sekali.
\set ON_ERROR_STOP on
begin;
\ir service_helpers.psql

do $$ begin
  perform pg_temp.as_user('owner');
  perform public.post_opening_stock_v1(jsonb_build_object('operation_id', gen_random_uuid(), 'reason', 'Stok uji part',
    'items', jsonb_build_array(
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000001', 'qty', '3', 'acquisition_cost', '20000'),
      jsonb_build_object('product_unit_id', 'a1000000-0000-4000-8000-000000000002', 'qty', '150', 'acquisition_cost', '750000',
        'positions', jsonb_build_array(
          jsonb_build_object('label', 'UJI-R1', 'qty_base', '100', 'segment_capacity', '100', 'sealed', true),
          jsonb_build_object('label', 'UJI-R2', 'qty_base', '50', 'segment_capacity', '50', 'sealed', true))))));
end $$;

do $$
declare
  v_t uuid; v_other uuid; v jsonb; v_led_pos uuid; v_led_lot uuid; v_r1 uuid; v_roll_lot uuid;
  v_use_led uuid; v_use_roll uuid; v_use_field uuid; v_field_pos uuid; v_damaged uuid;
begin
  perform pg_temp.as_user('owner');
  select s.id, s.lot_id into v_led_pos, v_led_lot from private.stock_positions s join private.inventory_lots l on l.id = s.lot_id
    where l.product_id = 'a2000000-0000-4000-8000-000000000001';
  select id, lot_id into v_r1, v_roll_lot from private.stock_positions where label = 'UJI-R1';

  v_t := pg_temp.new_store_ticket('Part', '081266660000');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_led_pos, 'qty', '1'), 'INVALID_TRANSITION');
  perform pg_temp.to_working(v_t, '1000000', '1000000');

  -- Validasi pemakaian.
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_led_pos, 'qty', '1.5'), 'INVALID_QUANTITY');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_led_pos, 'qty', '4'), 'INSUFFICIENT_STOCK');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_r1, 'qty', '0.05'), 'INVALID_QUANTITY');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_r1, 'qty', '100.5'), 'SEGMENT_TOO_SHORT');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_led_pos, 'qty', '1', 'charge_unit_price', 15000), 'INVALID_NUMBER');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', 1,
    'position_id', v_led_pos, 'qty', '1'), 'VERSION_CONFLICT');

  -- LED 2 dari lot 3 pcs / 20.000 -> modal round_half_up(20000*2/3, 6) = 13333.333333.
  v := pg_temp.call('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_led_pos, 'qty', '2', 'charge_unit_price', ''));
  v_use_led := (v->>'part_event_id')::uuid;
  perform pg_temp.check((v->>'cost')::numeric = 13333.333333, 'modal pemakaian proporsional');
  perform pg_temp.check((select qty_base = 1 from private.stock_positions where id = v_led_pos)
    and (select remaining_qty = 1 and remaining_cost = 6666.666667 from private.inventory_lots where id = v_led_lot), 'stok & lot berkurang');

  -- Reverse 1 ke posisi asal (SHOP/SALEABLE) -> modal kumulatif 6666.666667.
  perform pg_temp.fail('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_led, 'qty', '1'), 'INVALID_INPUT');
  v := pg_temp.call('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_led, 'qty', '1', 'reason', 'Tidak jadi dipakai'));
  perform pg_temp.check((v->>'cost_restored')::numeric = 6666.666667 and (v->>'target_position_id')::uuid = v_led_pos, 'reverse 1 ke posisi asal');
  perform pg_temp.check((select qty_base = 2 from private.stock_positions where id = v_led_pos), 'posisi asal +1');
  -- Reverse sisa 1 sebagai DAMAGED -> posisi baru; total modal kembali penuh.
  v := pg_temp.call('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_led, 'qty', '1', 'target_condition', 'DAMAGED', 'reason', 'Part rusak saat dicoba'));
  v_damaged := (v->>'target_position_id')::uuid;
  perform pg_temp.check((v->>'cost_restored')::numeric = 6666.666666, 'reverse akhir memulihkan sisa modal');
  perform pg_temp.check((select condition = 'DAMAGED' and location = 'SHOP' and qty_base = 1 from private.stock_positions where id = v_damaged),
    'posisi DAMAGED baru');
  perform pg_temp.check((select remaining_qty = 3 and remaining_cost = 20000 from private.inventory_lots where id = v_led_lot), 'lot pulih penuh');
  perform pg_temp.check((select reversed_qty = qty_base and reversed_cost = cost_amount from private.cost_allocations
    where service_part_event_id = v_use_led), 'alokasi reversed penuh');
  perform pg_temp.fail('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_led, 'qty', '1', 'reason', 'lagi'), 'REFUND_LIMIT_EXCEEDED');
  perform pg_temp.fail('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_damaged, 'qty', '1'), 'INVALID_INPUT');

  -- Roll: potong 2,5 m dari roll bersegel -> segel terbuka; reverse 1 m ke dompet lapangan = posisi baru.
  v := pg_temp.call('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_r1, 'qty', '2.5', 'charge_unit_price', '7500'));
  v_use_roll := (v->>'part_event_id')::uuid;
  perform pg_temp.check((v->>'cost')::numeric = 12500, 'modal kabel 2,5 m');
  perform pg_temp.check((select qty_base = 97.5 and not sealed from private.stock_positions where id = v_r1), 'roll terpotong');
  v := pg_temp.call('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_roll, 'qty', '1', 'target_location', 'FIELD_FATHER', 'reason', 'Sisa potongan dibawa ayah'));
  v_field_pos := (v->>'target_position_id')::uuid;
  perform pg_temp.check((v->>'cost_restored')::numeric = 5000, 'modal 1 m kembali');
  perform pg_temp.check((select location = 'FIELD_FATHER' and qty_base = 1 and segment_capacity = 1 and not sealed
    and label like 'UJI-R1-K%' and lot_id = v_roll_lot from private.stock_positions where id = v_field_pos), 'potongan kembali posisi baru');
  perform pg_temp.check((select qty_base = 97.5 from private.stock_positions where id = v_r1), 'roll asal tidak disambung');
  v := pg_temp.call('use_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'position_id', v_field_pos, 'qty', '0.5'));
  v_use_field := (v->>'part_event_id')::uuid;

  -- Invariant ledger: movement = qty posisi; cost_delta lot = remaining_cost; posisi = remaining_qty.
  perform pg_temp.check(not exists (select 1 from private.stock_positions s
    where s.qty_base <> coalesce((select sum(m.qty_delta) from private.stock_movements m where m.position_id = s.id), 0)), 'ledger qty posisi');
  perform pg_temp.check(not exists (select 1 from private.inventory_lots l
    where l.remaining_cost <> coalesce((select sum(m.cost_delta) from private.stock_movements m where m.lot_id = l.id), 0)
       or l.remaining_qty <> coalesce((select sum(s.qty_base) from private.stock_positions s where s.lot_id = l.id), 0)), 'ledger lot');
  perform pg_temp.check((select count(*) from private.stock_movements where service_part_event_id is not null
    and kind = 'RETURN_IN') = 3, 'movement RETURN_IN per reverse');

  -- Tagihan: USE bersih wajib tepat satu baris PART; USE yang direverse penuh tidak ditagih.
  perform pg_temp.set_status(v_t, 'READY', jsonb_build_object('test_result', 'Instalasi menyala normal'));
  v_other := pg_temp.new_store_ticket('Tiket Lain', '081266661111');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', pg_temp.labor('50000') || jsonb_build_array(
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'unit_price', '7500'))), 'PART_LINE_REQUIRED');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', jsonb_build_array(
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'quantity', '2.5', 'unit_price', '7500'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_field, 'unit_price', '0'))), 'INVALID_INPUT');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', jsonb_build_array(
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'unit_price', '7500'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'unit_price', '7500'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_field, 'unit_price', '0'))), 'INVALID_INPUT');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', jsonb_build_array(
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'unit_price', '7500'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_field, 'unit_price', '0'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_led, 'unit_price', '0'))), 'INVALID_INPUT');
  perform pg_temp.fail('finalize_service_invoice_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'approved_estimate_revision', 1, 'charge_lines', jsonb_build_array(
      jsonb_build_object('kind', 'LABOR', 'service_part_event_id', v_use_roll, 'description', 'x', 'quantity', '1', 'unit_price', '1'),
      jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_field, 'unit_price', '0'))), 'INVALID_INPUT');
  v := pg_temp.finalize(v_t, jsonb_build_array(
    jsonb_build_object('kind', 'LABOR', 'description', 'Pasang instalasi', 'quantity', '1', 'unit_price', '50000'),
    jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_roll, 'unit_price', '7500'),
    jsonb_build_object('kind', 'PART', 'service_part_event_id', v_use_field, 'unit_price', '0')),
    jsonb_build_object('approved_estimate_revision', 1));
  perform pg_temp.check(v->>'total' = '61250', 'total 50.000 + 1,5 m x 7.500 + 0');
  perform pg_temp.check((v->>'cost_recognized')::numeric = 7500 + 2500, 'COGS bersih diakui (part Rp0 tetap diakui)');
  perform pg_temp.check((select count(*) from private.service_cost_recognitions where invoice_id = (v->>'invoice_id')::uuid) = 2
    and not exists (select 1 from private.service_cost_recognitions where part_event_id = v_use_led), 'USE direverse penuh tidak diakui');
  perform pg_temp.check((select qty_sell = 1.5 and qty_base = 1.5 and net_total = 11250 from private.invoice_items
    where service_part_event_id = v_use_roll), 'baris part snapshot qty bersih');

  -- Setelah final: part tidak bisa ditambah/direverse (koreksi lewat credit note).
  perform pg_temp.fail('reverse_service_part_v1', jsonb_build_object('ticket_id', v_t, 'expected_version', pg_temp.ver(v_t),
    'use_event_id', v_use_roll, 'qty', '0.5', 'reason', 'Setelah final'), 'ALREADY_FINALIZED');
  perform pg_temp.fail('reverse_service_part_v1', jsonb_build_object('ticket_id', v_other, 'expected_version', pg_temp.ver(v_other),
    'use_event_id', v_use_roll, 'qty', '0.5', 'reason', 'Tiket salah'), 'NOT_FOUND');

  -- Detail owner memuat modal; staff tidak.
  v := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_t));
  perform pg_temp.check((v->'invoice'->>'cost_recognized')::numeric = 10000 and v->'part_events'->0->>'cost' is not null, 'owner melihat modal');
  perform pg_temp.as_user('staff');
  v := pg_temp.call('get_service_ticket_v1', jsonb_build_object('ticket_id', v_t));
  perform pg_temp.check(not exists (select 1 from jsonb_array_elements(v->'part_events') e where e->'cost' <> 'null'::jsonb), 'staff tanpa modal');
end $$;

rollback;
