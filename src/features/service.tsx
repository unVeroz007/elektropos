import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useQuery } from '@tanstack/react-query'
import { TicketPhotos } from './photos'

type Ticket = { id: string; number: string; equipment_type: string; complaint: string; work_status: string; service_location: string; custody_location: string; created_at: string }
type TicketDetail = Ticket & {
  version: number; customer_id: string;
  status_events: { from_status: string; to_status: string; reason: string; occurred_at: string }[];
  estimates: { id: string; revision: number; description: string; max_amount: string; status: string; approved_limit: string }[];
  part_events: { id: string; kind: string; qty_base: string; charge_unit_price: string }[];
  payments: { id: string; amount: string; method: string; occurred_at: string }[];
}

const STATUS_LABEL: Record<string, string> = {
  NEW: 'Baru', INSPECTING: 'Inspeksi', AWAITING_APPROVAL: 'Menunggu Persetujuan',
  WORKING: 'Dikerjakan', READY: 'Siap', DIAMBIL: 'Diambil',
  ONSITE_DONE: 'Selesai Onsite', UNREPAIRABLE: 'Tidak Diperbaiki', CANCELLED: 'Dibatalkan'
}

export function ServiceTickets() {
  const [showForm, setShowForm] = useState(false)
  const [selectedTicket, setSelectedTicket] = useState<TicketDetail | null>(null)

  const { data: tickets, refetch } = useQuery({
    queryKey: ['tickets'],
    queryFn: async () => {
      if (!supabase) return []
      const { data } = await supabase.rpc('list_service_tickets_v1', { p_input: {} })
      return (data as Ticket[]) ?? []
    }
  })

  async function loadTicket(id: string) {
    if (!supabase) return
    const { data } = await supabase.rpc('get_service_ticket_v1', { p_input: { ticket_id: id } })
    setSelectedTicket(data as TicketDetail)
  }

  return (
    <section>
      <div className="section-head">
        <div>
          <div className="eyebrow">SERVIS</div>
          <h2>Tiket Servis</h2>
          <p>Penerimaan, progres, estimasi, part, penyerahan.</p>
        </div>
        <button onClick={() => setShowForm(!showForm)}>
          {showForm ? 'Tutup' : '+ Tiket Baru'}
        </button>
      </div>

      {showForm && <ServiceTicketForm onDone={() => { setShowForm(false); refetch() }} />}

      <div className="ticket-list">
        {(tickets ?? []).map(t => (
          <article key={t.id} className="ticket-card" onClick={() => loadTicket(t.id)}>
            <div className="ticket-header">
              <strong>{t.number}</strong>
              <span className={`status-badge ${t.work_status.toLowerCase()}`}>
                {STATUS_LABEL[t.work_status] || t.work_status}
              </span>
            </div>
            <div>{t.equipment_type} — {t.complaint}</div>
            <div className="ticket-meta">
              <span>{t.service_location === 'ONSITE' ? 'Kunjungan' : 'Toko'}</span>
              <span>{new Date(t.created_at).toLocaleDateString('id-ID')}</span>
            </div>
          </article>
        ))}
        {(tickets ?? []).length === 0 && <div className="empty">Belum ada tiket servis aktif.</div>}
      </div>

      {selectedTicket && <TicketDetail ticket={selectedTicket} onClose={() => setSelectedTicket(null)} onRefresh={() => loadTicket(selectedTicket.id)} />}
    </section>
  )
}

function ServiceTicketForm({ onDone }: { onDone: () => void }) {
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!supabase) return
    setBusy(true); setError('')
    const fd = new FormData(e.currentTarget as HTMLFormElement)
    const input = Object.fromEntries(fd.entries())
    const { data, error: err } = await supabase.rpc('create_service_ticket_v1', {
      p_input: {
        operation_id: crypto.randomUUID(),
        customer_name: input.customer_name,
        customer_phone: input.customer_phone || undefined,
        equipment_type: input.equipment_type,
        equipment_brand: input.equipment_brand || undefined,
        complaint: input.complaint,
        service_location: input.service_location,
        address: input.address || undefined,
        scheduled_at: input.scheduled_at || undefined
      }
    })
    setBusy(false)
    if (err) setError(err.message)
    else { const res = data as { ok?: boolean }; if (res?.ok) onDone() }
  }

  return (
    <form onSubmit={submit} className="editor">
      <h3>Penerimaan Servis</h3>
      <label>Nama Pelanggan<input name="customer_name" required /></label>
      <label>No. HP<input name="customer_phone" /></label>
      <label>Jenis Alat<input name="equipment_type" required placeholder="TV, AC, dll" /></label>
      <label>Merek<input name="equipment_brand" /></label>
      <label>Keluhan<textarea name="complaint" required rows={3} /></label>
      <label>Lokasi Servis
        <select name="service_location"><option value="STORE">Di Toko</option><option value="ONSITE">Kunjungan Rumah</option></select>
      </label>
      <label>Alamat (jika kunjungan)<input name="address" /></label>
      <label>Jadwal<input name="scheduled_at" type="datetime-local" /></label>
      {error && <div className="error">{error}</div>}
      <button disabled={busy}>{busy ? 'Menyimpan…' : 'Simpan Tiket'}</button>
    </form>
  )
}

function TicketDetail({ ticket, onClose, onRefresh }: { ticket: TicketDetail; onClose: () => void; onRefresh: () => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function transition(target: string) {
    if (!supabase) return
    setBusy(true); setError('')
    const { data, error: err } = await supabase.rpc('transition_service_v1', {
      p_input: { operation_id: crypto.randomUUID(), ticket_id: ticket.id, expected_version: ticket.version, target_status: target, reason: 'Progress', test_result: target === 'READY' ? 'OK' : undefined }
    })
    setBusy(false)
    if (err) setError(err.message)
    else { const res = data as { ok?: boolean }; if (res?.ok) onRefresh() }
  }

  const transitions: Record<string, string[]> = {
    NEW: ['INSPECTING', 'CANCELLED'],
    INSPECTING: ['AWAITING_APPROVAL', 'UNREPAIRABLE', 'CANCELLED'],
    AWAITING_APPROVAL: ['WORKING', 'UNREPAIRABLE', 'CANCELLED'],
    WORKING: ['READY', 'UNREPAIRABLE', 'CANCELLED']
  }

  return (
    <div className="modal" onClick={onClose}>
      <div className="modal-content" onClick={e => e.stopPropagation()}>
        <div className="modal-header">
          <h3>{ticket.number} — {ticket.equipment_type}</h3>
          <button className="ghost" onClick={onClose}>✕</button>
        </div>
        <p>{ticket.complaint}</p>
        <div className="ticket-status-row">
          <span className={`status-badge ${ticket.work_status.toLowerCase()}`}>
            {STATUS_LABEL[ticket.work_status]}
          </span>
          <span>{ticket.service_location === 'ONSITE' ? 'Kunjungan' : 'Toko'}</span>
          <span>Custody: {ticket.custody_location}</span>
        </div>

        {transitions[ticket.work_status] && (
          <div className="transition-buttons">
            {transitions[ticket.work_status].map(s => (
              <button key={s} onClick={() => transition(s)} disabled={busy}
                className={s === 'CANCELLED' || s === 'UNREPAIRABLE' ? 'ghost' : 'primary'}>
                {STATUS_LABEL[s]}
              </button>
            ))}
          </div>
        )}
        {error && <div className="error">{error}</div>}

        {ticket.status_events?.length > 0 && (
          <div className="events-section">
            <h4>Riwayat Status</h4>
            {ticket.status_events.map((ev, i) => (
              <div key={i} className="event-row">
                <span>{ev.from_status || '—'} → {STATUS_LABEL[ev.to_status]}</span>
                <span>{ev.reason || '-'}</span>
                <span>{new Date(ev.occurred_at).toLocaleString('id-ID')}</span>
              </div>
            ))}
          </div>
        )}

        <TicketPhotos ticketId={ticket.id} />
      </div>
    </div>
  )
}
