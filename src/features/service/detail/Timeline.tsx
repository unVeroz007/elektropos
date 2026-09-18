import { Card } from '../../../components/ui'
import { formatDateTime } from '../../../lib/numbers'
import { CUSTODY, statusLabel } from '../labels'
import type { TicketDetail } from '../types'

type Entry = { key: string; at: string; title: string; detail: string | null; actor: string | null }

/** Riwayat status dan perpindahan alat, digabung urut waktu (terbaru di atas). */
export function timelineEntries(ticket: TicketDetail): Entry[] {
  const status: Entry[] = ticket.status_events.map((e, i) => ({
    key: `s${i}`,
    at: e.occurred_at,
    title: e.from_status
      ? `${statusLabel(e.from_status, ticket.service_location)} → ${statusLabel(e.to_status, ticket.service_location)}`
      : `Tiket dibuat: ${statusLabel(e.to_status, ticket.service_location)}`,
    detail: e.reason,
    actor: e.actor_name,
  }))
  const custody: Entry[] = ticket.custody_events.map((e, i) => ({
    key: `c${i}`,
    at: e.occurred_at,
    title: e.is_handover
      ? `Alat diserahkan ke ${e.receiver_name ?? 'pelanggan'}`
      : `Alat pindah: ${e.from_location ? CUSTODY[e.from_location] : '-'} → ${CUSTODY[e.to_location]}`,
    detail: [e.condition_note && `Kondisi: ${e.condition_note}`, e.accessories_note && `Kelengkapan: ${e.accessories_note}`]
      .filter(Boolean).join(' · ') || null,
    actor: e.actor_name,
  }))
  return [...status, ...custody].sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
}

export function Timeline({ ticket }: { ticket: TicketDetail }) {
  const entries = timelineEntries(ticket)
  if (entries.length === 0) return null
  return (
    <Card title="Riwayat">
      <ol className="srv-timeline">
        {entries.map(e => (
          <li key={e.key}>
            <strong>{e.title}</strong>
            {e.detail && <span>{e.detail}</span>}
            <span className="srv-muted">{formatDateTime(e.at)}{e.actor ? ` · ${e.actor}` : ''}</span>
          </li>
        ))}
      </ol>
    </Card>
  )
}
