import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useInfiniteQuery } from '@tanstack/react-query'
import { Badge, EmptyState, ErrorMessage, Loading, PageHeader, Select, TextInput } from '../../components/ui'
import { formatDateTime, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { listTickets, serviceKeys, type TicketFilters } from './api'
import { Button, PaymentBadge, StatusBadge } from './common'
import { CUSTODY, LOCATION } from './labels'
import { isPositive } from './logic'
import type { ServiceLocation, TicketListItem } from './types'
import { useDebounced } from '../../components/useDebounced'

type FilterKey = 'active' | 'new' | 'approval' | 'working' | 'ready' | 'not_picked' | 'all'

const FILTERS: { value: FilterKey; label: string; filters: TicketFilters }[] = [
  { value: 'active', label: 'Semua yang masih berjalan', filters: {} },
  { value: 'new', label: 'Baru diterima & diperiksa', filters: { status: ['NEW', 'INSPECTING'] } },
  { value: 'approval', label: 'Menunggu persetujuan biaya', filters: { status: ['AWAITING_APPROVAL'] } },
  { value: 'working', label: 'Dikerjakan / menunggu part', filters: { status: ['WORKING', 'WAITING_PARTS'] } },
  { value: 'ready', label: 'Siap diambil / selesai dikerjakan', filters: { status: ['READY'] } },
  { value: 'not_picked', label: 'Belum diambil pelanggan', filters: { not_picked_up: true } },
  { value: 'all', label: 'Semua, termasuk yang sudah ditutup', filters: { include_closed: true } },
]

const LOCATIONS: { value: '' | ServiceLocation; label: string }[] = [
  { value: '', label: 'Toko & kunjungan' },
  { value: 'STORE', label: 'Servis di toko' },
  { value: 'ONSITE', label: 'Kunjungan rumah' },
]

export function TicketList() {
  const profile = useProfile()
  const [filter, setFilter] = useState<FilterKey>('active')
  const [location, setLocation] = useState<'' | ServiceLocation>('')
  const [query, setQuery] = useState('')
  const debouncedQuery = useDebounced(query)

  const filters: TicketFilters = {
    ...FILTERS.find(f => f.value === filter)?.filters,
    query: debouncedQuery,
    ...(location ? { service_location: location } : {}),
  }

  const tickets = useInfiniteQuery({
    queryKey: serviceKeys.list(filters),
    queryFn: ({ pageParam }) => listTickets(filters, pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: last => last.next_cursor,
  })
  const items = tickets.data?.pages.flatMap(p => p.items) ?? []

  return (
    <section className="srv-page">
      <PageHeader
        title="Servis"
        description="Alat titipan dan kunjungan rumah. Pilih tiket untuk melihat langkah berikutnya."
        actions={permissions.receiveService(profile)
          ? <Link className="ui-button ui-button-primary" to="/servis/baru">+ Terima servis baru</Link>
          : undefined}
      />

      <div className="srv-filters">
        <TextInput type="search" label="Cari nomor tiket, nama, atau HP" value={query} onChange={setQuery}
          placeholder="Contoh: SRV-0012, Budi, 0812…" maxLength={120} />
        <Select label="Tampilkan" value={filter} onChange={setFilter} options={FILTERS} />
        <Select label="Lokasi" value={location} onChange={setLocation} options={LOCATIONS} />
      </div>

      {tickets.isPending && <Loading label="Memuat tiket servis…" />}
      {tickets.isError && (
        <>
          <ErrorMessage error={tickets.error} />
          <Button variant="secondary" onClick={() => void tickets.refetch()}>Coba muat lagi</Button>
        </>
      )}
      {tickets.isSuccess && items.length === 0 && (
        <EmptyState>
          {debouncedQuery.trim() || filter !== 'active' || location
            ? 'Tidak ada tiket yang cocok dengan pencarian/pilihan ini.'
            : 'Belum ada tiket servis yang berjalan.'}
        </EmptyState>
      )}

      <ul className="srv-ticket-list">
        {items.map(ticket => <li key={ticket.id}><TicketCard ticket={ticket} /></li>)}
      </ul>

      {tickets.hasNextPage && (
        <Button variant="secondary" large disabled={tickets.isFetchingNextPage} onClick={() => void tickets.fetchNextPage()}>
          {tickets.isFetchingNextPage ? 'Memuat…' : 'Muat lagi'}
        </Button>
      )}
    </section>
  )
}

function TicketCard({ ticket }: { ticket: TicketListItem }) {
  const equipment = [ticket.equipment_type, ticket.equipment_brand, ticket.equipment_model].filter(Boolean).join(' · ')
  return (
    <Link className="srv-ticket-card" to={`/servis/${ticket.id}`}>
      <div className="srv-ticket-top">
        <strong>{ticket.number}</strong>
        <StatusBadge status={ticket.work_status} location={ticket.service_location} />
        {ticket.not_picked_up && <Badge tone="warning">Belum diambil</Badge>}
        {ticket.closed_at && <Badge tone="neutral">Sudah ditutup</Badge>}
      </div>
      <div className="srv-ticket-main">
        <span className="srv-ticket-customer">{ticket.customer_name ?? 'Pelanggan'}</span>
        <span>{equipment}</span>
        <span className="srv-muted">{ticket.complaint}</span>
      </div>
      <div className="srv-ticket-meta">
        <span>{LOCATION[ticket.service_location]}</span>
        <span>{CUSTODY[ticket.custody_location]}</span>
        {ticket.service_location === 'ONSITE' && ticket.scheduled_at && !ticket.closed_at && (
          <span>Jadwal: {formatDateTime(ticket.scheduled_at)}</span>
        )}
        <span>Masuk: {formatDateTime(ticket.created_at)}</span>
      </div>
      <div className="srv-ticket-meta">
        <PaymentBadge status={ticket.payment_status} />
        {isPositive(ticket.outstanding) && <span>Sisa {formatRupiah(ticket.outstanding)}</span>}
        {isPositive(ticket.refund_due) && <span>Kembalikan {formatRupiah(ticket.refund_due)}</span>}
      </div>
    </Link>
  )
}
