import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  Card, Checkbox, EmptyState, ErrorMessage, Loading, Notice, PageHeader, SummaryRow, TextArea, TextInput,
} from '../../components/ui'
import { formatDateTime, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { customerHistory, findSimilarCustomers, searchCustomers, serviceKeys, useServiceCommand } from './api'
import { Button, CommandError, PaymentBadge, StatusBadge } from './common'
import { telHref } from './logic'
import type { CustomerRef, SimilarCustomer } from './types'
import { useDebounced } from './useDebounced'
import './service.css'

type Mode = { kind: 'list' } | { kind: 'new' } | { kind: 'view'; customerId: string }

/** Data pelanggan (FR-CUS-01): cari, tambah, ubah, riwayat servis. */
export function CustomersPage() {
  const profile = useProfile()
  const canEdit = permissions.receiveService(profile)
  const [mode, setMode] = useState<Mode>({ kind: 'list' })
  const [query, setQuery] = useState('')
  const debounced = useDebounced(query)
  const results = useQuery({ queryKey: serviceKeys.customerSearch(debounced), queryFn: () => searchCustomers(debounced) })

  return (
    <section className="srv-page">
      <PageHeader title="Pelanggan" description="Cari dengan nama atau nomor HP. Pelanggan servis wajib punya kontak."
        actions={canEdit && mode.kind !== 'new'
          ? <Button onClick={() => setMode({ kind: 'new' })}>+ Pelanggan baru</Button> : undefined} />

      {mode.kind === 'new' && (
        <NewCustomer onDone={id => setMode(id ? { kind: 'view', customerId: id } : { kind: 'list' })} />
      )}
      {mode.kind === 'view' && (
        <CustomerDetail key={mode.customerId} customerId={mode.customerId} canEdit={canEdit}
          onClose={() => setMode({ kind: 'list' })} />
      )}

      <TextInput type="search" label="Cari nama atau nomor HP" value={query} onChange={setQuery}
        placeholder="Contoh: Budi atau 0812…" maxLength={120} />
      {results.isPending && <Loading label="Memuat pelanggan…" />}
      {results.isError && <ErrorMessage error={results.error} />}
      {results.isSuccess && results.data.length === 0 && <EmptyState>Tidak ada pelanggan yang cocok.</EmptyState>}
      {results.isSuccess && results.data.length > 0 && (
        <ul className="srv-option-list" aria-label="Daftar pelanggan">
          {results.data.map(c => (
            <li key={c.id}>
              <button type="button" className="srv-option" aria-current={mode.kind === 'view' && mode.customerId === c.id}
                onClick={() => setMode({ kind: 'view', customerId: c.id })}>
                <strong>{c.name}</strong>
                {(c.phone || c.alternate_contact) && <span>{[c.phone, c.alternate_contact].filter(Boolean).join(' · ')}</span>}
                <span className="srv-muted">
                  {c.open_tickets > 0 ? `${c.open_tickets} servis berjalan` : 'Tidak ada servis berjalan'}
                  {c.last_ticket_at && ` · terakhir ${formatDateTime(c.last_ticket_at)}`}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

type CustomerForm = { name: string; phone: string; alternateContact: string; address: string }

const toForm = (c?: CustomerRef): CustomerForm => ({
  name: c?.name ?? '', phone: c?.phone ?? '', alternateContact: c?.alternate_contact ?? '', address: c?.address ?? '',
})

function formError(form: CustomerForm): string | null {
  if (!form.name.trim()) return 'Nama wajib diisi.'
  if (!form.phone.trim() && !form.alternateContact.trim()) return 'Isi nomor HP atau kontak lain.'
  return null
}

function formPayload(form: CustomerForm): Record<string, unknown> {
  return {
    name: form.name.trim(),
    phone: form.phone.trim(),
    alternate_contact: form.alternateContact.trim(),
    address: form.address.trim(),
  }
}

function CustomerFields({ form, onChange }: { form: CustomerForm; onChange: (form: CustomerForm) => void }) {
  const set = (key: keyof CustomerForm) => (value: string) => onChange({ ...form, [key]: value })
  return (
    <>
      <TextInput label="Nama" value={form.name} onChange={set('name')} required maxLength={120} />
      <TextInput type="tel" label="Nomor HP" value={form.phone} onChange={set('phone')} maxLength={40}
        hint="Boleh ditulis +62 atau 08; sistem merapikannya." />
      <TextInput label="Kontak lain" value={form.alternateContact} onChange={set('alternateContact')} maxLength={120} />
      <TextArea label="Alamat" value={form.address} onChange={set('address')} rows={2} maxLength={500} />
    </>
  )
}

function NewCustomer({ onDone }: { onDone: (customerId: string | null) => void }) {
  const [form, setForm] = useState<CustomerForm>(toForm())
  const [similar, setSimilar] = useState<SimilarCustomer[] | null>(null)
  const [distinct, setDistinct] = useState(false)
  const [touched, setTouched] = useState(false)
  const [checking, setChecking] = useState(false)
  const [checkError, setCheckError] = useState<unknown>(null)
  const command = useServiceCommand<{ customer_id: string }, Record<string, unknown>>('create_customer_v1')
  const error = formError(form)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    if (similar === null) {
      // Langkah 1: tampilkan kandidat mirip sebelum membuat pelanggan baru (tanpa penggabungan otomatis).
      setChecking(true)
      setCheckError(null)
      try {
        const found = await findSimilarCustomers(form.name, form.phone)
        setSimilar(found)
        if (found.length > 0) return
      } catch (err) {
        setCheckError(err)
        return
      } finally {
        setChecking(false)
      }
    } else if (similar.length > 0 && !distinct) return
    const result = await command.run(formPayload(form))
    if (result) onDone(result.customer_id)
  }

  return (
    <Card title="Pelanggan baru">
      <form onSubmit={submit} noValidate>
        <CustomerFields form={form} onChange={next => { setForm(next); setSimilar(null); setDistinct(false) }} />
        {similar && similar.length > 0 && (
          <Notice tone="warning">
            <p className="srv-notice-title">Pelanggan mirip sudah ada:</p>
            <ul className="srv-option-list">
              {similar.map(c => (
                <li key={c.id}>
                  <button type="button" className="srv-option" onClick={() => onDone(c.id)}>
                    <strong>Buka: {c.name}</strong>
                    <span>{[c.phone, c.alternate_contact].filter(Boolean).join(' · ')}</span>
                    <span className="srv-muted">{c.match.includes('PHONE') ? 'Nomor HP sama' : 'Nama mirip'}</span>
                  </button>
                </li>
              ))}
            </ul>
            <Checkbox label="Ini orang yang berbeda, tetap buat baru" checked={distinct} onChange={setDistinct} />
          </Notice>
        )}
        {touched && error && <ErrorMessage error={error} />}
        {checkError !== null && <ErrorMessage error={checkError} />}
        <CommandError error={command.error} />
        <div className="srv-actions">
          <Button type="submit" disabled={command.busy || checking || (similar !== null && similar.length > 0 && !distinct)}>
            {command.busy || checking ? 'Memeriksa…' : 'Simpan pelanggan'}
          </Button>
          <Button variant="secondary" onClick={() => onDone(null)}>Batal</Button>
        </div>
      </form>
    </Card>
  )
}

function CustomerDetail({ customerId, canEdit, onClose }: { customerId: string; canEdit: boolean; onClose: () => void }) {
  const [editing, setEditing] = useState(false)
  const history = useQuery({ queryKey: serviceKeys.customerHistory(customerId), queryFn: () => customerHistory(customerId) })
  if (history.isPending) return <Loading label="Memuat pelanggan…" />
  if (history.isError) return <ErrorMessage error={history.error} />
  const { customer, tickets, sale_invoices: sales } = history.data

  return (
    <Card title={customer.name} actions={<Button variant="secondary" onClick={onClose}>Tutup</Button>}>
      {editing ? (
        <EditCustomer customer={customer} onDone={() => setEditing(false)} />
      ) : (
        <>
          {customer.phone && <SummaryRow label="HP" value={<a href={telHref(customer.phone)}>{customer.phone}</a>} />}
          {customer.alternate_contact && <SummaryRow label="Kontak lain" value={customer.alternate_contact} />}
          {customer.address && <SummaryRow label="Alamat" value={customer.address} />}
          {canEdit && <Button variant="secondary" onClick={() => setEditing(true)}>Ubah data</Button>}
        </>
      )}
      <h3 className="srv-subheading">Riwayat servis</h3>
      {tickets.length === 0 ? <EmptyState>Belum pernah servis.</EmptyState> : (
        <ul className="srv-option-list">
          {tickets.map(t => (
            <li key={t.id}>
              <Link className="srv-option" to={`/servis/${t.id}`}>
                <strong>{t.number} · {t.equipment_type}</strong>
                <span><StatusBadge status={t.work_status} location={t.service_location} /> <PaymentBadge status={t.payment_status} /></span>
                <span className="srv-muted">
                  {formatDateTime(t.created_at)}{t.invoice_total !== null && ` · ${formatRupiah(t.invoice_total)}`}
                  {t.parent_ticket_id && ' · keluhan kembali'}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
      {sales.length > 0 && (
        <>
          <h3 className="srv-subheading">Pembelian barang</h3>
          {sales.map(s => <SummaryRow key={s.id} label={`${s.number} · ${formatDateTime(s.posted_at)}`} value={formatRupiah(s.total)} />)}
        </>
      )}
    </Card>
  )
}

function EditCustomer({ customer, onDone }: { customer: CustomerRef; onDone: () => void }) {
  const [form, setForm] = useState<CustomerForm>(toForm(customer))
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<{ customer_id: string }, Record<string, unknown>>('upsert_customer_v1')
  const error = formError(form)
  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const result = await command.run({ ...formPayload(form), customer_id: customer.id, expected_version: customer.version })
    if (result) onDone()
  }
  return (
    <form onSubmit={submit} noValidate>
      <CustomerFields form={form} onChange={setForm} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <div className="srv-actions">
        <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan perubahan'}</Button>
        <Button variant="secondary" onClick={onDone}>Batal</Button>
      </div>
    </form>
  )
}
