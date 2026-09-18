import { useState, type FormEvent } from 'react'
import Decimal from 'decimal.js'
import {
  Card, Checkbox, ChoiceGroup, ConfirmDialog, ErrorMessage, Notice, RupiahInput, SummaryRow, TextArea, TextInput,
} from '../../../components/ui'
import { formatDateTime, formatRupiah, rupiahOrNull } from '../../../lib/numbers'
import { permissions, useProfile, type Profile } from '../../../lib/session'
import { useServiceCommand } from '../api'
import { Button, CommandError, PaymentBadge } from '../common'
import { CASHBOX, METHOD, PAYMENT_PURPOSE } from '../labels'
import { isPositive, paymentFormError, refundLimit, settlementAmount } from '../logic'
import type { Cashbox, CommandResult, PayMethod, PaymentRecord, PaymentResult, TicketDetail } from '../types'
import { ReceiptDialog, type ReceiptData } from './Receipt'

const METHODS: { value: PayMethod; label: string; description?: string }[] = [
  { value: 'CASH', label: METHOD.CASH },
  { value: 'TRANSFER', label: METHOD.TRANSFER },
  { value: 'QRIS', label: METHOD.QRIS },
]

function cashboxOptions(profile: Profile): { value: Cashbox; label: string }[] {
  return permissions.manageFatherWallet(profile)
    ? [{ value: 'SHOP_DRAWER', label: CASHBOX.SHOP_DRAWER }, { value: 'FATHER_WALLET', label: CASHBOX.FATHER_WALLET }]
    : [{ value: 'SHOP_DRAWER', label: CASHBOX.SHOP_DRAWER }]
}

function equipmentOf(ticket: TicketDetail): string {
  return [ticket.equipment_type, ticket.equipment_brand, ticket.equipment_model].filter(Boolean).join(' ')
}

/** Status bayar, uang muka, pelunasan tepat sisa, pengembalian, dan kuitansi (BR-10). */
export function PaymentPanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)
  const { payment } = ticket
  const final = payment.invoice_id !== null
  const settlement = settlementAmount(payment)
  const canReceive = permissions.receiveService(profile) && !ticket.closed_at && (!final || settlement !== null)
  const refundMax = refundLimit(ticket)
  const canRefund = permissions.manageService(profile) && !ticket.closed_at && refundMax !== null

  function reprint(record: PaymentRecord) {
    const beforeInvoice = !ticket.invoice || Date.parse(record.occurred_at) < Date.parse(ticket.invoice.posted_at)
    setReceipt({
      ticketNumber: ticket.number, customerName: ticket.customer?.name ?? null, equipment: equipmentOf(ticket),
      purpose: beforeInvoice ? 'DEPOSIT' : 'SETTLEMENT', method: record.method, cashbox: record.cashbox,
      amount: record.amount, tendered: record.tendered, change: record.change, occurredAt: record.occurred_at,
      actorName: record.actor_name, payment, reprint: true,
    })
  }

  return (
    <Card title="Pembayaran" actions={<PaymentBadge status={payment.status} />}>
      <SummaryRow label="Tagihan final" value={final ? formatRupiah(payment.invoice_net) : 'Belum ditentukan'} />
      <SummaryRow label={final ? 'Sudah dibayar' : 'Uang muka diterima'} value={formatRupiah(payment.net_received)} />
      {final && <SummaryRow strong label="Sisa bayar" value={formatRupiah(payment.outstanding)}
        tone={isPositive(payment.outstanding) ? 'danger' : 'success'} />}
      {isPositive(payment.refund_due) && (
        <SummaryRow strong label="Harus dikembalikan ke pelanggan" value={formatRupiah(payment.refund_due)} tone="danger" />
      )}

      {ticket.payments.length > 0 && (
        <ul className="srv-payment-list" aria-label="Riwayat pembayaran">
          {ticket.payments.map(p => (
            <li key={p.id}>
              <div>
                <strong>{p.direction === 'OUT' ? '-' : ''}{formatRupiah(p.amount)}</strong>
                {' · '}{PAYMENT_PURPOSE[p.purpose] ?? 'Pembayaran'} · {METHOD[p.method]}
                {p.cashbox && ` (${CASHBOX[p.cashbox]})`}
                <div className="srv-muted">{formatDateTime(p.occurred_at)} · {p.actor_name ?? '-'}</div>
              </div>
              {p.direction === 'IN' && p.purpose === 'SERVICE_RECEIPT' && (
                <Button variant="secondary" onClick={() => reprint(p)}>Cetak kuitansi</Button>
              )}
            </li>
          ))}
        </ul>
      )}

      {final && !isPositive(payment.outstanding) && !isPositive(payment.refund_due) && (
        <Notice tone="success">Tagihan sudah lunas.</Notice>
      )}
      {canReceive && (
        <PaymentForm key={`${payment.invoice_id ?? 'dp'}-${payment.outstanding ?? ''}`} ticket={ticket} settlement={settlement}
          onPaid={result => setReceipt({
            ticketNumber: result.ticket_number, customerName: ticket.customer?.name ?? null, equipment: equipmentOf(ticket),
            purpose: result.purpose, method: result.method, cashbox: result.cashbox, amount: result.amount,
            tendered: result.tendered, change: result.change, occurredAt: result.occurred_at,
            actorName: result.actor_name, payment: result.payment,
          })} />
      )}
      {canRefund && refundMax && <RefundForm key={refundMax} ticket={ticket} limit={refundMax} />}
      {receipt && <ReceiptDialog receipt={receipt} onClose={() => setReceipt(null)} />}
    </Card>
  )
}

function PaymentForm({ ticket, settlement, onPaid }: {
  ticket: TicketDetail
  settlement: string | null
  onPaid: (result: PaymentResult) => void
}) {
  const profile = useProfile()
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState<PayMethod>('CASH')
  const [cashbox, setCashbox] = useState<Cashbox>('SHOP_DRAWER')
  const [tendered, setTendered] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [reference, setReference] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<PaymentResult, Record<string, unknown>>('record_service_payment_v1')

  // Hasil belum diketahui: isian dikunci agar pengiriman ulang memakai data & operation_id yang sama.
  const locked = command.error?.kind === 'network' || command.busy
  const amountValue = settlement ?? rupiahOrNull(amount)
  const error = paymentFormError({ amount: amountValue, method, tendered, confirmed })

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error || !amountValue) return
    const payload: Record<string, unknown> = {
      ticket_id: ticket.id, purpose: settlement ? 'SETTLEMENT' : 'DEPOSIT', amount: amountValue, method,
    }
    if (method === 'CASH') {
      payload.cashbox = cashbox
      payload.tendered = rupiahOrNull(tendered)
    } else {
      payload.confirmed = true
      if (reference.trim()) payload.reference = reference.trim()
    }
    const result = await command.run(payload)
    if (result) {
      setAmount(''); setTendered(''); setConfirmed(false); setReference(''); setTouched(false)
      onPaid(result)
    }
  }

  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <p className="srv-subform-title">{settlement ? 'Pelunasan' : 'Terima uang muka (boleh lebih dari sekali)'}</p>
      <fieldset className="srv-fieldset-plain" disabled={locked}>
        {settlement
          ? <SummaryRow strong label="Harus dibayar tepat" value={formatRupiah(settlement)} />
          : <RupiahInput label="Jumlah uang muka" value={amount} onChange={setAmount} required />}
        <ChoiceGroup label="Cara bayar" value={method} onChange={value => { setMethod(value); setConfirmed(false) }} options={METHODS} />
        {method === 'CASH' ? (
          <>
            {cashboxOptions(profile).length > 1 && (
              <ChoiceGroup label="Uang masuk ke" value={cashbox} onChange={setCashbox} options={cashboxOptions(profile)} />
            )}
            <RupiahInput label="Uang diterima dari pelanggan" value={tendered} onChange={setTendered} required
              hint="Kembalian dihitung sistem setelah disimpan." />
            {amountValue && (
              <Button variant="secondary" onClick={() => setTendered(amountValue)}>Uang pas {formatRupiah(amountValue)}</Button>
            )}
          </>
        ) : (
          <>
            <TextInput label="Nomor referensi (opsional)" value={reference} onChange={setReference} maxLength={100} />
            <Checkbox label={`Saya sudah memastikan ${METHOD[method]} ${amountValue ? formatRupiah(amountValue) : ''} benar-benar masuk`}
              checked={confirmed} onChange={setConfirmed} />
          </>
        )}
      </fieldset>
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <div className="srv-actions">
        <Button type="submit" large disabled={command.busy}>
          {command.busy ? 'Menyimpan…'
            : command.error?.kind === 'network' ? 'Kirim ulang (aman, tidak tercatat dua kali)'
              : settlement ? `Lunasi sisa ${formatRupiah(settlement)}`
                : `Terima uang muka${amountValue ? ` ${formatRupiah(amountValue)}` : ''}`}
        </Button>
        {command.error?.kind === 'network' && (
          <Button variant="secondary" onClick={command.reset}>Ubah isian (cek riwayat pembayaran dulu)</Button>
        )}
      </div>
    </form>
  )
}

function RefundForm({ ticket, limit }: { ticket: TicketDetail; limit: string }) {
  const [amount, setAmount] = useState(() => new Decimal(limit).toFixed(0))
  const [method, setMethod] = useState<PayMethod>('CASH')
  const [cashbox, setCashbox] = useState<Cashbox>('SHOP_DRAWER')
  const [confirmed, setConfirmed] = useState(false)
  const [reference, setReference] = useState('')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('refund_service_payment_v1')

  const amountValue = rupiahOrNull(amount)
  let error: string | null = null
  if (!amountValue || !new Decimal(amountValue).greaterThan(0)) error = 'Isi jumlah yang dikembalikan.'
  else if (new Decimal(amountValue).greaterThan(limit)) error = `Maksimal ${formatRupiah(limit)}.`
  else if (reason.trim().length < 3) error = 'Tulis alasan pengembalian.'
  else if (method !== 'CASH' && !confirmed) error = 'Centang konfirmasi setelah uang benar-benar dikirim.'

  function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (!error) setConfirming(true)
  }
  async function confirm() {
    const payload: Record<string, unknown> = { ticket_id: ticket.id, amount: amountValue, method, reason: reason.trim() }
    if (method === 'CASH') payload.cashbox = cashbox
    else {
      payload.confirmed = true
      if (reference.trim()) payload.reference = reference.trim()
    }
    await command.run(payload)
    setConfirming(false)
  }

  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <p className="srv-subform-title">Kembalikan uang ke pelanggan (maks. {formatRupiah(limit)})</p>
      <RupiahInput label="Jumlah dikembalikan" value={amount} onChange={setAmount} required />
      <ChoiceGroup label="Cara mengembalikan" value={method} onChange={value => { setMethod(value); setConfirmed(false) }} options={METHODS} />
      {method === 'CASH' ? (
        <ChoiceGroup label="Uang diambil dari" value={cashbox} onChange={setCashbox}
          options={[{ value: 'SHOP_DRAWER', label: CASHBOX.SHOP_DRAWER }, { value: 'FATHER_WALLET', label: CASHBOX.FATHER_WALLET }]} />
      ) : (
        <>
          <TextInput label="Nomor referensi (opsional)" value={reference} onChange={setReference} maxLength={100} />
          <Checkbox label="Saya sudah mengirim uang ini ke pelanggan" checked={confirmed} onChange={setConfirmed} />
        </>
      )}
      <TextArea label="Alasan" value={reason} onChange={setReason} required rows={2} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" variant="secondary" disabled={command.busy}>Kembalikan uang</Button>
      <ConfirmDialog open={confirming} title="Kembalikan uang?" confirmLabel="Ya, kembalikan" danger busy={command.busy}
        onConfirm={() => void confirm()} onCancel={() => setConfirming(false)}>
        <p>
          {amountValue ? formatRupiah(amountValue) : ''} dikembalikan lewat {METHOD[method]}
          {method === 'CASH' ? ` dari ${CASHBOX[cashbox]}` : ''}.
        </p>
      </ConfirmDialog>
    </form>
  )
}
