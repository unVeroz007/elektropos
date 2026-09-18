import { useParams } from 'react-router-dom'
import { TicketDetailPage } from './detail/TicketDetailPage'
import { IntakeForm } from './IntakeForm'
import { TicketList } from './TicketList'
import './service.css'

/**
 * Rute servis: `/servis` (daftar), `/servis/baru` (penerimaan; `?asal=` untuk
 * keluhan kembali) dan `/servis/:ticketId` (detail).
 */
export function ServicePage() {
  const { ticketId } = useParams()
  if (!ticketId) return <TicketList />
  if (ticketId === 'baru') return <IntakeForm />
  return <TicketDetailPage key={ticketId} ticketId={ticketId} />
}
