-- P2 helper: nomor dokumen invoice, credit note, payment

create or replace function private.next_invoice_number(p_kind text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_date date; v_number integer;
begin
  v_date := (now() at time zone 'Asia/Jakarta')::date;
  insert into private.document_sequences(kind, business_date, last_number)
  values (p_kind || '_INV', v_date, 1)
  on conflict (kind, business_date) do update
    set last_number = private.document_sequences.last_number + 1
  returning last_number into v_number;
  return p_kind || '-INV-' || to_char(v_date, 'YYYYMMDD') || '-' || lpad(v_number::text, 6, '0');
end $$;
revoke all on function private.next_invoice_number(text) from public,anon,authenticated;

create or replace function private.next_credit_number()
returns text language plpgsql security definer set search_path = '' as $$
declare v_date date; v_number integer;
begin
  v_date := (now() at time zone 'Asia/Jakarta')::date;
  insert into private.document_sequences(kind, business_date, last_number)
  values ('CREDIT', v_date, 1)
  on conflict (kind, business_date) do update
    set last_number = private.document_sequences.last_number + 1
  returning last_number into v_number;
  return 'CRD-' || to_char(v_date, 'YYYYMMDD') || '-' || lpad(v_number::text, 6, '0');
end $$;
revoke all on function private.next_credit_number() from public,anon,authenticated;