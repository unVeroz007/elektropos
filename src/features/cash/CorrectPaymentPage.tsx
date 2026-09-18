import { useState, type FormEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Card, Checkbox, ChoiceGroup, ConfirmDialog, EmptyState, ErrorMessage, Loading, Notice, PageHeader, TextInput,
} from '../../components/ui'
import { CASHBOX_LABEL, PAYMENT_METHOD_LABEL, labelOf } from '../../components/labels'
import { useDebounced } from '../../components/useDebounced'
import { formatDateTime, formatRupiah } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'
import { useCommand } from '../../lib/useCommand'

type Method = 'CASH' | 'TRANSFER' | 'QRIS'
type Cashbox = 'SHOP_DRAWER' | 'FATHER_WALLET'
type Source = 'SALE' | 'SERVICE'

type Payment = {
  id: string
  direction: 'IN' | 'OUT'
  purpose: string
  method: Method
  amount: string
  cashbox?: Cashbox | null
  reference: string | null
  actor_name: string | null
  occurred_at: string
}

type Found = { id: string; number: string; label: string }

const CORRECTABLE = ['SALE_RECEIPT', 'SERVICE_RECEIPT', 'PAYMENT_REPLACEMENT']

async function searchDocuments(source: Source, query: string): Promise<Found[]> {
  if (source === 'SALE') {
    const rows = await readRpc<{ id: string; number: string; total: string; posted_at: string }[]>(
      'list_invoices_v1', { query, kind: 'SALE', limit: 10 })
    return rows.map(r => ({ id: r.id, number: r.number, label: `${formatRupiah(r.total)} · ${formatDateTime(r.posted_at)}` }))
  }
  const page = await readRpc<{ items: { id: string; number: string; customer_name: string | null; equipment_type: string }[] }>(
    'list_service_tickets_v1', { query, include_closed: true, limit: 10 })
  return page.items.map(t => ({ id: t.id, number: t.number, label: [t.equipment_type, t.customer_name].filter(Boolean).join(' · ') }))
}

async function loadPayments(source: Source, id: string): Promise<Payment[]> {
  const detail = source === 'SALE'
    ? await readRpc<{ payments: Payment[] }>('get_invoice_v1', { invoice_id: id })
    : await readRpc<{ payments: Payment[] }>('get_service_ticket_v1', { ticket_id: id })
  return (detail.payments ?? []).filter(p => p.direction === 'IN' && CORRECTABLE.includes(p.purpose))
}

function paymentHolder(p: Payment): string {
  return p.method === 'CASH' && p.cashbox ? `Tunai (${labelOf(CASHBOX_LABEL, p.cashbox)})` : labelOf(PAYMENT_METHOD_LABEL, p.method)
}

function CorrectionForm({ payment, onDone }: { payment: Payment; onDone: () => void }) {
  const queryClient = useQueryClient()
  const [method, setMethod] = useState<Method>(payment.method === 'CASH' ? 'TRANSFER' : 'CASH')
  const [cashbox, setCashbox] = useState<Cashbox>('SHOP_DRAWER')
  const [confirmed, setConfirmed] = useState(false)
  const [reference, setReference] = useState('')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const [asking, setAsking] = useState(false)
  const command = useCommand<{ amount: string; already_refunded: string }, Record<string, unknown>>('correct_payment_v1')

  const sameHolder = method === payment.method && (method !== 'CASH' || cashbox === payment.cashbox)
  const error = sameHolder ? 'Pilih cara bayar atau kas yang berbeda dari catatan lama.'
    : method !== 'CASH' && !confirmed ? 'Centang bahwa uang benar-benar masuk ke rekening/QRIS toko.'
      : reason.trim().length < 3 ? 'Tulis alasan koreksi.' : null

  async function confirm() {
    const payload: Record<string, unknown> = { original_payment_id: payment.id, method, reason: reason.trim() }
    if (method === 'CASH') payload.cashbox = cashbox
    else {
      payload.confirmed = true
      if (reference.trim()) payload.reference = reference.trim()
    }
    const result = await command.run(payload)
    setAsking(false)
    if (result) {
      await queryClient.invalidateQueries()
      onDone()
    }
  }

  return (
    <form onSubmit={(event: FormEvent) => { event.preventDefault(); setTouched(true); if (!error) setAsking(true) }} noValidate>
      <p>Tercatat: <strong>{paymentHolder(payment)}</strong> {formatRupiah(payment.amount)} ({formatDateTime(payment.occurred_at)}).</p>
      <ChoiceGroup label="Cara bayar yang benar" value={method} onChange={value => { setMethod(value); command.reset() }} options={[
        { value: 'CASH', label: 'Tunai' }, { value: 'TRANSFER', label: 'Transfer bank' }, { value: 'QRIS', label: 'QRIS' },
      ]} />
      {method === 'CASH' ? (
        <ChoiceGroup label="Uang tunai ada di" value={cashbox} onChange={setCashbox} options={[
          { value: 'SHOP_DRAWER', label: CASHBOX_LABEL.SHOP_DRAWER }, { value: 'FATHER_WALLET', label: CASHBOX_LABEL.FATHER_WALLET },
        ]} />
      ) : (
        <>
          <Checkbox label="Saya sudah memastikan uang masuk" checked={confirmed} onChange={setConfirmed} />
          <TextInput label="Nomor referensi (boleh kosong)" value={reference} onChange={setReference} maxLength={100} />
        </>
      )}
      <TextInput label="Alasan koreksi" value={reason} onChange={setReason} maxLength={500} placeholder="Contoh: salah pilih, ternyata QRIS" />
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>Koreksi cara bayar</button>
      <ConfirmDialog open={asking} title="Koreksi cara bayar?" confirmLabel="Ya, koreksi" busy={command.busy}
        onConfirm={() => { void confirm() }} onCancel={() => setAsking(false)}>
        <p>Catatan lama dibalik dan diganti {method === 'CASH' ? `tunai di ${labelOf(CASHBOX_LABEL, cashbox)}` : labelOf(PAYMENT_METHOD_LABEL, method)}.
          Nota dan stok tidak berubah. Saldo kas yang sedang dibuka ikut menyesuaikan.</p>
      </ConfirmDialog>
    </form>
  )
}

/** Koreksi salah cara bayar (BR-07): pembalikan + pengganti, tanpa mengubah nota/stok. */
export function CorrectPaymentPage() {
  const [source, setSource] = useState<Source>('SALE')
  const [query, setQuery] = useState('')
  const [document, setDocument] = useState<Found | null>(null)
  const [selected, setSelected] = useState<Payment | null>(null)
  const [done, setDone] = useState(false)
  const debounced = useDebounced(query.trim())

  const found = useQuery({
    queryKey: ['cash', 'correct-search', source, debounced],
    queryFn: () => searchDocuments(source, debounced),
    enabled: debounced.length >= 2 && document === null,
  })
  const payments = useQuery({
    queryKey: ['cash', 'correct-payments', source, document?.id],
    queryFn: () => loadPayments(source, document?.id ?? ''),
    enabled: document !== null,
  })

  function reset() {
    setDocument(null)
    setSelected(null)
  }

  return (
    <section>
      <PageHeader title="Koreksi cara bayar" description="Untuk pembayaran yang tercatat dengan cara bayar atau kas yang salah." />
      {done && <Notice tone="success">Koreksi tersimpan. Laporan menampilkannya sebagai koreksi, bukan penerimaan baru.</Notice>}
      <Card title="1. Cari nota atau tiket servis">
        <ChoiceGroup label="Jenis" value={source} onChange={value => { setSource(value); reset() }} options={[
          { value: 'SALE', label: 'Nota penjualan' }, { value: 'SERVICE', label: 'Tiket servis' },
        ]} />
        {document ? (
          <div className="button-row">
            <span>Dipilih: <strong>{document.number}</strong> ({document.label})</span>
            <button type="button" className="ui-button ui-button-secondary" onClick={reset}>Ganti</button>
          </div>
        ) : (
          <>
            <TextInput type="search" label={source === 'SALE' ? 'Nomor nota' : 'Nomor tiket, nama, atau HP'} value={query}
              onChange={setQuery} maxLength={60} />
            {found.isFetching && <Loading label="Mencari…" />}
            <ErrorMessage error={found.error} />
            {found.data && found.data.length === 0 && <EmptyState>Tidak ditemukan.</EmptyState>}
            <ul className="card-list">
              {(found.data ?? []).map(d => (
                <li key={d.id} className="list-card">
                  <button type="button" className="list-card-link" onClick={() => { setDocument(d); setDone(false) }}>
                    <span className="list-card-title">{d.number}</span>
                    <span className="muted">{d.label}</span>
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}
      </Card>

      {document && (
        <Card title="2. Pilih pembayaran yang salah">
          {payments.isPending && <Loading label="Memuat pembayaran…" />}
          <ErrorMessage error={payments.error} />
          {payments.data && payments.data.length === 0 && <EmptyState>Tidak ada pembayaran yang bisa dikoreksi.</EmptyState>}
          <ul className="card-list">
            {(payments.data ?? []).map(p => (
              <li key={p.id} className="list-card">
                <button type="button" className="list-card-link" onClick={() => setSelected(p)} aria-pressed={selected?.id === p.id}>
                  <span className="list-card-title">{paymentHolder(p)} · {formatRupiah(p.amount)}</span>
                  <span className="muted">{formatDateTime(p.occurred_at)}{p.actor_name ? ` · ${p.actor_name}` : ''}{p.reference ? ` · ${p.reference}` : ''}</span>
                </button>
              </li>
            ))}
          </ul>
        </Card>
      )}

      {selected && (
        <Card title="3. Cara bayar yang benar">
          <CorrectionForm key={selected.id} payment={selected} onDone={() => { reset(); setDone(true) }} />
        </Card>
      )}
    </section>
  )
}
