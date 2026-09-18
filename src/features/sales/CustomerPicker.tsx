import { useEffect, useState } from 'react'
import { ErrorMessage, Loading, TextInput } from '../../components/ui'
import { searchCustomers } from './api'
import { useDebounced } from '../../components/useDebounced'
import type { CustomerSummary } from './types'

type Found = { query: string; items: CustomerSummary[]; error: unknown }

/** Pelanggan opsional: cari nama atau nomor HP, pilih dari daftar. */
export function CustomerPicker({ value, onChange }: {
  value: CustomerSummary | null
  onChange: (customer: CustomerSummary | null) => void
}) {
  const [query, setQuery] = useState('')
  const debounced = useDebounced(query.trim(), 300)
  const [found, setFound] = useState<Found | null>(null)

  useEffect(() => {
    if (debounced.length < 2) return
    let alive = true
    searchCustomers(debounced)
      .then(items => { if (alive) setFound({ query: debounced, items, error: null }) })
      .catch((error: unknown) => { if (alive) setFound({ query: debounced, items: [], error }) })
    return () => { alive = false }
  }, [debounced])

  if (value) {
    return (
      <div className="sl-customer-chosen">
        <span>Pelanggan: <strong>{value.name}</strong>{value.phone ? ` (${value.phone})` : ''}</span>
        <button type="button" className="ui-button ui-button-secondary" onClick={() => onChange(null)}>
          Tanpa pelanggan
        </button>
      </div>
    )
  }

  const current = debounced.length >= 2 && found?.query === debounced
  return (
    <div className="sl-customer">
      <TextInput type="search" label="Pelanggan (boleh dikosongkan)" value={query} onChange={setQuery}
        placeholder="Ketik nama atau nomor HP" maxLength={120} />
      {query.trim().length >= 2 && !current && <Loading label="Mencari pelanggan…" />}
      {current && <ErrorMessage error={found.error} />}
      {current && !found.error && found.items.length === 0 && (
        <p className="sl-muted">Pelanggan tidak ditemukan. Penjualan tetap bisa tanpa nama pelanggan.</p>
      )}
      {current && found.items.length > 0 && (
        <ul className="sl-pick-list" aria-label="Pilih pelanggan">
          {found.items.map(c => (
            <li key={c.id}>
              <button type="button" className="sl-pick" onClick={() => { onChange(c); setQuery('') }}>
                <strong>{c.name}</strong>
                {c.phone && <span>{c.phone}</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
