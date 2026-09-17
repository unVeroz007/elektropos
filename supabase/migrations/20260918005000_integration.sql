-- Integrasi hasil perbaikan paralel.
-- 1. Laporan biaya memuat retur distributor (dokumen dari domain kas/pembelian).
-- 2. Seluruh fungsi schema private tidak dapat dieksekusi PUBLIC/anon/authenticated
--    secara langsung; akses hanya lewat RPC public (SECURITY DEFINER).

create or replace function private.ops_cost_summary(p_start timestamptz, p_end timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_sale_alloc numeric; v_sale_rev numeric; v_srv_rec numeric; v_srv_rev numeric;
  v_sale_net numeric; v_srv_net numeric; v_rev_sale numeric; v_rev_srv numeric;
  v_disposal numeric; v_adj_in numeric; v_adj_out numeric; v_gross numeric;
  v_sr_claim numeric; v_sr_pending numeric; v_sr_diff numeric; v_sr_count integer;
begin
  select coalesce(sum(ca.cost_amount), 0) into v_sale_alloc
    from private.cost_allocations ca
    join private.invoice_items ii on ii.id = ca.invoice_item_id
    join private.invoices i on i.id = ii.invoice_id
    where i.kind = 'SALE' and i.posted_at >= p_start and i.posted_at < p_end;
  select coalesce(sum(cni.cost_reversal_amount) filter (where i.kind = 'SALE'), 0),
         coalesce(sum(cni.cost_reversal_amount) filter (where i.kind = 'SERVICE'), 0)
    into v_sale_rev, v_srv_rev
    from private.credit_note_items cni
    join private.credit_notes cn on cn.id = cni.credit_note_id
    join private.invoices i on i.id = cn.invoice_id
    where cn.posted_at >= p_start and cn.posted_at < p_end;
  select coalesce(sum(r.cost_amount), 0) into v_srv_rec
    from private.service_cost_recognitions r join private.invoices i on i.id = r.invoice_id
    where i.kind = 'SERVICE' and i.posted_at >= p_start and i.posted_at < p_end;

  select coalesce(sum(i.total) filter (where i.kind = 'SALE'), 0), coalesce(sum(i.total) filter (where i.kind = 'SERVICE'), 0)
    into v_rev_sale, v_rev_srv
    from private.invoices i where i.posted_at >= p_start and i.posted_at < p_end;
  select v_rev_sale - coalesce(sum(cn.total) filter (where i.kind = 'SALE'), 0),
         v_rev_srv - coalesce(sum(cn.total) filter (where i.kind = 'SERVICE'), 0)
    into v_rev_sale, v_rev_srv
    from private.credit_notes cn join private.invoices i on i.id = cn.invoice_id
    where cn.posted_at >= p_start and cn.posted_at < p_end;

  select coalesce(-sum(cost_delta) filter (where kind = 'DISPOSAL'), 0),
         coalesce(sum(cost_delta) filter (where kind in ('ADJUST_IN', 'COUNT_IN')), 0),
         coalesce(-sum(cost_delta) filter (where kind in ('ADJUST_OUT', 'COUNT_OUT')), 0)
    into v_disposal, v_adj_in, v_adj_out
    from private.stock_movements where occurred_at >= p_start and occurred_at < p_end
      and kind in ('DISPOSAL', 'ADJUST_IN', 'COUNT_IN', 'ADJUST_OUT', 'COUNT_OUT');

  -- Retur distributor: modal keluar saat dokumen dibuat (klaim), selisih diakui saat diselesaikan.
  select coalesce(sum(claim_value) filter (where created_at >= p_start and created_at < p_end), 0),
         count(*) filter (where created_at >= p_start and created_at < p_end),
         coalesce(sum(settlement_difference) filter (where settled_at >= p_start and settled_at < p_end), 0)
    into v_sr_claim, v_sr_count, v_sr_diff
    from private.supplier_returns;
  select coalesce(sum(claim_value), 0) into v_sr_pending
    from private.supplier_returns where status = 'PENDING' and created_at < p_end;

  v_sale_net := v_sale_alloc - v_sale_rev;
  v_srv_net := v_srv_rec - v_srv_rev;
  v_gross := (v_rev_sale + v_rev_srv) - (v_sale_net + v_srv_net);
  -- Nilai modal dihitung 6 desimal lalu dibulatkan pada agregat (BR-05).
  return jsonb_build_object(
    'cost', jsonb_build_object(
      'sale_cogs_allocated', private.ops_money(v_sale_alloc),
      'sale_cogs_reversed', private.ops_money(v_sale_rev),
      'sale_cogs_net', private.ops_money(v_sale_net),
      'service_cogs_recognized', private.ops_money(v_srv_rec),
      'service_cogs_reversed', private.ops_money(v_srv_rev),
      'service_cogs_net', private.ops_money(v_srv_net),
      'cogs_net', private.ops_money(v_sale_net + v_srv_net),
      'rounding', 'Dihitung 6 desimal, dibulatkan ke Rupiah pada total'),
    'gross_profit', jsonb_build_object(
      'sale', private.ops_money(v_rev_sale - v_sale_net),
      'service', private.ops_money(v_rev_srv - v_srv_net),
      'total', private.ops_money(v_gross),
      'note', 'Laba kotor = penjualan neto + servis neto - COGS neto. BUKAN laba bersih: belum dikurangi biaya operasional, kerugian disposal/koreksi stok, gaji, pajak.'),
    'stock_losses', jsonb_build_object(
      'disposal_cost', private.ops_money(v_disposal),
      'adjustment_out_cost', private.ops_money(v_adj_out),
      'adjustment_in_cost', private.ops_money(v_adj_in),
      'note', 'Kerugian disposal dan koreksi stok dicatat terpisah, tidak masuk laba kotor.'),
    'supplier_returns', jsonb_build_object(
      'count', v_sr_count,
      'claim_value', private.ops_money(v_sr_claim),
      'settlement_difference', private.ops_money(v_sr_diff),
      'pending_claim_value', private.ops_money(v_sr_pending),
      'note', 'Retur ke distributor: nilai klaim keluar dari persediaan; selisih penyelesaian (negatif = rugi) tidak masuk laba kotor.'),
    'cogs', private.ops_money(v_sale_net + v_srv_net));
end $$;
revoke all on function private.ops_cost_summary(timestamptz, timestamptz) from public, anon, authenticated;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.signature);
  end loop;
end $$;
