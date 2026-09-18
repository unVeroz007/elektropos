import { Link, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Badge, ErrorMessage, Loading, Notice, PageHeader } from '../../../components/ui'
import { permissions, useProfile } from '../../../lib/session'
import { getTicket, serviceKeys } from '../api'
import { Button, PaymentBadge, StatusBadge } from '../common'
import { isTerminal } from '../labels'
import { nextStep } from '../logic'
import { CustodyPanel } from './CustodyPanel'
import { EstimatePanel } from './EstimatePanel'
import { InvoicePanel } from './InvoicePanel'
import { PartsPanel } from './PartsPanel'
import { PaymentPanel } from './PaymentPanel'
import { StatusPanel } from './StatusPanel'
import { SummaryCard } from './SummaryCard'
import { TicketPhotos } from './TicketPhotos'
import { Timeline } from './Timeline'

/** Halaman detail tiket `/servis/:ticketId` dengan langkah sesuai status dan peran. */
export function TicketDetailPage({ ticketId }: { ticketId: string }) {
  const profile = useProfile()
  const [params] = useSearchParams()
  const query = useQuery({ queryKey: serviceKeys.ticket(ticketId), queryFn: () => getTicket(ticketId) })

  if (query.isPending) return <Loading label="Memuat tiket…" />
  if (query.isError) {
    return (
      <section className="srv-page">
        <Link className="ui-button ui-button-secondary" to="/servis">← Daftar servis</Link>
        <ErrorMessage error={query.error} />
        <Button variant="secondary" onClick={() => void query.refetch()}>Coba muat lagi</Button>
      </section>
    )
  }
  const ticket = query.data
  const readOnly = !permissions.receiveService(profile)

  return (
    <section className="srv-page srv-detail">
      <PageHeader
        title={`Servis ${ticket.number}`}
        description={[ticket.equipment_type, ticket.customer?.name].filter(Boolean).join(' · ')}
        actions={<Link className="ui-button ui-button-secondary" to="/servis">← Daftar servis</Link>}
      />
      <div className="srv-badges">
        <StatusBadge status={ticket.work_status} location={ticket.service_location} />
        <PaymentBadge status={ticket.payment.status} />
        {ticket.not_picked_up && <Badge tone="warning">Belum diambil</Badge>}
        {ticket.closed_at && <Badge tone="neutral">Sudah ditutup</Badge>}
      </div>
      <Notice tone="info"><strong>Langkah berikutnya:</strong> {nextStep(ticket)}</Notice>
      {readOnly && <Notice tone="warning">Akun ini hanya dapat melihat tiket.</Notice>}
      {query.isRefetching && <p className="srv-muted" role="status">Memperbarui…</p>}

      <SummaryCard ticket={ticket} />
      <StatusPanel ticket={ticket} />
      <EstimatePanel ticket={ticket} />
      <PartsPanel ticket={ticket} />
      <InvoicePanel ticket={ticket} />
      <PaymentPanel ticket={ticket} />
      <CustodyPanel ticket={ticket} />
      <TicketPhotos ticketId={ticket.id} canUpload={!readOnly && !ticket.closed_at} highlight={params.get('foto') === '1'} />
      <Timeline ticket={ticket} />
      {!readOnly && (ticket.closed_at || isTerminal(ticket.work_status)) && (
        <Link className="ui-button ui-button-secondary" to={`/servis/baru?asal=${ticket.id}`}>
          Keluhan kembali (buat tiket baru tertaut)
        </Link>
      )}
    </section>
  )
}
