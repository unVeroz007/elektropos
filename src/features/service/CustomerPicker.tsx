import { useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { Checkbox, EmptyState, ErrorMessage, Loading, Notice, TextArea, TextInput } from '../../components/ui'
import { findSimilarCustomers, searchCustomers, serviceKeys } from './api'
import { Button } from './common'
import type { CustomerRef, SimilarCustomer } from './types'
import { useDebounced } from './useDebounced'

export type NewCustomerDraft = {
  name: string
  phone: string
  alternateContact: string
  address: string
  /** Pengguna menyatakan pelanggan ini bukan salah satu kandidat mirip. */
  confirmedDistinct: boolean
  candidateCount: number
}

export type CustomerChoice =
  | { mode: 'existing'; customer: CustomerRef }
  | { mode: 'new'; draft: NewCustomerDraft }

export const emptyDraft = (): NewCustomerDraft => ({
  name: '', phone: '', alternateContact: '', address: '', confirmedDistinct: false, candidateCount: 0,
})

/** Pesan bila pilihan pelanggan belum boleh disimpan, atau null bila siap. */
export function customerChoiceError(choice: CustomerChoice | null): string | null {
  if (!choice) return 'Pilih pelanggan lama atau isi pelanggan baru.'
  if (choice.mode === 'existing') return null
  const { draft } = choice
  if (!draft.name.trim()) return 'Nama pelanggan wajib diisi.'
  if (!draft.phone.trim() && !draft.alternateContact.trim()) return 'Isi nomor HP atau kontak lain yang bisa dihubungi.'
  if (draft.candidateCount > 0 && !draft.confirmedDistinct) {
    return 'Ada pelanggan dengan nama/HP mirip. Pilih salah satu, atau centang bahwa ini orang yang berbeda.'
  }
  return null
}

function contactOf(c: CustomerRef): string {
  return [c.phone, c.alternate_contact].filter(Boolean).join(' · ') || 'Kontak tidak ditampilkan'
}

/**
 * Pilih pelanggan: cari yang sudah ada dulu; bila membuat baru, kandidat mirip
 * (HP/nama) ditampilkan dan pengguna memutuskan sendiri (tidak ada penggabungan otomatis).
 */
export function CustomerPicker({ value, onChange }: { value: CustomerChoice | null; onChange: (choice: CustomerChoice | null) => void }) {
  if (value?.mode === 'existing') {
    return (
      <div className="srv-picked">
        <div>
          <strong>{value.customer.name}</strong>
          <span className="srv-muted">{contactOf(value.customer)}</span>
        </div>
        <Button variant="secondary" onClick={() => onChange(null)}>Ganti pelanggan</Button>
      </div>
    )
  }
  if (value?.mode === 'new') {
    return <NewCustomerForm draft={value.draft} onChange={draft => onChange({ mode: 'new', draft })}
      onPick={customer => onChange({ mode: 'existing', customer })} onCancel={() => onChange(null)} />
  }
  return <CustomerSearch onPick={customer => onChange({ mode: 'existing', customer })}
    onNew={name => onChange({ mode: 'new', draft: { ...emptyDraft(), ...guessFromQuery(name) } })} />
}

function guessFromQuery(query: string): Partial<NewCustomerDraft> {
  const trimmed = query.trim()
  if (!trimmed) return {}
  return /^[0-9 +().-]+$/.test(trimmed) ? { phone: trimmed } : { name: trimmed }
}

function CustomerSearch({ onPick, onNew }: { onPick: (c: CustomerRef) => void; onNew: (query: string) => void }) {
  const [query, setQuery] = useState('')
  const debounced = useDebounced(query)
  const enabled = debounced.trim().length >= 2
  const results = useQuery({
    queryKey: serviceKeys.customerSearch(debounced),
    queryFn: () => searchCustomers(debounced),
    enabled,
  })
  return (
    <div className="srv-customer-search">
      <TextInput type="search" label="Cari pelanggan (nama atau nomor HP)" value={query} onChange={setQuery}
        placeholder="Contoh: Budi atau 0812…" maxLength={120} />
      {enabled && results.isPending && <Loading label="Mencari pelanggan…" />}
      {results.isError && <ErrorMessage error={results.error} />}
      {enabled && results.isSuccess && results.data.length === 0 && (
        <EmptyState>Belum ada pelanggan dengan nama/HP itu.</EmptyState>
      )}
      {results.isSuccess && results.data.length > 0 && (
        <ul className="srv-option-list" aria-label="Hasil pencarian pelanggan">
          {results.data.map(c => (
            <li key={c.id}>
              <button type="button" className="srv-option" onClick={() => onPick(c)}>
                <strong>{c.name}</strong>
                <span>{contactOf(c)}</span>
                {c.open_tickets > 0 && <span className="srv-muted">{c.open_tickets} servis masih berjalan</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
      <Button variant="secondary" onClick={() => onNew(query)}>+ Pelanggan baru</Button>
    </div>
  )
}

function NewCustomerForm({ draft, onChange, onPick, onCancel }: {
  draft: NewCustomerDraft
  onChange: (draft: NewCustomerDraft) => void
  onPick: (c: CustomerRef) => void
  onCancel: () => void
}) {
  const debouncedName = useDebounced(draft.name.trim())
  const debouncedPhone = useDebounced(draft.phone.trim())
  const enabled = debouncedName.length >= 3 || debouncedPhone.replace(/\D/g, '').length >= 6
  const similar = useQuery({
    queryKey: [...serviceKeys.customers, 'similar', debouncedName, debouncedPhone],
    queryFn: () => findSimilarCustomers(debouncedName, debouncedPhone),
    enabled,
  })
  const candidates: SimilarCustomer[] = enabled && similar.data ? similar.data : []
  useEffect(() => {
    // Sinkronkan jumlah kandidat agar validasi simpan tahu ada kemiripan.
    if (candidates.length !== draft.candidateCount) onChange({ ...draft, candidateCount: candidates.length })
  }, [candidates.length, draft, onChange])
  const set = (patch: Partial<NewCustomerDraft>) => onChange({ ...draft, ...patch, confirmedDistinct: false })

  return (
    <div className="srv-new-customer">
      <TextInput label="Nama pelanggan" value={draft.name} onChange={name => set({ name })} required maxLength={120} />
      <TextInput type="tel" label="Nomor HP" value={draft.phone} onChange={phone => set({ phone })}
        hint="HP atau kontak lain wajib salah satu." maxLength={40} />
      <TextInput label="Kontak lain (bila tidak punya HP)" value={draft.alternateContact}
        onChange={alternateContact => set({ alternateContact })} placeholder="Mis. HP anak / tetangga" maxLength={120} />
      <TextArea label="Alamat (opsional)" value={draft.address} onChange={address => set({ address })} rows={2} maxLength={500} />

      {similar.isError && <ErrorMessage error={similar.error} />}
      {candidates.length > 0 && (
        <Notice tone="warning">
          <p className="srv-notice-title">Mungkin pelanggan ini sudah tercatat:</p>
          <ul className="srv-option-list">
            {candidates.map(c => (
              <li key={c.id}>
                <button type="button" className="srv-option" onClick={() => onPick(c)}>
                  <strong>Pakai: {c.name}</strong>
                  <span>{contactOf(c)}</span>
                  <span className="srv-muted">
                    {c.match.includes('PHONE') ? 'Nomor HP sama' : 'Nama mirip'}
                  </span>
                </button>
              </li>
            ))}
          </ul>
          <Checkbox label="Bukan salah satu di atas, buat pelanggan baru" checked={draft.confirmedDistinct}
            onChange={confirmedDistinct => onChange({ ...draft, confirmedDistinct })} />
        </Notice>
      )}
      <Button variant="secondary" onClick={onCancel}>Kembali ke pencarian</Button>
    </div>
  )
}
