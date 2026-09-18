import { useState, type FormEvent } from 'react'
import { Card, ErrorMessage, Notice, TextArea } from '../../../components/ui'
import { permissions, useProfile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, Collapsible, CommandError } from '../common'
import { TRANSITION_ACTION, isTerminal, statusLabel } from '../labels'
import { testResultError, transitionNeeds } from '../logic'
import type { CommandResult, TicketDetail, WorkStatus } from '../types'

const DANGER: WorkStatus[] = ['CANCELLED', 'UNREPAIRABLE']

/** Langkah status sesuai tabel WF-05 dari server (hanya pemilik). */
export function StatusPanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const [target, setTarget] = useState<WorkStatus | null>(null)
  if (!permissions.manageService(profile)) return null
  const canCorrect = isTerminal(ticket.work_status) && !ticket.invoice && !ticket.closed_at
  if (ticket.allowed_transitions.length === 0 && !canCorrect) return null

  return (
    <Card title="Ubah status pengerjaan">
      {ticket.allowed_transitions.length > 0 && (
        <div className="srv-actions" role="group" aria-label="Pilih status berikutnya">
          {ticket.allowed_transitions.map(status => (
            <Button key={status} variant={DANGER.includes(status) ? 'secondary' : 'primary'}
              onClick={() => setTarget(status)} disabled={target === status}>
              {status === 'READY' && ticket.service_location === 'STORE' ? 'Selesai, siap diambil' : TRANSITION_ACTION[status]}
            </Button>
          ))}
        </div>
      )}
      {target && (
        <TransitionForm key={target} ticket={ticket} target={target} onDone={() => setTarget(null)} />
      )}
      {canCorrect && <CorrectStatusForm ticket={ticket} />}
    </Card>
  )
}

function TransitionForm({ ticket, target, onDone }: { ticket: TicketDetail; target: WorkStatus; onDone: () => void }) {
  const needs = transitionNeeds(target)
  const [reason, setReason] = useState('')
  const [testResult, setTestResult] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('transition_service_v1')

  const blockedByApproval = needs.approval && !ticket.approval.active
  let error: string | null = null
  if (blockedByApproval) error = 'Belum ada persetujuan biaya terbaru dari pelanggan. Catat persetujuan di bagian Biaya.'
  else if (needs.testResult) error = testResultError(testResult)
  else if (needs.reason && reason.trim().length < 3) error = 'Tulis alasannya agar tercatat di riwayat.'

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const payload: Record<string, unknown> = { ticket_id: ticket.id, expected_version: ticket.version, target_status: target }
    if (needs.reason) payload.reason = reason.trim()
    if (needs.testResult) payload.test_result = testResult.trim()
    if (await command.run(payload)) onDone()
  }

  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <p className="srv-subform-title">Ubah ke: <strong>{statusLabel(target, ticket.service_location)}</strong></p>
      {blockedByApproval && <Notice tone="warning">{error}</Notice>}
      {needs.testResult && (
        <TextArea label="Hasil uji setelah diperbaiki" value={testResult} onChange={setTestResult} required
          hint='Contoh: "Dinyalakan 30 menit, suara dan gambar normal". Tidak boleh hanya "OK".' maxLength={1000} />
      )}
      {needs.reason && (
        <TextArea label={target === 'CANCELLED' ? 'Alasan dibatalkan' : target === 'UNREPAIRABLE' ? 'Alasan tidak bisa diperbaiki' : 'Alasan'}
          value={reason} onChange={setReason} required maxLength={500} />
      )}
      {touched && error && !blockedByApproval && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <div className="srv-actions">
        <Button type="submit" variant={DANGER.includes(target) ? 'danger' : 'primary'} disabled={command.busy || blockedByApproval}>
          {command.busy ? 'Menyimpan…' : `Simpan: ${statusLabel(target, ticket.service_location)}`}
        </Button>
        <Button variant="secondary" onClick={onDone}>Batal</Button>
      </div>
    </form>
  )
}

function CorrectStatusForm({ ticket }: { ticket: TicketDetail }) {
  const [reason, setReason] = useState('')
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('correct_service_status_v1')
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (reason.trim().length < 3) return
    await command.run({ ticket_id: ticket.id, expected_version: ticket.version, reason: reason.trim() })
  }
  return (
    <Collapsible title="Salah tekan status? Kembalikan ke status sebelumnya">
      <form onSubmit={submit} noValidate>
        <TextArea label="Alasan koreksi" value={reason} onChange={setReason} required maxLength={500} />
        <CommandError error={command.error} />
        <Button type="submit" variant="secondary" disabled={command.busy || reason.trim().length < 3}>
          {command.busy ? 'Menyimpan…' : 'Kembalikan status'}
        </Button>
      </form>
    </Collapsible>
  )
}
