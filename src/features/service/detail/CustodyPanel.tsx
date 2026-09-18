import { useState, type FormEvent } from 'react'
import { Card, ChoiceGroup, ConfirmDialog, ErrorMessage, Notice, TextArea, TextInput } from '../../../components/ui'
import { formatDateTime } from '../../../lib/numbers'
import { permissions, useProfile, type Profile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, Collapsible, CommandError } from '../common'
import { CUSTODY } from '../labels'
import { closeOnsiteBlockers, handoverBlockers, isoToShopLocal, shopLocalToIso } from '../logic'
import type { CommandResult, Custody, TicketDetail } from '../types'

type Target = Exclude<Custody, 'CUSTOMER'>

/** Tujuan pindah alat yang boleh untuk peran ini (server tetap memeriksa). */
export function custodyTargets(ticket: TicketDetail, profile: Profile): Target[] {
  if (ticket.closed_at) return []
  if (permissions.manageService(profile)) {
    return (['SHOP', 'FATHER'] as Target[]).filter(t => t !== ticket.custody_location)
  }
  if (permissions.receiveService(profile) && ticket.custody_location === 'CUSTOMER' && ticket.work_status === 'NEW') {
    return ['SHOP']
  }
  return []
}

const TARGET_LABEL: Record<Target, string> = { SHOP: 'Taruh di toko', FATHER: 'Dibawa ayah' }

/** Keberadaan alat, pindah tangan, serah terima & tutup kunjungan (BR-11). */
export function CustodyPanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const targets = custodyTargets(ticket, profile)
  const holdsDevice = ticket.custody_location !== 'CUSTOMER'
  const canHandover = permissions.receiveService(profile) && holdsDevice && !ticket.closed_at
  const canCloseOnsite = permissions.manageService(profile) && ticket.service_location === 'ONSITE'
    && !holdsDevice && !ticket.closed_at
  const canReschedule = permissions.manageService(profile) && ticket.service_location === 'ONSITE' && !ticket.closed_at

  return (
    <Card title="Keberadaan alat">
      <p className="srv-lead">Sekarang: <strong>{CUSTODY[ticket.custody_location]}</strong></p>
      {ticket.closed_at && <Notice tone="success">Servis ditutup {formatDateTime(ticket.closed_at)}.</Notice>}
      {canHandover && <HandoverForm ticket={ticket} />}
      {canCloseOnsite && <CloseOnsiteForm ticket={ticket} />}
      {targets.length > 0 && (
        <Collapsible title="Pindahkan alat (mis. dibawa ayah pulang ke toko)">
          <TransferForm ticket={ticket} targets={targets} />
        </Collapsible>
      )}
      {canReschedule && (
        <Collapsible title="Ubah jadwal kunjungan">
          <ScheduleForm ticket={ticket} />
        </Collapsible>
      )}
    </Card>
  )
}

function TransferForm({ ticket, targets }: { ticket: TicketDetail; targets: Target[] }) {
  const [to, setTo] = useState<Target>(targets[0])
  const [condition, setCondition] = useState('')
  const [accessories, setAccessories] = useState('')
  const [reason, setReason] = useState('')
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('transfer_service_custody_v1')
  async function submit(event: FormEvent) {
    event.preventDefault()
    const payload: Record<string, unknown> = { ticket_id: ticket.id, expected_version: ticket.version, to_location: to }
    if (condition.trim()) payload.condition_note = condition.trim()
    if (accessories.trim()) payload.accessories_note = accessories.trim()
    if (reason.trim()) payload.reason = reason.trim()
    if (await command.run(payload)) { setCondition(''); setAccessories(''); setReason('') }
  }
  return (
    <form onSubmit={submit} noValidate>
      <ChoiceGroup label="Pindahkan ke" value={to} onChange={setTo}
        options={targets.map(value => ({ value, label: TARGET_LABEL[value] }))} />
      <TextArea label="Kondisi alat saat dipindah (opsional)" value={condition} onChange={setCondition} rows={2} maxLength={1000} />
      <TextArea label="Kelengkapan (opsional)" value={accessories} onChange={setAccessories} rows={2} maxLength={1000} />
      <TextInput label="Catatan (opsional)" value={reason} onChange={setReason} maxLength={500} />
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan perpindahan'}</Button>
    </form>
  )
}

function Blockers({ reasons, action }: { reasons: string[]; action: string }) {
  return (
    <Notice tone="warning">
      <p className="srv-notice-title">{action} belum bisa karena:</p>
      <ul>{reasons.map(r => <li key={r}>{r}</li>)}</ul>
    </Notice>
  )
}

function HandoverForm({ ticket }: { ticket: TicketDetail }) {
  const blockers = handoverBlockers(ticket)
  const [receiver, setReceiver] = useState('')
  const [condition, setCondition] = useState('')
  const [accessories, setAccessories] = useState(ticket.accessories ?? '')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('handover_service_v1')
  const error = receiver.trim().length < 2 ? 'Tulis nama orang yang mengambil alat.' : null

  function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (!error) setConfirming(true)
  }
  async function confirm() {
    const payload: Record<string, unknown> = { ticket_id: ticket.id, expected_version: ticket.version, receiver_name: receiver.trim() }
    if (condition.trim()) payload.condition_note = condition.trim()
    if (accessories.trim()) payload.accessories_note = accessories.trim()
    await command.run(payload)
    setConfirming(false)
  }

  if (blockers.length > 0) return <Blockers reasons={blockers} action="Serah terima alat" />
  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <p className="srv-subform-title">Serahkan alat ke pelanggan</p>
      <TextInput label="Nama penerima" value={receiver} onChange={setReceiver} required maxLength={120}
        placeholder={ticket.customer?.name ?? ''} />
      <TextArea label="Kondisi saat diserahkan (opsional)" value={condition} onChange={setCondition} rows={2} maxLength={1000} />
      <TextArea label="Kelengkapan yang dikembalikan" value={accessories} onChange={setAccessories} rows={2} maxLength={1000} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" large disabled={command.busy}>Serahkan alat</Button>
      <ConfirmDialog open={confirming} title="Serahkan alat?" confirmLabel="Ya, sudah diserahkan" busy={command.busy}
        onConfirm={() => void confirm()} onCancel={() => setConfirming(false)}>
        <p>Alat {ticket.number} diserahkan kepada <strong>{receiver.trim()}</strong>. Tiket akan ditutup.</p>
      </ConfirmDialog>
    </form>
  )
}

function CloseOnsiteForm({ ticket }: { ticket: TicketDetail }) {
  const blockers = closeOnsiteBlockers(ticket)
  const [note, setNote] = useState('')
  const [confirming, setConfirming] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('close_onsite_service_v1')
  async function confirm() {
    const payload: Record<string, unknown> = { ticket_id: ticket.id, expected_version: ticket.version }
    if (note.trim()) payload.completion_note = note.trim()
    await command.run(payload)
    setConfirming(false)
  }
  if (blockers.length > 0) return <Blockers reasons={blockers} action="Tutup kunjungan" />
  return (
    <form className="srv-subform" onSubmit={event => { event.preventDefault(); setConfirming(true) }} noValidate>
      <p className="srv-subform-title">Tutup kunjungan (alat tetap di rumah pelanggan)</p>
      <TextArea label="Catatan penyelesaian (opsional)" value={note} onChange={setNote} rows={2} maxLength={1000} />
      <CommandError error={command.error} />
      <Button type="submit" large disabled={command.busy}>Tutup kunjungan</Button>
      <ConfirmDialog open={confirming} title="Tutup kunjungan?" confirmLabel="Ya, tutup" busy={command.busy}
        onConfirm={() => void confirm()} onCancel={() => setConfirming(false)}>
        <p>Tiket {ticket.number} akan ditutup dan tidak bisa diubah lagi.</p>
      </ConfirmDialog>
    </form>
  )
}

function ScheduleForm({ ticket }: { ticket: TicketDetail }) {
  const [when, setWhen] = useState(() => isoToShopLocal(ticket.scheduled_at))
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('update_service_schedule_v1')
  const iso = shopLocalToIso(when)
  const error = !iso ? 'Pilih tanggal dan jam kunjungan.' : reason.trim().length < 3 ? 'Tulis alasan jadwal diubah.' : null
  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error || !iso) return
    if (await command.run({ ticket_id: ticket.id, expected_version: ticket.version, scheduled_at: iso, reason: reason.trim() })) {
      setReason(''); setTouched(false)
    }
  }
  return (
    <form onSubmit={submit} noValidate>
      <TextInput type="datetime-local" label="Jadwal baru (jam toko)" value={when} onChange={setWhen} required />
      <TextInput label="Alasan" value={reason} onChange={setReason} required maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>Simpan jadwal</Button>
    </form>
  )
}
