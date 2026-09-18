import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Badge, Checkbox, EmptyState, ErrorMessage, Loading, PageHeader, Select, SummaryRow } from '../../components/ui'
import { DateRangeFields, monthStartInShop, rangeError, type DateRangeValue } from '../../components/DateRange'
import { CASHBOX_LABEL, labelOf } from '../../components/labels'
import { formatDateTime, formatRupiah, todayInShop } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'
import { permissions, useProfile } from '../../lib/session'
import { cashKeys, type CashboxCode, type CashSessionRecord } from './api'
import { ReviewForm } from './CashPage'

const PAGE_SIZE = 50

function SessionItem({ session, canReview }: { session: CashSessionRecord; canReview: boolean }) {
  const [reviewing, setReviewing] = useState(false)
  return (
    <li className="list-card">
      <span className="list-card-title">
        {labelOf(CASHBOX_LABEL, session.cashbox_code)} · {session.business_date}
      </span>
      <span>
        <Badge tone={session.status === 'OPEN' ? 'success' : 'neutral'}>{session.status === 'OPEN' ? 'Masih dibuka' : 'Ditutup'}</Badge>{' '}
        {session.review_pending && <Badge tone="warning">Perlu ditinjau</Badge>}
        {session.reviewed_at && <Badge tone="info">Sudah ditinjau</Badge>}
      </span>
      <SummaryRow label={`Buka ${formatDateTime(session.opened_at)}${session.opened_by_name ? ` · ${session.opened_by_name}` : ''}`}
        value={formatRupiah(session.opening_amount)} />
      {session.opening_variance && session.opening_variance !== '0' && (
        <SummaryRow label="Selisih saat buka" value={formatRupiah(session.opening_variance)} tone="danger" />
      )}
      <SummaryRow label="Saldo sistem" value={formatRupiah(session.expected)} />
      {session.counted_amount !== null && (
        <>
          <SummaryRow label={`Dihitung saat tutup ${formatDateTime(session.closed_at)}${session.closed_by_name ? ` · ${session.closed_by_name}` : ''}`}
            value={formatRupiah(session.counted_amount)} />
          <SummaryRow strong label="Selisih tutup" value={formatRupiah(session.variance ?? '0')}
            tone={session.variance && session.variance !== '0' ? 'danger' : 'success'} />
        </>
      )}
      {(session.opening_note || session.close_note || session.review_note) && (
        <span className="muted">
          {[session.opening_note && `Buka: ${session.opening_note}`, session.close_note && `Tutup: ${session.close_note}`,
            session.review_note && `Tinjauan: ${session.review_note}`].filter(Boolean).join(' · ')}
        </span>
      )}
      {canReview && session.review_pending && (reviewing
        ? <ReviewForm sessionId={session.id} version={session.version} onDone={() => setReviewing(false)} />
        : <span className="button-row">
            <button type="button" className="ui-button ui-button-secondary" onClick={() => setReviewing(true)}>Tinjau selisih</button>
          </span>)}
    </li>
  )
}

/** Riwayat sesi kas per tanggal usaha, termasuk selisih buka/tutup untuk ditinjau pemilik. */
export function CashHistoryPage() {
  const profile = useProfile()
  const [range, setRange] = useState<DateRangeValue>({ start: monthStartInShop(), end: todayInShop() })
  const [cashbox, setCashbox] = useState<'' | CashboxCode>('')
  const [onlyPending, setOnlyPending] = useState(false)
  const [page, setPage] = useState(0)
  const invalid = rangeError(range)
  const filter = {
    start_date: range.start, end_date: range.end,
    ...(cashbox ? { cashbox_code: cashbox } : {}),
    ...(onlyPending ? { review_pending: true } : {}),
    limit: String(PAGE_SIZE), offset: String(page * PAGE_SIZE),
  }
  const sessions = useQuery({
    queryKey: cashKeys.history(filter),
    queryFn: () => readRpc<{ total: number; items: CashSessionRecord[] }>('list_cash_sessions_v1', filter),
    enabled: invalid === null,
  })
  const items = sessions.data?.items ?? []
  const total = sessions.data?.total ?? 0
  const resetPage = <T,>(set: (value: T) => void) => (value: T) => { set(value); setPage(0) }

  return (
    <section>
      <PageHeader title="Riwayat kas" description="Sesi kas per hari usaha. Selisih ditandai untuk ditinjau pemilik." />
      <div className="ui-card">
        <DateRangeFields value={range} onChange={resetPage(setRange)} />
        <div className="form-grid">
          <Select label="Kas" value={cashbox} onChange={resetPage(setCashbox)} options={[
            { value: '', label: 'Semua kas' },
            { value: 'SHOP_DRAWER', label: CASHBOX_LABEL.SHOP_DRAWER },
            { value: 'FATHER_WALLET', label: CASHBOX_LABEL.FATHER_WALLET },
          ]} />
          <Checkbox label="Hanya yang perlu ditinjau" checked={onlyPending} onChange={resetPage(setOnlyPending)} />
        </div>
      </div>
      {sessions.isLoading && <Loading label="Memuat riwayat kas…" />}
      <ErrorMessage error={sessions.error} />
      {sessions.data && items.length === 0 && <EmptyState>Tidak ada sesi kas pada rentang ini.</EmptyState>}
      <ul className="card-list">
        {items.map(s => <SessionItem key={s.id} session={s} canReview={permissions.manageCash(profile)} />)}
      </ul>
      {total > PAGE_SIZE && (
        <nav className="button-row" aria-label="Halaman riwayat kas">
          <button type="button" className="ui-button ui-button-secondary" disabled={page === 0} onClick={() => setPage(p => p - 1)}>Sebelumnya</button>
          <span>Halaman {page + 1} dari {Math.ceil(total / PAGE_SIZE)}</span>
          <button type="button" className="ui-button ui-button-secondary" disabled={(page + 1) * PAGE_SIZE >= total}
            onClick={() => setPage(p => p + 1)}>Berikutnya</button>
        </nav>
      )}
    </section>
  )
}
