import { useState, type FormEvent } from 'react'
import Decimal from 'decimal.js'
import {
  Card, ConfirmDialog, ErrorMessage, Notice, QuantityInput, RupiahInput, Select, SummaryRow, TextArea, TextInput,
} from '../../../components/ui'
import { formatDateTime, formatQuantity, formatRupiah, quantityOrNull, rupiahOrNull } from '../../../lib/numbers'
import { permissions, useProfile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, Collapsible, CommandError } from '../common'
import { CHARGE_KIND, isTerminal } from '../labels'
import { checkInvoice, draftInvoiceTotal, isPositive, netUsedParts } from '../logic'
import type { ChargeKind, CommandResult, Invoice, TicketDetail } from '../types'

type FreeKind = Exclude<ChargeKind, 'PART'>
type FreeLine = { key: number; kind: FreeKind; description: string; quantity: string; unitPrice: string }

const FREE_KINDS: { value: FreeKind; label: string }[] = [
  { value: 'LABOR', label: CHARGE_KIND.LABOR },
  { value: 'VISIT', label: CHARGE_KIND.VISIT },
  { value: 'DIAGNOSIS', label: CHARGE_KIND.DIAGNOSIS },
]

const wholeRupiah = (value: string | null) => new Decimal(value ?? '0').toDecimalPlaces(0, Decimal.ROUND_HALF_UP).toFixed(0)

/** Tagihan final servis (BR-09, WF-06). Hanya pemilik yang membuat/mengoreksi. */
export function InvoicePanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const owner = permissions.manageService(profile)
  if (ticket.invoice) return <InvoiceView ticket={ticket} invoice={ticket.invoice} canCredit={owner} />
  if (ticket.closed_at) return null
  if (!isTerminal(ticket.work_status)) {
    return (
      <Card title="Tagihan final">
        <Notice tone="info">Tagihan dibuat setelah pekerjaan selesai, tidak bisa diperbaiki, atau dibatalkan.</Notice>
      </Card>
    )
  }
  if (!owner) {
    return <Card title="Tagihan final"><Notice tone="info">Tagihan final belum dibuat pemilik.</Notice></Card>
  }
  return <FinalizeForm ticket={ticket} />
}

function FinalizeForm({ ticket }: { ticket: TicketDetail }) {
  const parts = netUsedParts(ticket.part_events)
  const failed = ticket.work_status !== 'READY'
  const [lines, setLines] = useState<FreeLine[]>(() => [{
    key: 1, kind: failed ? 'DIAGNOSIS' : 'LABOR',
    description: failed ? 'Biaya pemeriksaan' : 'Jasa perbaikan', quantity: '1', unitPrice: '',
  }])
  const [partPrices, setPartPrices] = useState<Record<string, string>>(
    () => Object.fromEntries(parts.map(p => [p.id, wholeRupiah(p.charge_unit_price)])))
  const [waiver, setWaiver] = useState('')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('finalize_service_invoice_v1')

  const { total, invalid } = draftInvoiceTotal([
    ...lines.map(l => ({ quantity: l.quantity, unitPrice: l.unitPrice })),
    ...parts.map(p => ({ quantity: p.net_qty ?? '0', unitPrice: partPrices[p.id] ?? '' })),
  ])
  const check = checkInvoice({
    total,
    approvedRevision: ticket.approval.approved_revision,
    approvedLimit: ticket.approval.approved_limit,
    status: ticket.work_status,
    waiverReason: waiver,
  })
  let error: string | null = null
  if (lines.some(l => !l.description.trim())) error = 'Setiap baris biaya wajib punya uraian.'
  else if (invalid > 0) error = 'Lengkapi jumlah dan harga setiap baris (tulis 0 bila tidak ditagih).'
  else if (!check.ok) error = check.message

  const update = (key: number, patch: Partial<FreeLine>) =>
    setLines(ls => ls.map(l => l.key === key ? { ...l, ...patch } : l))

  function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (!error) setConfirming(true)
  }

  async function confirm() {
    if (!check.ok) return
    const payload: Record<string, unknown> = {
      ticket_id: ticket.id,
      expected_version: ticket.version,
      charge_lines: [
        ...lines.map(l => ({
          kind: l.kind, description: l.description.trim(),
          quantity: quantityOrNull(l.quantity), unit_price: rupiahOrNull(l.unitPrice),
        })),
        ...parts.map(p => ({ kind: 'PART', service_part_event_id: p.id, unit_price: rupiahOrNull(partPrices[p.id] ?? '') })),
      ],
    }
    if (check.mode === 'APPROVED') payload.approved_estimate_revision = ticket.approval.approved_revision
    else payload.waiver_reason = waiver.trim()
    await command.run(payload)
    setConfirming(false)
  }

  const limit = ticket.approval.approved_limit
  const overLimit = limit !== null && total.greaterThan(limit)

  return (
    <Card title="Buat tagihan final">
      <form onSubmit={submit} noValidate>
        <p className="srv-muted">Setelah final, tagihan tidak bisa diubah; koreksi hanya lewat potongan tagihan.</p>
        <fieldset className="srv-fieldset">
          <legend>Biaya jasa / kunjungan / pemeriksaan</legend>
          {lines.map(line => (
            <div key={line.key} className="srv-charge-line">
              <Select label="Jenis biaya" value={line.kind} onChange={kind => update(line.key, { kind })} options={FREE_KINDS} />
              <TextInput label="Uraian" value={line.description} onChange={description => update(line.key, { description })} maxLength={200} />
              <div className="srv-grid-2">
                <QuantityInput label="Jumlah" value={line.quantity} onChange={quantity => update(line.key, { quantity })} />
                <RupiahInput label="Harga" value={line.unitPrice} onChange={unitPrice => update(line.key, { unitPrice })} />
              </div>
              <Button variant="secondary" onClick={() => setLines(ls => ls.filter(l => l.key !== line.key))}>Hapus baris ini</Button>
            </div>
          ))}
          <Button variant="secondary" onClick={() => setLines(ls => [...ls, {
            key: Math.max(0, ...ls.map(l => l.key)) + 1, kind: 'LABOR', description: '', quantity: '1', unitPrice: '',
          }])}>+ Tambah baris biaya</Button>
        </fieldset>

        {parts.length > 0 && (
          <fieldset className="srv-fieldset">
            <legend>Part terpakai (wajib dicantumkan, boleh Rp0)</legend>
            {parts.map(p => (
              <RupiahInput key={p.id} label={`${p.product_name} · ${formatQuantity(p.net_qty ?? '0', p.base_unit)} — harga per ${p.base_unit}`}
                value={partPrices[p.id] ?? ''} onChange={value => setPartPrices(prices => ({ ...prices, [p.id]: value }))} />
            ))}
          </fieldset>
        )}

        <SummaryRow strong label="Total tagihan" value={formatRupiah(total)} tone={overLimit ? 'danger' : undefined} />
        {limit !== null
          ? <SummaryRow label="Batas disetujui pelanggan" value={formatRupiah(limit)} />
          : <SummaryRow label="Batas disetujui pelanggan" value="Belum ada" />}
        {isPositive(ticket.payment.net_received) && (
          <SummaryRow label="Uang yang sudah diterima (data lama)" value={formatRupiah(ticket.payment.net_received)} />
        )}

        {limit === null && failed && total.isZero() && (
          <TextArea label="Alasan pembebasan biaya" value={waiver} onChange={setWaiver} required rows={2} maxLength={500}
            hint="Wajib bila tagihan Rp0 tanpa persetujuan biaya." />
        )}
        {(touched || overLimit) && error && <ErrorMessage error={error} />}
        <CommandError error={command.error} />
        <Button type="submit" large disabled={command.busy || overLimit}>Periksa & buat tagihan final</Button>
      </form>
      <ConfirmDialog open={confirming} title="Buat tagihan final?" confirmLabel="Ya, buat tagihan"
        busy={command.busy} onConfirm={() => void confirm()} onCancel={() => setConfirming(false)}>
        <p>Total tagihan <strong>{formatRupiah(total)}</strong>. Setelah final, tagihan tidak dapat diubah.</p>
      </ConfirmDialog>
    </Card>
  )
}

function InvoiceView({ ticket, invoice, canCredit }: { ticket: TicketDetail; invoice: Invoice; canCredit: boolean }) {
  return (
    <Card title={`Tagihan final ${invoice.number}`}>
      <p className="srv-muted">Dibuat {formatDateTime(invoice.posted_at)}</p>
      <ul className="srv-invoice-lines">
        {invoice.items.map(item => (
          <li key={item.id}>
            <span>
              {item.description}
              <small className="srv-muted"> {CHARGE_KIND[item.kind]} · {formatQuantity(item.quantity)} × {formatRupiah(item.unit_price)}</small>
              {isPositive(item.credited) && <small className="srv-muted"> · dipotong {formatRupiah(item.credited)}</small>}
            </span>
            <strong>{formatRupiah(item.net_total)}</strong>
          </li>
        ))}
      </ul>
      <SummaryRow label="Total tagihan" value={formatRupiah(invoice.total)} />
      {invoice.credit_notes.map(cn => (
        <SummaryRow key={cn.id} label={`Potongan ${cn.number}: ${cn.reason}`} value={`-${formatRupiah(cn.total)}`} />
      ))}
      <SummaryRow strong label="Tagihan bersih" value={formatRupiah(ticket.payment.invoice_net ?? invoice.total)} />
      {invoice.cost_recognized !== null && (
        <SummaryRow label="Modal part (hanya pemilik)" value={formatRupiah(invoice.cost_recognized)} />
      )}
      {canCredit && isPositive(ticket.payment.invoice_net) && (
        <Collapsible title="Potong tagihan (koreksi harga)">
          <CreditForm ticket={ticket} invoice={invoice} />
        </Collapsible>
      )}
    </Card>
  )
}

function CreditForm({ ticket, invoice }: { ticket: TicketDetail; invoice: Invoice }) {
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('credit_service_invoice_v1')

  const lines: { invoice_item_id: string; amount: string }[] = []
  let error: string | null = null
  let total = new Decimal(0)
  for (const item of invoice.items) {
    const raw = amounts[item.id]?.trim() ?? ''
    if (!raw) continue
    const amount = rupiahOrNull(raw)
    const remaining = new Decimal(item.net_total).minus(item.credited)
    if (!amount) error = `Potongan untuk "${item.description}" tidak sah.`
    else if (new Decimal(amount).greaterThan(remaining)) error = `Potongan "${item.description}" maksimal ${formatRupiah(remaining)}.`
    else if (new Decimal(amount).greaterThan(0)) { lines.push({ invoice_item_id: item.id, amount }); total = total.plus(amount) }
  }
  if (!error && lines.length === 0) error = 'Isi potongan pada minimal satu baris.'
  if (!error && reason.trim().length < 3) error = 'Tulis alasan potongan.'

  function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (!error) setConfirming(true)
  }
  async function confirm() {
    const result = await command.run({
      invoice_id: invoice.id, expected_version: ticket.version, reason: reason.trim(), lines,
    })
    setConfirming(false)
    if (result) { setAmounts({}); setReason(''); setTouched(false) }
  }

  return (
    <form onSubmit={submit} noValidate>
      <p className="srv-muted">Potongan tidak mengembalikan uang otomatis. Bila uang sudah lebih, catat pengembalian di bagian Pembayaran.</p>
      {invoice.items.map(item => (
        <RupiahInput key={item.id} label={`Potong: ${item.description} (sisa ${formatRupiah(new Decimal(item.net_total).minus(item.credited))})`}
          value={amounts[item.id] ?? ''} onChange={value => setAmounts(a => ({ ...a, [item.id]: value }))} />
      ))}
      <TextArea label="Alasan potongan" value={reason} onChange={setReason} required rows={2} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" variant="secondary" disabled={command.busy}>Simpan potongan</Button>
      <ConfirmDialog open={confirming} title="Potong tagihan?" confirmLabel="Ya, potong tagihan" busy={command.busy}
        onConfirm={() => void confirm()} onCancel={() => setConfirming(false)}>
        <p>Tagihan dipotong <strong>{formatRupiah(total)}</strong>.</p>
      </ConfirmDialog>
    </form>
  )
}
