import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import Decimal from 'decimal.js'
import { Card, ErrorMessage, Loading, Notice, PageHeader, SummaryRow } from '../../components/ui'
import { DateRangeFields, monthStartInShop, rangeError, type DateRangeValue } from '../../components/DateRange'
import { downloadText } from '../../components/download'
import { formatRupiah, todayInShop } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'
import { hasRole, useProfile } from '../../lib/session'
import { collectCsv, type CsvPage } from './csvExport'
import type { ByMethod, Report } from './types'

function MethodRows({ values }: { values: ByMethod }) {
  return (
    <>
      <SummaryRow label="· Tunai" value={formatRupiah(values.CASH)} />
      <SummaryRow label="· Transfer" value={formatRupiah(values.TRANSFER)} />
      <SummaryRow label="· QRIS" value={formatRupiah(values.QRIS)} />
    </>
  )
}

function ExportButton({ range, dataset, label }: { range: DateRangeValue; dataset: 'invoices' | 'products'; label: string }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const [done, setDone] = useState<number | null>(null)

  async function run() {
    setBusy(true); setError(null); setDone(null)
    try {
      const { text, rows } = await collectCsv(cursor => readRpc<CsvPage>('export_csv_v1', {
        dataset, start_date: range.start, end_date: range.end, limit: 1000, ...(cursor ? { cursor } : {}),
      }))
      downloadText(`elektropos-${dataset === 'invoices' ? 'nota' : 'barang'}-${range.start}-sd-${range.end}.csv`, text)
      setDone(rows)
    } catch (err) {
      setError(err)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <button type="button" className="ui-button ui-button-secondary" disabled={busy} onClick={() => { void run() }}>
        {busy ? 'Menyiapkan berkas…' : label}
      </button>
      {done !== null && <p className="muted">{done} baris diunduh. Waktu dalam WIB. Berkas ini bukan pengganti backup.</p>}
      <ErrorMessage error={error} />
    </div>
  )
}

/** Laporan operasional periode (FR-RPT-02, BR-13). Karyawan tidak menerima data modal (D2). */
export function ReportPage() {
  const profile = useProfile()
  const [range, setRange] = useState<DateRangeValue>({ start: monthStartInShop(), end: todayInShop() })
  const invalid = rangeError(range)
  const report = useQuery({
    queryKey: ['reports', 'period', range.start, range.end],
    queryFn: () => readRpc<Report>('get_report_v1', { start_date: range.start, end_date: range.end }),
    enabled: invalid === null,
  })
  const r = report.data

  return (
    <section>
      <PageHeader title="Laporan" description="Semua angka dihitung sistem menurut tanggal toko (WIB)." />
      <div className="ui-card">
        <DateRangeFields value={range} onChange={setRange} />
      </div>
      {report.isLoading && <Loading label="Menghitung laporan…" />}
      <ErrorMessage error={report.error} />
      {r && (
        <>
          <Card title="Penjualan & servis">
            <SummaryRow label={`Penjualan barang (${r.sales.invoice_count} nota)`} value={formatRupiah(r.sales.invoice_total)} />
            <SummaryRow label={`Dikurangi retur barang (${r.sales.credit_count})`} value={`−${formatRupiah(r.sales.credit_total)}`} tone="danger" />
            <SummaryRow strong label="Penjualan barang bersih" value={formatRupiah(r.sales.net)} />
            <SummaryRow label={`Tagihan servis (${r.service.invoice_count})`} value={formatRupiah(r.service.invoice_total)} />
            <SummaryRow label={`Dikurangi koreksi tagihan servis (${r.service.credit_count})`} value={`−${formatRupiah(r.service.credit_total)}`} tone="danger" />
            <SummaryRow strong label="Tagihan servis bersih" value={formatRupiah(r.service.net)} />
            <p className="muted">Retur dicatat pada tanggal retur, bukan tanggal nota asal; periode bisa bernilai minus.</p>
          </Card>

          <Card title="Uang dari pelanggan">
            <SummaryRow label="Uang masuk" value={formatRupiah(r.customer_receipts.total)} />
            <MethodRows values={r.customer_receipts.by_method} />
            <SummaryRow label="Termasuk uang muka servis (DP)" value={formatRupiah(r.customer_receipts.deposit_total)} />
            <SummaryRow label="Uang dikembalikan ke pelanggan" value={`−${formatRupiah(r.customer_refunds.total)}`} tone="danger" />
            <SummaryRow strong label="Uang masuk bersih" value={formatRupiah(r.net_customer_receipts)} />
            {!new Decimal(r.payment_corrections.reversal_total).isZero() && (
              <p className="muted">
                Koreksi cara bayar: {formatRupiah(r.payment_corrections.reversal_total)} dipindah antar cara bayar
                (total tetap). Rincian bersih per cara bayar: tunai {formatRupiah(r.net_by_method.CASH)}, transfer
                {' '}{formatRupiah(r.net_by_method.TRANSFER)}, QRIS {formatRupiah(r.net_by_method.QRIS)}.
              </p>
            )}
            <p className="muted">Uang masuk bukan omzet dan bukan isi laci: transfer/QRIS tidak masuk laci.</p>
          </Card>

          {r.cost && r.gross_profit && r.stock_losses && (
            <Card title="Modal & laba kotor (khusus pemilik)">
              <SummaryRow label="Modal barang terjual (HPP) bersih" value={formatRupiah(r.cost.sale_cogs_net)} />
              <SummaryRow label="Modal part servis bersih" value={formatRupiah(r.cost.service_cogs_net)} />
              <SummaryRow strong label="Laba kotor" value={formatRupiah(r.gross_profit.total)} />
              <Notice tone="info">Laba kotor = penjualan & servis bersih dikurangi modal. Belum dikurangi gaji, listrik, sewa, pajak, dan kerugian stok.</Notice>
              <SummaryRow label="Kerugian barang dibuang" value={formatRupiah(r.stock_losses.disposal_cost)} tone="danger" />
              <SummaryRow label="Koreksi stok kurang" value={formatRupiah(r.stock_losses.adjustment_out_cost)} tone="danger" />
              <SummaryRow label="Koreksi stok tambah" value={formatRupiah(r.stock_losses.adjustment_in_cost)} />
              {r.supplier_returns && (
                <>
                  <SummaryRow label={`Retur ke distributor (${r.supplier_returns.count})`} value={formatRupiah(r.supplier_returns.claim_value)} />
                  <SummaryRow label="Selisih penyelesaian retur distributor" value={formatRupiah(r.supplier_returns.settlement_difference)}
                    tone={r.supplier_returns.settlement_difference.startsWith('-') ? 'danger' : 'success'} />
                  <SummaryRow label="Klaim distributor belum selesai" value={formatRupiah(r.supplier_returns.pending_claim_value)} />
                </>
              )}
            </Card>
          )}
        </>
      )}

      {invalid === null && (
        <Card title="Unduh data (CSV)">
          <div className="button-row">
            <ExportButton range={range} dataset="invoices" label="Unduh daftar nota" />
            {hasRole(profile, 'OWNER', 'MAINTAINER') && <ExportButton range={range} dataset="products" label="Unduh daftar barang" />}
          </div>
        </Card>
      )}
    </section>
  )
}
