import { useState, type FormEvent } from 'react'
import Decimal from 'decimal.js'
import { Card, ChoiceGroup, EmptyState, ErrorMessage, Notice, RupiahInput, SummaryRow, TextArea } from '../../../components/ui'
import { formatDateTime, formatRupiah, rupiahOrNull } from '../../../lib/numbers'
import { permissions, useProfile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, Collapsible, CommandError } from '../common'
import { APPROVAL_METHOD, ESTIMATE_STATUS } from '../labels'
import { partChargeEstimate } from '../logic'
import type { ApprovalMethod, CommandResult, Estimate, TicketDetail } from '../types'

/** Estimasi & persetujuan biaya (BR-09). Estimasi bukan tagihan. */
export function EstimatePanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const owner = permissions.manageService(profile)
  const editable = owner && !ticket.invoice && !ticket.completed_at
  const latest = ticket.estimates.at(-1) ?? null
  const { approved_limit: limit, approved_revision: revision } = ticket.approval
  const partCharges = partChargeEstimate(ticket.part_events)

  return (
    <Card title="Biaya & persetujuan pelanggan">
      {limit !== null && revision !== null ? (
        <SummaryRow strong label={`Batas disetujui (revisi ${revision})`} value={formatRupiah(limit)} />
      ) : (
        <Notice tone="info">Belum ada persetujuan biaya. Pekerjaan berbayar baru boleh dimulai setelah pelanggan setuju.</Notice>
      )}
      {limit !== null && partCharges.greaterThan(limit) && (
        <Notice tone="warning">
          Harga part yang sudah dipakai ({formatRupiah(partCharges)}) sudah melebihi batas disetujui.
          Catat estimasi baru dan minta persetujuan lagi sebelum menagih.
        </Notice>
      )}

      {ticket.estimates.length === 0
        ? <EmptyState>Belum ada estimasi biaya.</EmptyState>
        : (
          <ol className="srv-estimate-list">
            {[...ticket.estimates].reverse().map(e => <EstimateRow key={e.id} estimate={e} />)}
          </ol>
        )}

      {editable && latest?.status === 'PROPOSED' && <ApproveForm key={latest.id} estimate={latest} />}
      {editable && (
        <Collapsible title={ticket.estimates.length ? 'Revisi estimasi (biaya berubah)' : 'Catat estimasi biaya'}
          defaultOpen={ticket.estimates.length === 0 && ticket.work_status === 'INSPECTING'}>
          <EstimateForm ticket={ticket} />
        </Collapsible>
      )}
    </Card>
  )
}

function range(e: Estimate): string {
  return e.min_amount && e.min_amount !== e.max_amount
    ? `${formatRupiah(e.min_amount)} – ${formatRupiah(e.max_amount)}`
    : formatRupiah(e.max_amount)
}

function EstimateRow({ estimate: e }: { estimate: Estimate }) {
  return (
    <li className={`srv-estimate${e.status === 'SUPERSEDED' ? ' is-old' : ''}`}>
      <div className="srv-estimate-head">
        <strong>Revisi {e.revision}: {range(e)}</strong>
        <span>{ESTIMATE_STATUS[e.status] ?? 'Status lain'}</span>
      </div>
      <p>{e.description}</p>
      {e.approved_limit && (
        <p className="srv-muted">
          Disetujui maks. {formatRupiah(e.approved_limit)}
          {e.approved_method && ` · ${APPROVAL_METHOD[e.approved_method]}`}
          {e.approved_at && ` · ${formatDateTime(e.approved_at)}`}
          {e.approved_by_name && ` · dicatat ${e.approved_by_name}`}
          {e.consent_note && ` · ${e.consent_note}`}
        </p>
      )}
    </li>
  )
}

function EstimateForm({ ticket }: { ticket: TicketDetail }) {
  const [description, setDescription] = useState('')
  const [min, setMin] = useState('')
  const [max, setMax] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('record_estimate_v1')

  const maxValue = rupiahOrNull(max)
  const minValue = min.trim() ? rupiahOrNull(min) : null
  let error: string | null = null
  if (!description.trim()) error = 'Tulis pekerjaan/part yang diperkirakan.'
  else if (!maxValue) error = 'Isi perkiraan biaya maksimal.'
  else if (min.trim() && !minValue) error = 'Perkiraan minimal tidak sah.'
  else if (minValue && new Decimal(minValue).greaterThan(maxValue)) error = 'Perkiraan minimal tidak boleh lebih besar dari maksimal.'

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error || !maxValue) return
    const payload: Record<string, unknown> = {
      ticket_id: ticket.id, expected_version: ticket.version, description: description.trim(), max_amount: maxValue,
    }
    if (minValue) payload.min_amount = minValue
    if (await command.run(payload)) { setDescription(''); setMin(''); setMax(''); setTouched(false) }
  }

  return (
    <form onSubmit={submit} noValidate>
      <TextArea label="Uraian pekerjaan & part" value={description} onChange={setDescription} required maxLength={1000}
        hint="Contoh: ganti kapasitor & bersihkan papan. Estimasi belum menjadi tagihan." />
      <div className="srv-grid-2">
        <RupiahInput label="Perkiraan minimal (opsional)" value={min} onChange={setMin} />
        <RupiahInput label="Perkiraan maksimal" value={max} onChange={setMax} required />
      </div>
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan estimasi'}</Button>
    </form>
  )
}

function ApproveForm({ estimate }: { estimate: Estimate }) {
  const [agreed, setAgreed] = useState(() => new Decimal(estimate.max_amount).toFixed(0))
  const [method, setMethod] = useState<ApprovalMethod>('IN_PERSON')
  const [note, setNote] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('approve_estimate_v1')

  const agreedValue = rupiahOrNull(agreed)
  let error: string | null = null
  if (!agreedValue) error = 'Isi batas biaya yang disetujui pelanggan.'
  else if (new Decimal(agreedValue).greaterThan(estimate.max_amount)) {
    error = `Batas tidak boleh melebihi estimasi maksimal ${formatRupiah(estimate.max_amount)}. Catat revisi estimasi bila biaya naik.`
  } else if (method === 'OTHER' && !note.trim()) error = 'Tulis cara pelanggan menyetujui.'

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error || !agreedValue) return
    const payload: Record<string, unknown> = {
      estimate_id: estimate.id, expected_version: estimate.version, agreed_limit: agreedValue, method,
    }
    if (note.trim()) payload.consent_note = note.trim()
    await command.run(payload)
  }

  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <p className="srv-subform-title">Catat persetujuan pelanggan untuk revisi {estimate.revision}</p>
      <RupiahInput label="Batas biaya yang disetujui" value={agreed} onChange={setAgreed} required
        hint={`Maksimal ${formatRupiah(estimate.max_amount)}. Tagihan final tidak boleh melebihi batas ini.`} />
      <ChoiceGroup label="Cara pelanggan menyetujui" value={method} onChange={setMethod}
        options={(Object.keys(APPROVAL_METHOD) as ApprovalMethod[]).map(value => ({ value, label: APPROVAL_METHOD[value] }))} />
      <TextArea label={method === 'OTHER' ? 'Catatan persetujuan' : 'Catatan (opsional)'} value={note} onChange={setNote}
        rows={2} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan persetujuan'}</Button>
    </form>
  )
}
