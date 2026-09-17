-- Perbaikan audit domain SERVIS (1/5): skema pendukung dan helper bersama.
-- Temuan: K07, K08, K09, K12, T06, S05 (lihat docs/audit/PERBAIKAN-AUDIT-2026-09.md).
-- Semua helper berprefiks `srv_` agar tidak bertabrakan dengan helper domain lain.

-- Skema -------------------------------------------------------------------

-- WF-05 memuat WAITING_PARTS; nilai lama (DIAMBIL/ONSITE_DONE) dibiarkan agar data lama tetap sah.
alter table private.service_tickets drop constraint if exists service_tickets_work_status_check;
alter table private.service_tickets add constraint service_tickets_work_status_check check (work_status in (
  'NEW','INSPECTING','AWAITING_APPROVAL','WAITING_PARTS','WORKING',
  'READY','DIAMBIL','ONSITE_DONE','UNREPAIRABLE','CANCELLED'));

-- DATA-04: penanda serah terima eksplisit pada log custody.
alter table private.service_custody_events
  add column if not exists is_handover boolean not null default false;

-- DATA-04: bukti modal/posisi yang dipulihkan oleh reversal part sebelum invoice.
create table if not exists private.part_reversal_allocations (
  id uuid primary key default gen_random_uuid(),
  reversal_event_id uuid not null references private.service_part_events(id),
  original_cost_allocation_id uuid not null references private.cost_allocations(id),
  qty_base numeric(18,3) not null check (qty_base > 0),
  cost_amount numeric(24,6) not null check (cost_amount >= 0),
  target_position_id uuid not null references private.stock_positions(id)
);
alter table private.part_reversal_allocations enable row level security;
revoke all on private.part_reversal_allocations from public, anon, authenticated;
create index if not exists part_reversal_allocations_event
  on private.part_reversal_allocations(reversal_event_id);

-- Satu pemakaian part hanya boleh tertaut ke satu baris invoice (BR-09).
create unique index if not exists invoice_items_part_event_unique
  on private.invoice_items(service_part_event_id) where service_part_event_id is not null;

create index if not exists service_tickets_list on private.service_tickets(created_at desc, id desc);
create index if not exists service_tickets_customer on private.service_tickets(customer_id, created_at desc);
create index if not exists service_tickets_parent on private.service_tickets(parent_ticket_id)
  where parent_ticket_id is not null;
create index if not exists service_part_events_ticket on private.service_part_events(ticket_id, occurred_at);
create index if not exists service_part_events_reverses on private.service_part_events(reverses_event_id)
  where reverses_event_id is not null;
create index if not exists service_status_events_ticket on private.service_status_events(ticket_id, id);
create index if not exists service_custody_events_ticket on private.service_custody_events(ticket_id, id);
create index if not exists payments_original on private.payments(original_payment_id)
  where original_payment_id is not null;
create index if not exists refund_allocations_original on private.refund_allocations(original_payment_id);
create index if not exists customers_name_lower on private.customers(lower(name));

-- Validasi input JSON --------------------------------------------------------

-- Perintah bisnis menolak kolom tak dikenal (API-01), mis. cash_session_id dari klien.
create or replace function private.srv_keys(p_input jsonb, p_allowed text[])
returns void language plpgsql immutable set search_path = '' as $$
declare v_key text;
begin
  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise exception 'INVALID_INPUT: Data permintaan harus berupa objek JSON' using errcode = '22023';
  end if;
  select k into v_key from jsonb_object_keys(p_input) k where not (k = any (p_allowed)) order by k limit 1;
  if v_key is not null then
    raise exception 'INVALID_INPUT: Kolom "%" tidak dikenal untuk perintah ini', v_key using errcode = '22023';
  end if;
end $$;

create or replace function private.srv_uuid(p_input jsonb, p_key text, p_required boolean default true)
returns uuid language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_input->p_key; v_id uuid;
begin
  if v is null or jsonb_typeof(v) = 'null' or (jsonb_typeof(v) = 'string' and v #>> '{}' = '') then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_key using errcode = '22023';
    end if;
    return null;
  end if;
  if jsonb_typeof(v) <> 'string' then
    raise exception 'INVALID_INPUT: % harus berupa ID teks', p_key using errcode = '22023';
  end if;
  begin
    v_id := (v #>> '{}')::uuid;
  exception when others then
    raise exception 'INVALID_INPUT: % tidak sah', p_key using errcode = '22023';
  end;
  return v_id;
end $$;

-- Teks dirapikan; string kosong dianggap tidak diisi.
create or replace function private.srv_text(p_input jsonb, p_key text, p_max integer, p_required boolean default false)
returns text language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_input->p_key; v_text text;
begin
  if v is not null and jsonb_typeof(v) not in ('string', 'null') then
    raise exception 'INVALID_INPUT: % harus berupa teks', p_key using errcode = '22023';
  end if;
  v_text := nullif(trim(coalesce(v #>> '{}', '')), '');
  if v_text is null and p_required then
    raise exception 'INVALID_INPUT: % wajib diisi', p_key using errcode = '22023';
  end if;
  if length(v_text) > p_max then
    raise exception 'INVALID_INPUT: % terlalu panjang (maksimal % karakter)', p_key, p_max using errcode = '22023';
  end if;
  return v_text;
end $$;

create or replace function private.srv_int(p_input jsonb, p_key text, p_required boolean,
  p_min integer, p_max integer)
returns integer language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_input->p_key; v_text text; v_int integer;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      raise exception 'INVALID_INPUT: % wajib diisi', p_key using errcode = '22023';
    end if;
    return null;
  end if;
  v_text := v #>> '{}';
  if jsonb_typeof(v) not in ('number', 'string') or v_text !~ '^-?[0-9]{1,9}$' then
    raise exception 'INVALID_INPUT: % harus bilangan bulat', p_key using errcode = '22023';
  end if;
  v_int := v_text::integer;
  if v_int < p_min or v_int > p_max then
    raise exception 'INVALID_INPUT: % di luar batas', p_key using errcode = '22023';
  end if;
  return v_int;
end $$;

create or replace function private.srv_bool(p_input jsonb, p_key text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_input->p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then return null; end if;
  if jsonb_typeof(v) <> 'boolean' then
    raise exception 'INVALID_INPUT: % harus true/false', p_key using errcode = '22023';
  end if;
  return (v #>> '{}')::boolean;
end $$;

create or replace function private.srv_ts(p_input jsonb, p_key text, p_required boolean)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare v_text text := private.srv_text(p_input, p_key, 40, p_required); v_ts timestamptz;
begin
  if v_text is null then return null; end if;
  begin
    v_ts := v_text::timestamptz;
  exception when others then
    raise exception 'INVALID_DATE: % tidak sah (format ISO 8601, mis. 2026-09-20T09:00:00+07:00)', p_key
      using errcode = '22023';
  end;
  return v_ts;
end $$;

-- Nomor HP dinormalisasi (private.normalize_phone) lalu diperiksa bentuknya.
create or replace function private.srv_phone(p_raw text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if p_raw is null or trim(p_raw) = '' then return null; end if;
  if p_raw ~ '[^0-9+ ().-]' then
    raise exception 'INVALID_PHONE: Nomor HP hanya boleh berisi angka, spasi, +, -, titik atau kurung' using errcode = '22023';
  end if;
  v := private.normalize_phone(p_raw);
  if v is null or v !~ '^0[0-9]{7,14}$' then
    raise exception 'INVALID_PHONE: Nomor HP tidak sah (contoh 0812xxxxxxxx)' using errcode = '22023';
  end if;
  return v;
end $$;

-- Idempotensi ----------------------------------------------------------------

-- Nama command WAJIB sama dengan nama RPC publik (dipakai get_operation_v1).
create or replace function private.srv_begin(p_command text, p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.srv_uuid(p_input, 'operation_id', true);
  begin
    return private.operation_result(p_command, p_input);
  exception when sqlstate '22023' then
    if sqlerrm = 'IDEMPOTENCY_CONFLICT' then
      raise exception 'IDEMPOTENCY_CONFLICT: operation_id sudah dipakai untuk data yang berbeda' using errcode = '22023';
    end if;
    raise;
  end;
end $$;

-- Tiket ----------------------------------------------------------------------

create or replace function private.srv_lock_ticket(p_ticket uuid, p_expected integer)
returns private.service_tickets language plpgsql security definer set search_path = '' as $$
declare v private.service_tickets%rowtype;
begin
  select * into v from private.service_tickets where id = p_ticket for update;
  if not found then
    raise exception 'NOT_FOUND: Tiket servis tidak ditemukan' using errcode = 'P0002';
  end if;
  if p_expected is not null and v.version <> p_expected then
    raise exception 'VERSION_CONFLICT: Data tiket sudah berubah. Muat ulang lalu periksa kembali.' using errcode = '40001';
  end if;
  return v;
end $$;

create or replace function private.srv_require_open(p_ticket private.service_tickets)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_ticket.closed_at is not null then
    raise exception 'TICKET_CLOSED: Tiket sudah ditutup. Buat tiket baru bila ada pekerjaan tambahan.' using errcode = '22023';
  end if;
end $$;

create or replace function private.srv_is_terminal(p_status text)
returns boolean language sql immutable set search_path = '' as $$
  select p_status in ('READY', 'UNREPAIRABLE', 'CANCELLED')
$$;

-- Tabel transisi WF-05.
create or replace function private.srv_allowed_targets(p_status text)
returns text[] language sql immutable set search_path = '' as $$
  select case p_status
    when 'NEW' then array['INSPECTING', 'CANCELLED']
    when 'INSPECTING' then array['AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED']
    when 'AWAITING_APPROVAL' then array['WORKING', 'WAITING_PARTS', 'CANCELLED']
    when 'WAITING_PARTS' then array['WORKING', 'AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED']
    when 'WORKING' then array['READY', 'WAITING_PARTS', 'AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED']
    else array[]::text[] end
$$;

create or replace function private.srv_has_invoice(p_ticket uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.invoices i where i.service_ticket_id = p_ticket)
$$;

-- Persetujuan aktif: revisi estimasi TERBARU harus APPROVED (BR-09/WF-05).
create or replace function private.srv_require_active_approval(p_ticket uuid)
returns private.service_estimates language plpgsql stable security definer set search_path = '' as $$
declare v private.service_estimates%rowtype;
begin
  select * into v from private.service_estimates where ticket_id = p_ticket order by revision desc limit 1;
  if not found or v.status <> 'APPROVED' then
    raise exception 'APPROVAL_REQUIRED: Biaya belum disetujui pelanggan. Catat estimasi dan persetujuannya dahulu.'
      using errcode = '22023';
  end if;
  return v;
end $$;

-- Ubah status + log event dalam satu langkah.
create or replace function private.srv_set_status(p_ticket uuid, p_from text, p_to text, p_kind text,
  p_reason text, p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update private.service_tickets set work_status = p_to where id = p_ticket;
  insert into private.service_status_events(ticket_id, from_status, to_status, kind, reason, actor_id)
  values (p_ticket, p_from, p_to, p_kind, p_reason, p_actor);
end $$;

-- Uang -------------------------------------------------------------------------

-- Status pembayaran derived BR-10. net_received memasukkan koreksi metode
-- (PAYMENT_REVERSAL keluar, PAYMENT_REPLACEMENT masuk) sehingga totalnya tetap.
create or replace function private.srv_payment_state(p_ticket uuid)
returns table(invoice_id uuid, invoice_number text, invoice_total numeric, credit_total numeric,
  invoice_net numeric, received_total numeric, refunded_total numeric, correction_net numeric,
  net_received numeric, outstanding numeric, refund_due numeric, status text)
language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.id, i.number, i.total,
      coalesce((select sum(c.total) from private.credit_notes c where c.invoice_id = i.id), 0) as credit
    from private.invoices i where i.service_ticket_id = p_ticket and i.kind = 'SERVICE'
  ), pay as (
    select
      coalesce(sum(p.amount) filter (where p.direction = 'IN' and p.purpose = 'SERVICE_RECEIPT'), 0) as received,
      coalesce(sum(p.amount) filter (where p.direction = 'OUT' and p.purpose = 'CUSTOMER_REFUND'), 0) as refunded,
      coalesce(sum(case when p.direction = 'IN' then p.amount else -p.amount end)
        filter (where p.purpose in ('PAYMENT_REVERSAL', 'PAYMENT_REPLACEMENT')), 0) as corr,
      coalesce(sum(case when p.direction = 'IN' then p.amount else -p.amount end), 0) as net
    from private.payments p
    where p.service_ticket_id = p_ticket
      and p.purpose in ('SERVICE_RECEIPT', 'CUSTOMER_REFUND', 'PAYMENT_REVERSAL', 'PAYMENT_REPLACEMENT')
  )
  select inv.id, inv.number, inv.total, inv.credit, inv.total - inv.credit,
    pay.received, pay.refunded, pay.corr, pay.net,
    case when inv.id is null then null else greatest(inv.total - inv.credit - pay.net, 0) end,
    case when inv.id is null then null else greatest(pay.net - (inv.total - inv.credit), 0) end,
    case
      when inv.id is null then 'UNPRICED'
      when pay.net > inv.total - inv.credit then 'REFUND_DUE'
      when pay.net = inv.total - inv.credit then 'PAID'
      when pay.net > 0 then 'PARTIAL'
      else 'UNPAID' end
  from pay left join inv on true
$$;

create or replace function private.srv_payment_state_json(p_ticket uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'status', s.status,
    'invoice_id', s.invoice_id,
    'invoice_number', s.invoice_number,
    'invoice_total', s.invoice_total::text,
    'credit_total', case when s.invoice_id is null then null else s.credit_total::text end,
    'invoice_net', case when s.invoice_id is null then null else s.invoice_net::text end,
    'received_total', s.received_total::text,
    'refunded_total', s.refunded_total::text,
    'correction_net', s.correction_net::text,
    'net_received', s.net_received::text,
    'outstanding', s.outstanding::text,
    'refund_due', s.refund_due::text)
  from private.srv_payment_state(p_ticket) s
$$;

-- Saldo receipt pelanggan yang masih dapat direfund: amount - refund teralokasi - pembalikan metode.
create or replace function private.srv_receipt_balances(p_ticket uuid)
returns table(payment_id uuid, occurred_at timestamptz, method text, balance numeric)
language sql stable security definer set search_path = '' as $$
  select p.id, p.occurred_at, p.method,
    p.amount
      - coalesce((select sum(ra.amount) from private.refund_allocations ra where ra.original_payment_id = p.id), 0)
      - coalesce((select sum(r.amount) from private.payments r
          where r.original_payment_id = p.id and r.purpose = 'PAYMENT_REVERSAL'), 0)
  from private.payments p
  where p.service_ticket_id = p_ticket and p.direction = 'IN'
    and p.purpose in ('SERVICE_RECEIPT', 'PAYMENT_REPLACEMENT')
$$;

-- Modal proporsional eksak BR-05/BR-08: round_half_up(cost * part / total, 6), penuh saat part=total.
create or replace function private.srv_prop_cost(p_cost numeric, p_part numeric, p_total numeric)
returns numeric language plpgsql immutable set search_path = '' as $$
declare v_n numeric; v_d numeric;
begin
  if p_part >= p_total then return p_cost; end if;
  if p_part <= 0 or p_cost <= 0 then return 0; end if;
  v_n := round(p_cost * 1000000) * round(p_part * 1000);
  v_d := round(p_total * 1000);
  return round((div(v_n, v_d) + case when 2 * mod(v_n, v_d) >= v_d then 1 else 0 end) / 1000000.0, 6);
end $$;

-- Qty bersih sebuah event USE (dikurangi seluruh REVERSE).
create or replace function private.srv_use_net_qty(p_use_event uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select e.qty_base - coalesce((select sum(r.qty_base) from private.service_part_events r
    where r.reverses_event_id = e.id and r.kind = 'REVERSE'), 0)
  from private.service_part_events e where e.id = p_use_event
$$;

do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname like 'srv\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
