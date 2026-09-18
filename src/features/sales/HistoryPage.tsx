import { useState } from 'react'
import { Link } from 'react-router-dom'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Badge, Card, EmptyState, ErrorMessage, Loading, PageHeader, TextInput } from '../../components/ui'
import { formatDateTime, formatRupiah, todayInShop } from '../../lib/numbers'
import { listInvoices } from './api'
import { useDebounced } from '../../components/useDebounced'
import { paymentLabel, paymentStatus } from './labels'
import type { InvoiceListItem } from './types'
import './sales.css'

export const HISTORY_PAGE_SIZE = 25

/** Riwayat nota (FR-POS-03). Default hari ini menurut jam toko (WIB). */
export function HistoryPage() {
  const [startDate, setStartDate] = useState(() => todayInShop())
  const [endDate, setEndDate] = useState(() => todayInShop())
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(0)
  const search = useDebounced(query, 300)
  const datesValid = startDate !== '' && endDate !== '' && startDate <= endDate

  const invoices = useQuery({
    queryKey: ['sales', 'invoices', startDate, endDate, search.trim(), page],
    queryFn: () => listInvoices({
      startDate, endDate, query: search, limit: HISTORY_PAGE_SIZE, offset: page * HISTORY_PAGE_SIZE,
    }),
    enabled: datesValid,
    placeholderData: keepPreviousData,
  })

  const setFilter = (apply: () => void) => {
    apply()
    setPage(0)
  }
  const rows = invoices.data ?? []
  const hasNext = rows.length === HISTORY_PAGE_SIZE

  return (
    <div className="sl-page">
      <PageHeader title="Riwayat nota" description="Nota penjualan dan servis. Pilih nota untuk melihat struk." />
      <Card>
        <div className="sl-filters">
          <TextInput type="date" label="Dari tanggal" value={startDate}
            onChange={v => setFilter(() => setStartDate(v))} />
          <TextInput type="date" label="Sampai tanggal" value={endDate}
            onChange={v => setFilter(() => setEndDate(v))} />
          <TextInput type="search" label="Cari nomor nota" value={query} maxLength={60}
            onChange={v => setFilter(() => setQuery(v))} placeholder="Contoh: 000123" />
        </div>
        <div className="sl-row-actions">
          <button type="button" className="ui-button ui-button-secondary"
            onClick={() => setFilter(() => { setStartDate(todayInShop()); setEndDate(todayInShop()) })}>
            Hari ini
          </button>
          <button type="button" className="ui-button ui-button-secondary"
            onClick={() => setFilter(() => { setStartDate(todayInShop(-6)); setEndDate(todayInShop()) })}>
            7 hari terakhir
          </button>
        </div>
        {!datesValid && <ErrorMessage error="Tanggal awal harus sebelum atau sama dengan tanggal akhir." />}
      </Card>

      {invoices.isPending && datesValid && <Loading label="Memuat riwayat…" />}
      <ErrorMessage error={invoices.error} />
      {invoices.isSuccess && rows.length === 0 && (
        <EmptyState>{page > 0 ? 'Tidak ada nota lagi.' : 'Belum ada nota pada tanggal ini.'}</EmptyState>
      )}
      {rows.length > 0 && (
        <ul className="sl-history" aria-label="Daftar nota">
          {rows.map(row => <HistoryRow key={row.id} row={row} />)}
        </ul>
      )}

      {(page > 0 || hasNext) && (
        <nav className="sl-pager" aria-label="Halaman riwayat">
          <button type="button" className="ui-button ui-button-secondary" disabled={page === 0 || invoices.isFetching}
            onClick={() => setPage(p => Math.max(0, p - 1))}>Sebelumnya</button>
          <span>Halaman {page + 1}</span>
          <button type="button" className="ui-button ui-button-secondary" disabled={!hasNext || invoices.isFetching}
            onClick={() => setPage(p => p + 1)}>Berikutnya</button>
        </nav>
      )}
    </div>
  )
}

function HistoryRow({ row }: { row: InvoiceListItem }) {
  const status = paymentStatus(row.payment_status)
  const methods = (row.payment_methods ?? []).map(paymentLabel).join(', ')
  return (
    <li>
      <Link className="sl-history-row" to={`/struk/${row.id}`}>
        <span className="sl-history-main">
          <strong>{row.number}</strong>
          <span>{formatDateTime(row.posted_at)}</span>
          <span>
            {row.kind === 'SALE' ? 'Penjualan' : 'Servis'}
            {row.cashier_name ? ` · Petugas ${row.cashier_name}` : ''}
            {row.customer_name ? ` · ${row.customer_name}` : ''}
          </span>
        </span>
        <span className="sl-history-side">
          <strong className="sl-history-total">{formatRupiah(row.total)}</strong>
          <Badge tone={status.tone}>{status.label}</Badge>
          {methods && <small>{methods}</small>}
          {row.has_return && <Badge tone="info">Ada retur</Badge>}
        </span>
      </Link>
    </li>
  )
}
