import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import {
  Badge, Card, Checkbox, EmptyState, ErrorMessage, Loading, PageHeader, SummaryRow, TextArea, TextInput,
} from '../../components/ui'
import { formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { useDebounced } from '../../components/useDebounced'
import { supplierKeys, useSuppliers, type Supplier } from './api'

type SupplierForm = { name: string; contact: string; address: string; active: boolean }

function SupplierEditor({ supplier, onDone }: { supplier: Supplier | null; onDone: () => void }) {
  const queryClient = useQueryClient()
  const [form, setForm] = useState<SupplierForm>({
    name: supplier?.name ?? '', contact: supplier?.contact ?? '', address: supplier?.address ?? '', active: supplier?.active ?? true,
  })
  const [touched, setTouched] = useState(false)
  const command = useCommand<{ entity_id: string }, Record<string, unknown>>('upsert_supplier_v1')
  const error = form.name.trim().length < 2 ? 'Nama distributor wajib diisi.' : null
  const set = (patch: Partial<SupplierForm>) => { setForm(f => ({ ...f, ...patch })); command.reset() }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    // Server mengosongkan kolom teks yang tidak dikirim: selalu kirim nilai lengkap.
    const payload: Record<string, unknown> = {
      name: form.name.trim(), contact: form.contact.trim(), address: form.address.trim(),
    }
    if (supplier) Object.assign(payload, { supplier_id: supplier.id, expected_version: supplier.version, active: form.active })
    if (await command.run(payload)) {
      await queryClient.invalidateQueries({ queryKey: supplierKeys.all })
      onDone()
    }
  }

  return (
    <form onSubmit={submit} noValidate>
      <TextInput label="Nama distributor" value={form.name} onChange={name => set({ name })} required maxLength={120} />
      <TextInput type="tel" label="Kontak (HP/telepon)" value={form.contact} onChange={contact => set({ contact })} maxLength={120} />
      <TextArea label="Alamat" value={form.address} onChange={address => set({ address })} rows={2} maxLength={500} />
      {supplier && <Checkbox label="Masih aktif dipakai" checked={form.active} onChange={active => set({ active })} />}
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <div className="button-row">
        <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>Simpan</button>
        <button type="button" className="ui-button ui-button-secondary" onClick={onDone}>Batal</button>
      </div>
    </form>
  )
}

/** Daftar distributor, saldo kredit, dan klaim retur yang belum selesai. */
export function SuppliersPage() {
  const profile = useProfile()
  const canEdit = permissions.manageStock(profile)
  const [query, setQuery] = useState('')
  const [includeInactive, setIncludeInactive] = useState(false)
  const [editing, setEditing] = useState<Supplier | 'new' | null>(null)
  const suppliers = useSuppliers(useDebounced(query.trim()), includeInactive)
  const rows = suppliers.data ?? []

  return (
    <section>
      <PageHeader title="Distributor" description="Pemasok barang. Saldo kredit dapat dipakai membayar barang masuk berikutnya."
        actions={canEdit && editing === null
          ? <button type="button" className="ui-button ui-button-primary" onClick={() => setEditing('new')}>+ Distributor baru</button>
          : undefined} />
      {editing && (
        <Card title={editing === 'new' ? 'Distributor baru' : `Ubah ${editing.name}`}>
          <SupplierEditor key={editing === 'new' ? 'new' : editing.id} supplier={editing === 'new' ? null : editing}
            onDone={() => setEditing(null)} />
        </Card>
      )}
      <div className="form-grid">
        <TextInput type="search" label="Cari nama distributor" value={query} onChange={setQuery} maxLength={120} />
        <Checkbox label="Tampilkan yang tidak aktif" checked={includeInactive} onChange={setIncludeInactive} />
      </div>
      {suppliers.isLoading && <Loading label="Memuat distributor…" />}
      <ErrorMessage error={suppliers.error} />
      {suppliers.data && rows.length === 0 && <EmptyState>Belum ada distributor.</EmptyState>}
      <ul className="card-list">
        {rows.map(s => (
          <li key={s.id} className="list-card">
            <span className="list-card-title">{s.name} {!s.active && <Badge>Tidak aktif</Badge>}</span>
            {(s.contact || s.address) && <span className="muted">{[s.contact, s.address].filter(Boolean).join(' · ')}</span>}
            <SummaryRow label="Saldo kredit (potong tagihan)" value={formatRupiah(s.credit_balance)} />
            {s.pending_return_count > 0 && (
              <SummaryRow label={`Klaim retur belum selesai (${s.pending_return_count})`} value={formatRupiah(s.pending_claim_value)} tone="danger" />
            )}
            <span className="button-row">
              <Link className="ui-button ui-button-secondary" to={`/distributor/retur?distributor=${s.id}`}>Retur ke distributor ini</Link>
              {canEdit && <button type="button" className="ui-button ui-button-secondary" onClick={() => setEditing(s)}>Ubah</button>}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}
