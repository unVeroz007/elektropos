import { useState, type FormEvent } from 'react'
import { ErrorMessage, TextArea, TextInput } from '../../../components/ui'
import { permissions, type Profile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, CommandError } from '../common'
import { isTerminal } from '../labels'
import type { CommandResult, TicketDetail } from '../types'

type EditableField =
  | 'equipment_type' | 'equipment_brand' | 'equipment_model' | 'equipment_serial'
  | 'complaint' | 'initial_condition' | 'accessories' | 'address'

type Values = Record<EditableField, string>

const REQUIRED: EditableField[] = ['equipment_type', 'complaint']

/**
 * Data alat & keluhan boleh dikoreksi sebelum tiket selesai. STAFF hanya saat
 * tiket masih baru (kontrak server); kontak pelanggan diubah di menu Pelanggan.
 */
export function canEditDetails(ticket: TicketDetail, profile: Profile): boolean {
  if (ticket.closed_at || isTerminal(ticket.work_status)) return false
  if (permissions.manageService(profile)) return true
  return permissions.receiveService(profile) && ticket.work_status === 'NEW'
}

function initialValues(ticket: TicketDetail): Values {
  return {
    equipment_type: ticket.equipment_type,
    equipment_brand: ticket.equipment_brand ?? '',
    equipment_model: ticket.equipment_model ?? '',
    equipment_serial: ticket.equipment_serial ?? '',
    complaint: ticket.complaint,
    initial_condition: ticket.initial_condition ?? '',
    accessories: ticket.accessories ?? '',
    address: ticket.address ?? '',
  }
}

/** Hanya kolom yang benar-benar berubah yang dikirim ke server. */
export function changedFields(before: Values, after: Values, onsite: boolean): Partial<Values> {
  const changes: Partial<Values> = {}
  for (const key of Object.keys(after) as EditableField[]) {
    if (key === 'address' && !onsite) continue
    const value = after[key].trim()
    if (value !== before[key].trim()) changes[key] = value
  }
  return changes
}

export function DetailsForm({ ticket }: { ticket: TicketDetail }) {
  const onsite = ticket.service_location === 'ONSITE'
  const [values, setValues] = useState<Values>(() => initialValues(ticket))
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('update_service_details_v1')

  const changes = changedFields(initialValues(ticket), values, onsite)
  const missing = REQUIRED.filter(key => values[key].trim() === '')
  const error = missing.length > 0 ? 'Jenis alat dan keluhan wajib diisi.'
    : Object.keys(changes).length === 0 ? 'Belum ada data yang diubah.' : null

  const set = (key: EditableField) => (value: string) => setValues(v => ({ ...v, [key]: value }))

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const payload: Record<string, unknown> = { ticket_id: ticket.id, expected_version: ticket.version, ...changes }
    if (reason.trim()) payload.reason = reason.trim()
    if (await command.run(payload)) { setReason(''); setTouched(false) }
  }

  return (
    <form onSubmit={submit} noValidate>
      <TextInput label="Jenis alat" value={values.equipment_type} onChange={set('equipment_type')} required maxLength={120} />
      <TextInput label="Merek (opsional)" value={values.equipment_brand} onChange={set('equipment_brand')} maxLength={120} />
      <TextInput label="Model (opsional)" value={values.equipment_model} onChange={set('equipment_model')} maxLength={120} />
      <TextInput label="Nomor seri (opsional)" value={values.equipment_serial} onChange={set('equipment_serial')} maxLength={120} />
      <TextArea label="Keluhan" value={values.complaint} onChange={set('complaint')} required rows={3} maxLength={2000} />
      <TextArea label="Kondisi awal" value={values.initial_condition} onChange={set('initial_condition')} rows={2} maxLength={1000} />
      <TextArea label="Kelengkapan" value={values.accessories} onChange={set('accessories')} rows={2} maxLength={1000} />
      {onsite && <TextArea label="Alamat kunjungan" value={values.address} onChange={set('address')} rows={2} maxLength={1000} />}
      <TextInput label="Alasan perubahan (opsional)" value={reason} onChange={setReason} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan perubahan'}</Button>
    </form>
  )
}
