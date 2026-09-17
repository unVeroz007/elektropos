-- Perbaikan audit 2026-09 K11: koreksi metode/pemegang pembayaran pelanggan (BR-07).
--
-- Keputusan:
-- * Efek kas ditulis ke sesi OPEN saat ini dari cashbox terkait, bukan sesi asal
--   (yang mungkin sudah ditutup). Riwayat tutup kas tidak berubah.
-- * Pembalikan tunai hanya bila penerimaan asal benar-benar tercatat masuk kas
--   (ada cash_movement); saldo kas saat ini wajib cukup (INSUFFICIENT_CASH).
-- * Penerimaan yang sudah direfund sebagian boleh dikoreksi untuk SISA saldonya
--   (amount - refund teralokasi). Bagian yang sudah direfund tetap seperti adanya;
--   refund berikutnya mengacu PAYMENT_REPLACEMENT. Refund penuh ditolak.
-- * Satu koreksi per pembayaran. Pengganti (PAYMENT_REPLACEMENT) dapat dikoreksi lagi.

create or replace function public.correct_payment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_id uuid; v_method text; v_new_box text; v_reason text; v_reference text;
  v_orig private.payments%rowtype; v_old_box text; v_code text; v_refunded numeric(20,0);
  v_amount numeric(20,0); v_session private.cash_sessions%rowtype; v_expected numeric(20,0);
  v_reversal uuid; v_replacement uuid; v_op uuid;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input,
    array['operation_id', 'original_payment_id', 'method', 'cashbox', 'confirmed', 'reference', 'reason'],
    'koreksi pembayaran');
  v_old := private.operation_result('correct_payment_v1', p_input);
  if v_old is not null then return v_old; end if;
  v_op := (p_input->>'operation_id')::uuid;

  v_id := private.input_uuid(p_input->'original_payment_id', 'original_payment_id');
  v_method := p_input->>'method';
  if v_method is null or v_method not in ('CASH', 'TRANSFER', 'QRIS') then
    raise exception 'INVALID_INPUT: Metode wajib CASH, TRANSFER, atau QRIS' using errcode = '22023';
  end if;
  if v_method = 'CASH' then
    v_new_box := private.cash_cashbox_input(p_input->'cashbox', 'cashbox');
    if p_input ? 'confirmed' then
      raise exception 'INVALID_INPUT: Konfirmasi hanya untuk TRANSFER/QRIS' using errcode = '22023';
    end if;
  else
    if p_input ? 'cashbox' then
      raise exception 'INVALID_INPUT: Kas hanya diisi untuk metode tunai' using errcode = '22023';
    end if;
    if not private.input_bool(p_input->'confirmed', 'confirmed', false) then
      raise exception 'PAYMENT_NOT_CONFIRMED: Pastikan uang % benar-benar sudah diterima, lalu centang konfirmasi',
        v_method using errcode = '22023';
    end if;
  end if;
  v_reason := private.input_text(p_input->'reason', 'Alasan', 500, true);
  v_reference := private.input_text(p_input->'reference', 'Referensi', 120);

  -- Baca tanpa kunci untuk mengetahui kas yang terlibat; kunci mengikuti urutan
  -- global: sesi kas (id) lalu pembayaran asal.
  select * into v_orig from private.payments where id = v_id;
  if not found then
    raise exception 'NOT_FOUND: Pembayaran tidak ditemukan' using errcode = '22023';
  end if;
  select s.cashbox_id into v_old_box from private.cash_movements m
    join private.cash_sessions s on s.id = m.session_id where m.payment_id = v_id;

  for v_code in select cashbox_id from private.cash_sessions
    where status = 'OPEN' and cashbox_id in (v_old_box, v_new_box) order by id
  loop
    perform private.lock_open_cash_session(v_code);
  end loop;

  select * into v_orig from private.payments where id = v_id for update;
  if v_orig.direction <> 'IN' or v_orig.purpose not in ('SALE_RECEIPT', 'SERVICE_RECEIPT', 'PAYMENT_REPLACEMENT') then
    raise exception 'INVALID_INPUT: Koreksi hanya untuk pembayaran yang diterima dari pelanggan' using errcode = '22023';
  end if;
  if exists (select 1 from private.payments where original_payment_id = v_orig.id
      and purpose in ('PAYMENT_REVERSAL', 'PAYMENT_REPLACEMENT')) then
    raise exception 'ALREADY_CORRECTED: Pembayaran ini sudah pernah dikoreksi; koreksi pembayaran penggantinya'
      using errcode = '40001';
  end if;
  if v_method = v_orig.method and (v_method <> 'CASH' or v_old_box is not distinct from v_new_box) then
    raise exception 'INVALID_INPUT: Metode dan pemegang uang baru sama dengan yang lama' using errcode = '22023';
  end if;

  -- Refund teralokasi + refund lama tanpa alokasi yang menunjuk pembayaran ini.
  select coalesce((select sum(amount) from private.refund_allocations where original_payment_id = v_orig.id), 0)
       + coalesce((select sum(p.amount) from private.payments p
           where p.original_payment_id = v_orig.id and p.purpose = 'CUSTOMER_REFUND'
             and not exists (select 1 from private.refund_allocations ra where ra.refund_payment_id = p.id)), 0)
    into v_refunded;
  v_amount := v_orig.amount - v_refunded;
  if v_amount <= 0 then
    raise exception 'REFUND_LIMIT_EXCEEDED: Pembayaran ini sudah dikembalikan seluruhnya; tidak ada yang dapat dikoreksi'
      using errcode = '22023';
  end if;

  -- Pembalikan: uang keluar dari kas yang dulu menerimanya (sesi yang sedang buka).
  v_session := null;
  if v_old_box is not null then
    v_session := private.lock_open_cash_session(v_old_box);
    v_expected := private.cash_session_expected(v_session.id);
    if v_expected < v_amount then
      raise exception 'INSUFFICIENT_CASH: Saldo kas % tidak cukup untuk membalik %',
        private.cash_rupiah(v_expected), private.cash_rupiah(v_amount) using errcode = '22023';
    end if;
  end if;

  insert into private.payments(direction, purpose, invoice_id, service_ticket_id, original_payment_id,
    method, amount, cash_session_id, reference, actor_id, operation_id)
  values ('OUT', 'PAYMENT_REVERSAL', v_orig.invoice_id, v_orig.service_ticket_id, v_orig.id,
    v_orig.method, v_amount, v_session.id, v_reference, v_actor, v_op)
  returning id into v_reversal;
  if v_session.id is not null then
    insert into private.cash_movements(session_id, direction, kind, amount, payment_id, reason, actor_id, operation_id)
    values (v_session.id, 'OUT', 'CORRECTION', v_amount, v_reversal, v_reason, v_actor, v_op);
  end if;

  -- Pengganti dengan metode/pemegang yang benar.
  v_session := null;
  if v_method = 'CASH' then
    v_session := private.lock_open_cash_session(v_new_box);
  end if;
  insert into private.payments(direction, purpose, invoice_id, service_ticket_id, original_payment_id,
    method, amount, cash_session_id, reference, confirmed_by, actor_id, operation_id)
  values ('IN', 'PAYMENT_REPLACEMENT', v_orig.invoice_id, v_orig.service_ticket_id, v_orig.id,
    v_method, v_amount, v_session.id, v_reference,
    case when v_method <> 'CASH' then v_actor end, v_actor, v_op)
  returning id into v_replacement;
  if v_session.id is not null then
    insert into private.cash_movements(session_id, direction, kind, amount, payment_id, reason, actor_id, operation_id)
    values (v_session.id, 'IN', 'CORRECTION', v_amount, v_replacement, v_reason, v_actor, v_op);
  end if;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CORRECT_PAYMENT', 'PAYMENT', v_orig.id, v_reason);

  return private.finish_operation('correct_payment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_replacement, 'original_payment_id', v_orig.id,
    'reversal_payment_id', v_reversal, 'replacement_payment_id', v_replacement,
    'amount', v_amount::text, 'already_refunded', v_refunded::text,
    'old_method', v_orig.method, 'old_cashbox', v_old_box,
    'new_method', v_method, 'new_cashbox', v_new_box,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.correct_payment_v1(jsonb) from public, anon, authenticated;
grant execute on function public.correct_payment_v1(jsonb) to authenticated;
