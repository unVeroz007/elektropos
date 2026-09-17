-- Perbaikan audit 2026-09: RPC sesi kas, penyesuaian, pindah kas (D1, S09, K10).
-- Aturan: BR-12. Seluruh penulis mutasi mengunci sesi lewat private.lock_open_cash_session.

-- Saldo sistem sesi = saldo buka + masuk - keluar.
create or replace function private.cash_session_expected(p_session uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select s.opening_amount
    + coalesce((select sum(case m.direction when 'IN' then m.amount else -m.amount end)
        from private.cash_movements m where m.session_id = s.id), 0)
  from private.cash_sessions s where s.id = p_session
$$;
revoke all on function private.cash_session_expected(uuid) from public, anon, authenticated;

-- Ringkasan sesi untuk get/list (tanpa daftar mutasi).
create or replace function private.cash_session_json(p_session private.cash_sessions)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_session.id, 'cashbox_code', p_session.cashbox_id,
    'cashbox_label', (select label from private.cashboxes where code = p_session.cashbox_id),
    'status', p_session.status, 'open', p_session.status = 'OPEN',
    'business_date', p_session.business_date,
    'opened_at', p_session.opened_at,
    'opened_by_name', (select display_name from private.app_profiles where id = p_session.opened_by),
    'opening_amount', p_session.opening_amount::text,
    'previous_session_id', p_session.previous_session_id,
    'previous_counted_amount', (select counted_amount::text from private.cash_sessions
      where id = p_session.previous_session_id),
    'opening_variance', p_session.opening_variance::text,
    'opening_note', p_session.opening_note,
    'expected', case when p_session.status = 'OPEN'
      then private.cash_session_expected(p_session.id) else p_session.expected_snapshot end::text,
    'total_in', coalesce((select sum(amount) from private.cash_movements
      where session_id = p_session.id and direction = 'IN'), 0)::text,
    'total_out', coalesce((select sum(amount) from private.cash_movements
      where session_id = p_session.id and direction = 'OUT'), 0)::text,
    'closed_at', p_session.closed_at,
    'closed_by_name', (select display_name from private.app_profiles where id = p_session.closed_by),
    'counted_amount', p_session.counted_amount::text,
    'variance', p_session.variance::text,
    'close_note', p_session.note,
    'needs_review', p_session.needs_review,
    'review_pending', p_session.needs_review and p_session.reviewed_at is null,
    'reviewed_at', p_session.reviewed_at,
    'review_note', p_session.review_note,
    'version', p_session.version)
$$;
revoke all on function private.cash_session_json(private.cash_sessions) from public, anon, authenticated;

-- === open_cash_session_v1 =================================================
create or replace function public.open_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_old jsonb; v_code text; v_amount numeric(20,0); v_note text;
  v_prev private.cash_sessions%rowtype; v_variance numeric(20,0); v_session private.cash_sessions%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.input_keys_only(p_input, array['operation_id', 'cashbox_code', 'opening_amount', 'note'], 'buka kas');
  v_old := private.operation_result('open_cash_session_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_code := private.cash_cashbox_input(p_input->'cashbox_code');
  if v_code = 'FATHER_WALLET' and v_role <> 'OWNER' then
    raise exception 'FORBIDDEN: Hanya pemilik yang dapat membuka dompet ayah' using errcode = '42501';
  end if;
  v_amount := private.input_decimal(p_input->'opening_amount', 0, 9999999999999999, false, 'Saldo buka');
  v_note := private.input_text(p_input->'note', 'Keterangan', 500);

  -- Kunci cashbox: pembukaan bersamaan antre di sini lalu melihat sesi yang baru dibuka.
  perform 1 from private.cashboxes where code = v_code and active for update;
  if not found then
    raise exception 'NOT_FOUND: Kas tidak aktif' using errcode = '22023';
  end if;
  if exists (select 1 from private.cash_sessions where cashbox_id = v_code and status = 'OPEN') then
    raise exception 'CASH_SESSION_ALREADY_OPEN: Kas masih terbuka. Tutup kas sebelumnya terlebih dahulu.'
      using errcode = '40001';
  end if;

  select * into v_prev from private.cash_sessions
    where cashbox_id = v_code and status = 'CLOSED'
    order by closed_at desc, id desc limit 1;
  if found then
    v_variance := v_amount - v_prev.counted_amount;
    if v_variance <> 0 and v_note is null then
      raise exception 'NOTE_REQUIRED: Saldo buka % berbeda dari hitungan tutup terakhir %. Tulis keterangan.',
        private.cash_rupiah(v_amount), private.cash_rupiah(v_prev.counted_amount) using errcode = '22023';
    end if;
  end if;

  begin
    insert into private.cash_sessions(cashbox_id, opened_by, business_date, opening_amount,
      previous_session_id, opening_variance, opening_note, needs_review)
    values (v_code, v_actor, private.local_today(), v_amount,
      v_prev.id, v_variance, v_note, coalesce(v_variance, 0) <> 0)
    returning * into v_session;
  exception when unique_violation then
    raise exception 'CASH_SESSION_ALREADY_OPEN: Kas masih terbuka. Tutup kas sebelumnya terlebih dahulu.'
      using errcode = '40001';
  end;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'OPEN_CASH_SESSION', 'CASH_SESSION', v_session.id, v_note);

  return private.finish_operation('open_cash_session_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'cashbox_code', v_code,
    'opening_amount', v_amount::text,
    'previous_counted_amount', v_prev.counted_amount::text,
    'opening_variance', v_variance::text, 'needs_review', v_session.needs_review,
    'version', v_session.version, 'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.open_cash_session_v1(jsonb) from public, anon, authenticated;
grant execute on function public.open_cash_session_v1(jsonb) to authenticated;

-- === close_cash_session_v1 ================================================
create or replace function public.close_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_old jsonb; v_id uuid; v_session private.cash_sessions%rowtype;
  v_expected numeric(20,0); v_counted numeric(20,0); v_variance numeric(20,0); v_note text;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.input_keys_only(p_input,
    array['operation_id', 'session_id', 'expected_version', 'counted_amount', 'note'], 'tutup kas');
  v_old := private.operation_result('close_cash_session_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_id := private.input_uuid(p_input->'session_id', 'session_id');
  v_counted := private.input_decimal(p_input->'counted_amount', 0, 9999999999999999, false, 'Uang terhitung');
  v_note := private.input_text(p_input->'note', 'Keterangan', 500);

  -- Kunci dulu, baru periksa status dan hitung saldo: mutasi yang sedang
  -- berjalan sudah commit (terhitung) atau akan ditolak trigger karena CLOSED.
  select * into v_session from private.cash_sessions where id = v_id for update;
  if not found then
    raise exception 'NOT_FOUND: Sesi kas tidak ditemukan' using errcode = '22023';
  end if;
  if v_session.cashbox_id = 'FATHER_WALLET' and v_role <> 'OWNER' then
    raise exception 'FORBIDDEN: Hanya pemilik yang dapat menutup dompet ayah' using errcode = '42501';
  end if;
  if v_session.status <> 'OPEN' then
    raise exception 'CASH_SESSION_CLOSED: Sesi kas sudah ditutup' using errcode = '40001';
  end if;
  if v_session.version <> private.input_version(p_input->'expected_version') then
    raise exception 'VERSION_CONFLICT: Data kas berubah. Muat ulang lalu hitung lagi.' using errcode = '40001';
  end if;

  v_expected := private.cash_session_expected(v_session.id);
  v_variance := v_counted - v_expected;
  if v_variance <> 0 and v_note is null then
    raise exception 'NOTE_REQUIRED: Uang terhitung berbeda % dari saldo sistem. Tulis keterangan.',
      private.cash_rupiah(v_variance) using errcode = '22023';
  end if;

  update private.cash_sessions set
    status = 'CLOSED', closed_at = now(), closed_by = v_actor,
    counted_amount = v_counted, expected_snapshot = v_expected, variance = v_variance, note = v_note,
    needs_review = needs_review or v_variance <> 0,
    reviewed_at = case when v_variance <> 0 then null else reviewed_at end,
    reviewed_by = case when v_variance <> 0 then null else reviewed_by end,
    version = version + 1
    where id = v_session.id returning * into v_session;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CLOSE_CASH_SESSION', 'CASH_SESSION', v_session.id, v_note);

  return private.finish_operation('close_cash_session_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'cashbox_code', v_session.cashbox_id,
    'expected', v_expected::text, 'counted', v_counted::text, 'variance', v_variance::text,
    'needs_review', v_session.needs_review, 'version', v_session.version,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.close_cash_session_v1(jsonb) from public, anon, authenticated;
grant execute on function public.close_cash_session_v1(jsonb) to authenticated;

-- === get_cash_session_v1 ==================================================
create or replace function public.get_cash_session_v1(p_input jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor uuid; v_role text; v_id uuid; v_code text; v_session private.cash_sessions%rowtype;
  v_last private.cash_sessions%rowtype;
begin
  v_actor := private.require_role(array['OWNER', 'STAFF', 'MAINTAINER']);
  select role into v_role from private.app_profiles where id = v_actor;
  perform private.input_keys_only(coalesce(p_input, '{}'::jsonb), array['session_id', 'cashbox_code'], 'lihat kas');
  v_id := private.input_uuid(p_input->'session_id', 'session_id', false);

  if v_id is not null then
    select * into v_session from private.cash_sessions where id = v_id;
    if not found then
      raise exception 'NOT_FOUND: Sesi kas tidak ditemukan' using errcode = '22023';
    end if;
    v_code := v_session.cashbox_id;
  else
    v_code := case when p_input ? 'cashbox_code' then private.cash_cashbox_input(p_input->'cashbox_code')
      else 'SHOP_DRAWER' end;
  end if;
  if v_role = 'STAFF' and v_code <> 'SHOP_DRAWER' then
    raise exception 'FORBIDDEN: Karyawan hanya dapat melihat laci toko' using errcode = '42501';
  end if;

  if v_id is null then
    select * into v_session from private.cash_sessions
      where cashbox_id = v_code and status = 'OPEN' order by opened_at desc limit 1;
    if not found then
      select * into v_last from private.cash_sessions
        where cashbox_id = v_code and status = 'CLOSED' order by closed_at desc, id desc limit 1;
      return jsonb_build_object('open', false, 'cashbox_code', v_code,
        'last_session_id', v_last.id, 'last_closed_at', v_last.closed_at,
        'last_counted_amount', v_last.counted_amount::text);
    end if;
  end if;

  return private.cash_session_json(v_session) || jsonb_build_object(
    'movements', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'direction', m.direction, 'kind', m.kind,
      'label', private.cash_kind_label(m.kind, m.direction),
      'amount', m.amount::text, 'reason', m.reason, 'occurred_at', m.occurred_at,
      'actor_name', (select display_name from private.app_profiles where id = m.actor_id),
      'reference', coalesce(
        (select i.number from private.payments p join private.invoices i on i.id = p.invoice_id where p.id = m.payment_id),
        (select t.number from private.payments p join private.service_tickets t on t.id = p.service_ticket_id where p.id = m.payment_id),
        (select d.number from private.stock_documents d where d.id = m.stock_document_id),
        (select d.number from private.supplier_returns r join private.stock_documents d on d.id = r.stock_document_id
          where r.id = m.supplier_return_id))
    ) order by m.occurred_at desc, m.id), '[]'::jsonb)
    from private.cash_movements m where m.session_id = v_session.id));
end $$;
revoke all on function public.get_cash_session_v1(jsonb) from public, anon, authenticated;
grant execute on function public.get_cash_session_v1(jsonb) to authenticated;

-- === list_cash_sessions_v1 ================================================
create or replace function public.list_cash_sessions_v1(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_range record; v_code text; v_pending boolean; v_limit integer; v_offset integer;
begin
  perform private.require_role(array['OWNER', 'MAINTAINER']);
  perform private.input_keys_only(p_input,
    array['start_date', 'end_date', 'cashbox_code', 'review_pending', 'limit', 'offset'], 'riwayat kas');
  select * into v_range from private.date_range_input(p_input, 366);
  if p_input ? 'cashbox_code' then v_code := private.cash_cashbox_input(p_input->'cashbox_code'); end if;
  v_pending := private.input_bool(p_input->'review_pending', 'review_pending', false);
  v_limit := coalesce(private.decimal_input_opt(p_input->'limit', 0, 200), 50);
  v_offset := coalesce(private.decimal_input_opt(p_input->'offset', 0, 1000000, false), 0);

  return jsonb_build_object(
    'total', (select count(*) from private.cash_sessions s
      where s.business_date between v_range.start_date and v_range.end_date
        and (v_code is null or s.cashbox_id = v_code)
        and (not v_pending or (s.needs_review and s.reviewed_at is null))),
    'items', (select coalesce(jsonb_agg(private.cash_session_json(s) order by s.opened_at desc, s.id), '[]'::jsonb)
      from private.cash_sessions s where s.id in (select x.id from private.cash_sessions x
        where x.business_date between v_range.start_date and v_range.end_date
          and (v_code is null or x.cashbox_id = v_code)
          and (not v_pending or (x.needs_review and x.reviewed_at is null))
        order by x.opened_at desc, x.id limit v_limit offset v_offset)));
end $$;
revoke all on function public.list_cash_sessions_v1(jsonb) from public, anon, authenticated;
grant execute on function public.list_cash_sessions_v1(jsonb) to authenticated;

-- === review_cash_session_v1 ===============================================
-- Owner menandai selisih buka/tutup sudah ditinjau; angka sesi tidak berubah.
create or replace function public.review_cash_session_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_old jsonb; v_session private.cash_sessions%rowtype; v_note text;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input, array['operation_id', 'session_id', 'expected_version', 'note'], 'tinjau kas');
  v_old := private.operation_result('review_cash_session_v1', p_input);
  if v_old is not null then return v_old; end if;
  v_note := private.input_text(p_input->'note', 'Catatan tinjauan', 500, true);

  select * into v_session from private.cash_sessions
    where id = private.input_uuid(p_input->'session_id', 'session_id') for update;
  if not found then
    raise exception 'NOT_FOUND: Sesi kas tidak ditemukan' using errcode = '22023';
  end if;
  if v_session.version <> private.input_version(p_input->'expected_version') then
    raise exception 'VERSION_CONFLICT: Data kas berubah. Muat ulang.' using errcode = '40001';
  end if;
  if not v_session.needs_review or v_session.reviewed_at is not null then
    raise exception 'INVALID_INPUT: Sesi kas ini tidak menunggu tinjauan' using errcode = '22023';
  end if;

  update private.cash_sessions set reviewed_by = v_actor, reviewed_at = now(), review_note = v_note,
    version = version + 1 where id = v_session.id returning * into v_session;
  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'REVIEW_CASH_SESSION', 'CASH_SESSION', v_session.id, v_note);

  return private.finish_operation('review_cash_session_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_session.id, 'version', v_session.version,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.review_cash_session_v1(jsonb) from public, anon, authenticated;
grant execute on function public.review_cash_session_v1(jsonb) to authenticated;

-- === record_cash_adjustment_v1 ============================================
create or replace function public.record_cash_adjustment_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_code text; v_direction text; v_kind text; v_amount numeric(20,0);
  v_reason text; v_session private.cash_sessions%rowtype; v_expected numeric(20,0); v_movement uuid;
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input,
    array['operation_id', 'cashbox_code', 'direction', 'kind', 'amount', 'reason'], 'penyesuaian kas');
  v_old := private.operation_result('record_cash_adjustment_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_code := private.cash_cashbox_input(p_input->'cashbox_code');
  v_direction := p_input->>'direction';
  if v_direction is null or v_direction not in ('IN', 'OUT') then
    raise exception 'INVALID_INPUT: Arah wajib IN (uang masuk) atau OUT (uang keluar)' using errcode = '22023';
  end if;
  v_kind := coalesce(p_input->>'kind', case v_direction when 'IN' then 'OWNER_ADD' else 'OWNER_WITHDRAW' end);
  if (v_direction = 'IN' and v_kind <> 'OWNER_ADD')
     or (v_direction = 'OUT' and v_kind not in ('OWNER_WITHDRAW', 'EXPENSE')) then
    raise exception 'INVALID_INPUT: Jenis penyesuaian tidak sesuai arah' using errcode = '22023';
  end if;
  v_amount := private.input_decimal(p_input->'amount', 0, 9999999999999999, true, 'Jumlah');
  v_reason := private.input_text(p_input->'reason', 'Alasan', 500, true);

  v_session := private.lock_open_cash_session(v_code);
  if v_direction = 'OUT' then
    v_expected := private.cash_session_expected(v_session.id);
    if v_expected < v_amount then
      raise exception 'INSUFFICIENT_CASH: Saldo kas sistem % tidak cukup untuk mengeluarkan %',
        private.cash_rupiah(v_expected), private.cash_rupiah(v_amount) using errcode = '22023';
    end if;
  end if;

  insert into private.cash_movements(session_id, direction, kind, amount, reason, actor_id, operation_id)
  values (v_session.id, v_direction, v_kind, v_amount, v_reason, v_actor, (p_input->>'operation_id')::uuid)
  returning id into v_movement;

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'CASH_ADJUSTMENT', 'CASH_SESSION', v_session.id, v_reason);

  return private.finish_operation('record_cash_adjustment_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_movement, 'session_id', v_session.id, 'cashbox_code', v_code,
    'direction', v_direction, 'kind', v_kind, 'amount', v_amount::text,
    'expected', private.cash_session_expected(v_session.id)::text,
    'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.record_cash_adjustment_v1(jsonb) from public, anon, authenticated;
grant execute on function public.record_cash_adjustment_v1(jsonb) to authenticated;

-- === transfer_cash_v1 =====================================================
create or replace function public.transfer_cash_v1(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid; v_old jsonb; v_src_code text; v_dst_code text; v_code text; v_amount numeric(20,0);
  v_reason text; v_source private.cash_sessions%rowtype; v_target private.cash_sessions%rowtype;
  v_expected numeric(20,0); v_group uuid := gen_random_uuid();
begin
  v_actor := private.require_role(array['OWNER']);
  perform private.input_keys_only(p_input,
    array['operation_id', 'source_cashbox', 'target_cashbox', 'amount', 'reason'], 'pindah kas');
  v_old := private.operation_result('transfer_cash_v1', p_input);
  if v_old is not null then return v_old; end if;

  v_src_code := private.cash_cashbox_input(p_input->'source_cashbox', 'source_cashbox');
  v_dst_code := private.cash_cashbox_input(p_input->'target_cashbox', 'target_cashbox');
  if v_src_code = v_dst_code then
    raise exception 'INVALID_INPUT: Kas asal dan tujuan harus berbeda' using errcode = '22023';
  end if;
  v_amount := private.input_decimal(p_input->'amount', 0, 9999999999999999, true, 'Jumlah');
  v_reason := private.input_text(p_input->'reason', 'Alasan', 500, true);

  -- Kunci kedua sesi dalam urutan id agar dua pindahan berlawanan tidak deadlock.
  for v_code in select cashbox_id from private.cash_sessions
    where status = 'OPEN' and cashbox_id in (v_src_code, v_dst_code) order by id
  loop
    perform private.lock_open_cash_session(v_code);
  end loop;
  v_source := private.lock_open_cash_session(v_src_code);
  v_target := private.lock_open_cash_session(v_dst_code);

  v_expected := private.cash_session_expected(v_source.id);
  if v_expected < v_amount then
    raise exception 'INSUFFICIENT_CASH: Saldo kas asal % tidak cukup untuk memindahkan %',
      private.cash_rupiah(v_expected), private.cash_rupiah(v_amount) using errcode = '22023';
  end if;

  insert into private.cash_movements(session_id, direction, kind, amount, transfer_group_id, reason, actor_id, operation_id)
  values (v_source.id, 'OUT', 'TRANSFER', v_amount, v_group, v_reason, v_actor, (p_input->>'operation_id')::uuid),
         (v_target.id, 'IN', 'TRANSFER', v_amount, v_group, v_reason, v_actor, (p_input->>'operation_id')::uuid);

  insert into private.audit_events(actor_id, action, entity_type, entity_id, reason)
  values (v_actor, 'TRANSFER_CASH', 'CASH_SESSION', v_source.id, v_reason);

  return private.finish_operation('transfer_cash_v1', p_input, jsonb_build_object(
    'ok', true, 'entity_id', v_group, 'transfer_group_id', v_group,
    'source_session_id', v_source.id, 'target_session_id', v_target.id,
    'amount', v_amount::text, 'server_time', now(), 'operation_id', p_input->>'operation_id'));
end $$;
revoke all on function public.transfer_cash_v1(jsonb) from public, anon, authenticated;
grant execute on function public.transfer_cash_v1(jsonb) to authenticated;
