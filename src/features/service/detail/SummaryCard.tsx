import { Link } from 'react-router-dom'
import { Card, SummaryRow } from '../../../components/ui'
import { formatDateTime } from '../../../lib/numbers'
import { CUSTODY, LOCATION, statusLabel } from '../labels'
import { telHref } from '../logic'
import type { TicketDetail } from '../types'

/** Ringkasan pelanggan & alat. Kontak tidak dikirim server untuk akun teknis. */
export function SummaryCard({ ticket }: { ticket: TicketDetail }) {
  const c = ticket.customer
  const equipment = [ticket.equipment_type, ticket.equipment_brand, ticket.equipment_model].filter(Boolean).join(' · ')
  const mapLink = ticket.address?.match(/https?:\/\/\S+/)?.[0] ?? null
  return (
    <Card title="Pelanggan & alat">
      <div className="srv-summary-grid">
        <div>
          <SummaryRow label="Pelanggan" value={c?.name ?? '-'} />
          {c?.phone && <SummaryRow label="HP" value={<a href={telHref(c.phone)}>{c.phone}</a>} />}
          {c?.alternate_contact && <SummaryRow label="Kontak lain" value={c.alternate_contact} />}
          {ticket.address && <SummaryRow label="Alamat" value={<span className="srv-prewrap">{ticket.address}</span>} />}
          {mapLink && <SummaryRow label="Peta" value={<a href={mapLink} target="_blank" rel="noreferrer">Buka peta</a>} />}
          <SummaryRow label="Lokasi servis" value={LOCATION[ticket.service_location]} />
          {ticket.scheduled_at && <SummaryRow label="Jadwal kunjungan" value={formatDateTime(ticket.scheduled_at)} />}
          <SummaryRow label="Alat sekarang" value={CUSTODY[ticket.custody_location]} />
        </div>
        <div>
          <SummaryRow label="Alat" value={equipment} />
          {ticket.equipment_serial && <SummaryRow label="Nomor seri" value={ticket.equipment_serial} />}
          <SummaryRow label="Keluhan" value={<span className="srv-prewrap">{ticket.complaint}</span>} />
          {ticket.initial_condition && <SummaryRow label="Kondisi awal" value={ticket.initial_condition} />}
          {ticket.accessories && <SummaryRow label="Kelengkapan" value={ticket.accessories} />}
          {ticket.test_result && <SummaryRow label="Hasil uji" value={ticket.test_result} />}
          {ticket.terminal_reason && <SummaryRow label="Alasan" value={ticket.terminal_reason} />}
          <SummaryRow label="Diterima" value={formatDateTime(ticket.created_at)} />
          {ticket.mechanic_name && <SummaryRow label="Mekanik" value={ticket.mechanic_name} />}
        </div>
      </div>
      {ticket.parent_ticket && (
        <p>Keluhan kembali dari <Link to={`/servis/${ticket.parent_ticket.id}`}>{ticket.parent_ticket.number}</Link>
          {' '}({statusLabel(ticket.parent_ticket.work_status)})</p>
      )}
      {ticket.child_tickets.length > 0 && (
        <p>Keluhan kembali: {ticket.child_tickets.map((child, i) => (
          <span key={child.id}>{i > 0 && ', '}<Link to={`/servis/${child.id}`}>{child.number}</Link></span>
        ))}</p>
      )}
    </Card>
  )
}
