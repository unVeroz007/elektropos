import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Badge, Card, EmptyState, ErrorMessage, Loading, Notice, PageHeader, SummaryRow } from '../../components/ui'
import { SERVICE_STATUS_LABEL, CUSTODY_LABEL, labelOf } from '../../components/labels'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { useOnlineStatus } from '../../lib/online'
import { readRpc } from '../../lib/rpc'
import { permissions, useProfile } from '../../lib/session'
import type { Dashboard } from './types'

const REFRESH_MS = 60_000

function MoneyTile({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="stat-tile">
      <span className="stat-label">{label}</span>
      <strong className="stat-value">{formatRupiah(value)}</strong>
      {hint && <span className="muted">{hint}</span>}
    </div>
  )
}

/** Beranda (FR-RPT-01): ringkasan hari ini dari data nyata, status kas, servis, stok rendah, backup. */
export function DashboardPage() {
  const profile = useProfile()
  const online = useOnlineStatus()
  const dashboard = useQuery({
    queryKey: ['reports', 'dashboard'],
    queryFn: () => readRpc<Dashboard>('get_dashboard_v1', {}),
    refetchInterval: REFRESH_MS,
  })

  if (dashboard.isPending) return <Loading label="Memuat beranda…" />
  if (dashboard.isError) {
    return (
      <section>
        <PageHeader title="Beranda" />
        <ErrorMessage error={dashboard.error} />
        <button type="button" className="ui-button ui-button-secondary" onClick={() => { void dashboard.refetch() }}>Coba lagi</button>
      </section>
    )
  }
  const d = dashboard.data
  const today = d.today
  const { service } = d

  return (
    <section>
      <PageHeader title="Beranda"
        description={`Hari ini ${d.server_date} (WIB) · diperbarui ${formatDateTime(d.refreshed_at)}${online ? '' : ' · koneksi terputus'}`}
        actions={<button type="button" className="ui-button ui-button-secondary" disabled={dashboard.isFetching}
          onClick={() => { void dashboard.refetch() }}>{dashboard.isFetching ? 'Memperbarui…' : 'Perbarui'}</button>} />

      {d.backup.stale && permissions.viewHealth(profile) && (
        <Notice tone="warning">
          Backup terakhir {d.backup.last_success_at ? formatDateTime(d.backup.last_success_at) : 'belum pernah berhasil'}.
          {' '}<Link to="/kesehatan">Periksa backup</Link>.
        </Notice>
      )}

      <div className="stat-grid">
        <MoneyTile label="Penjualan barang (neto)" value={today.sales.net} hint={`${today.sales.invoice_count} nota`} />
        <MoneyTile label="Tagihan servis (neto)" value={today.service.net} hint={`${today.service.invoice_count} tagihan`} />
        <MoneyTile label="Uang masuk dari pelanggan" value={today.customer_receipts.total}
          hint={`Tunai ${formatRupiah(today.customer_receipts.by_method.CASH)} · Transfer ${formatRupiah(today.customer_receipts.by_method.TRANSFER)} · QRIS ${formatRupiah(today.customer_receipts.by_method.QRIS)}`} />
        <MoneyTile label="Uang dikembalikan" value={today.customer_refunds.total} />
      </div>

      <Card title="Kas">
        {d.cash_sessions.map(s => (
          <SummaryRow key={s.cashbox}
            label={<>{s.label} <Badge tone={s.open ? 'success' : 'neutral'}>{s.open ? 'Dibuka' : 'Ditutup'}</Badge></>}
            value={s.open
              ? `${s.opened_by ?? ''}${s.expected_amount ? ` · saldo ${formatRupiah(s.expected_amount)}` : ''}`
              : <Link to="/kas">Buka kas</Link>} />
        ))}
      </Card>

      <Card title={`Servis berjalan (${service.active_total})`} actions={<Link to="/servis">Lihat semua</Link>}>
        {Object.keys(service.active_by_status).length === 0 ? <EmptyState>Tidak ada servis berjalan.</EmptyState> : (
          <div className="button-row">
            {Object.entries(service.active_by_status).map(([status, n]) => (
              <Badge key={status} tone="info">{labelOf(SERVICE_STATUS_LABEL, status)}: {n}</Badge>
            ))}
          </div>
        )}
        {service.not_picked_up_count > 0 && (
          <>
            <h3>Belum diambil pelanggan ({service.not_picked_up_count})</h3>
            <ul className="plain-list">
              {service.not_picked_up.map(t => (
                <li key={t.ticket_id}>
                  <Link to={`/servis/${t.ticket_id}`}>{t.number}</Link> · {t.equipment_type} · {t.customer_name ?? '-'}
                  {' '}· {labelOf(CUSTODY_LABEL, t.custody_location)}
                </li>
              ))}
            </ul>
          </>
        )}
        {service.receivable_count > 0 && (
          <>
            <h3>Piutang servis ({service.receivable_count}) · {formatRupiah(service.receivable_total)}</h3>
            <ul className="plain-list">
              {service.receivables.map(t => (
                <li key={t.ticket_id}>
                  <Link to={`/servis/${t.ticket_id}`}>{t.number}</Link> · {t.customer_name ?? '-'}
                  {' '}· sisa {formatRupiah(t.outstanding)}{t.note ? ` · ${t.note}` : ''}
                </li>
              ))}
            </ul>
          </>
        )}
        {service.scheduled_today.length > 0 && (
          <>
            <h3>Kunjungan hari ini</h3>
            <ul className="plain-list">
              {service.scheduled_today.map(t => (
                <li key={t.ticket_id}>
                  {t.scheduled_at && formatDateTime(t.scheduled_at)} · <Link to={`/servis/${t.ticket_id}`}>{t.number}</Link>
                  {' '}· {t.customer_name ?? '-'}{t.address ? ` · ${t.address}` : ''}
                </li>
              ))}
            </ul>
          </>
        )}
      </Card>

      <Card title={`Stok menipis (${d.low_stock})`} actions={<Link to="/stok">Lihat stok</Link>}>
        {d.low_stock_items.length === 0 ? <EmptyState>Tidak ada barang di bawah batas minimum.</EmptyState> : (
          <ul className="plain-list">
            {d.low_stock_items.map(i => (
              <li key={i.product_id}>
                <Link to={`/katalog/${i.product_id}`}>{i.name}</Link>: {formatQuantity(i.stock_shop, i.base_unit)}
                {' '}(minimum {formatQuantity(i.min_stock, i.base_unit)})
              </li>
            ))}
          </ul>
        )}
      </Card>
    </section>
  )
}
