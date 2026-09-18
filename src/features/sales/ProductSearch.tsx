import { useEffect, useState } from 'react'
import { EmptyState, ErrorMessage, Loading, TextInput } from '../../components/ui'
import { formatQuantity, formatRupiah } from '../../lib/numbers'
import { searchProducts } from './api'
import { snapshotFromSearch, type ProductSnapshot } from './cart'
import { useDebouncedValue } from './hooks'
import type { ProductSearchItem } from './types'

type SearchState = { query: string; items: ProductSearchItem[]; error: unknown }

/**
 * Pencarian barang. Hasil pencarian terpisah dari keranjang: mengetik kata lain
 * tidak mengubah isi keranjang (T03).
 */
export function ProductSearch({ onAdd, label = 'Cari barang' }: {
  onAdd: (snapshot: ProductSnapshot, product: ProductSearchItem) => void
  label?: string
}) {
  const [query, setQuery] = useState('')
  const debounced = useDebouncedValue(query.trim(), 250)
  const [result, setResult] = useState<SearchState>({ query: '', items: [], error: null })

  useEffect(() => {
    if (debounced === '') return
    let alive = true
    searchProducts(debounced)
      .then(items => { if (alive) setResult({ query: debounced, items, error: null }) })
      .catch((error: unknown) => { if (alive) setResult({ query: debounced, items: [], error }) })
    return () => { alive = false }
  }, [debounced])

  const current = debounced !== '' && result.query === debounced
  const loading = query.trim() !== '' && !current

  return (
    <div className="sl-search">
      <TextInput type="search" label={label} value={query} onChange={setQuery} maxLength={120}
        placeholder="Nama barang, kode, atau barcode" hint="Contoh: kabel NYA, lampu 10 watt, 8991234" />
      {loading && <Loading label="Mencari barang…" />}
      {current && <ErrorMessage error={result.error} />}
      {current && !result.error && result.items.length === 0 && (
        <EmptyState>Barang “{debounced}” tidak ditemukan. Coba kata lain atau periksa ejaan.</EmptyState>
      )}
      {current && result.items.length > 0 && (
        <ul className="sl-results" aria-label="Hasil pencarian">
          {result.items.map(product => (
            <li key={product.id} className="sl-result">
              <div className="sl-result-info">
                <strong>{product.name}</strong>
                {product.specification && <span>{product.specification}</span>}
                <small>
                  Kode {product.sku}{product.shelf ? ` · Rak ${product.shelf}` : ''}
                  {' · '}Stok toko {formatQuantity(product.stock_shop, product.base_unit)}
                </small>
                {product.track_segments && <small>Dijual per potongan dari roll. Setelah ditambah, pilih roll-nya.</small>}
              </div>
              <div className="sl-result-actions">
                {product.units.length === 0 && <small>Belum ada harga jual.</small>}
                {product.units.map(unit => (
                  <button key={unit.id} type="button" className="ui-button ui-button-primary"
                    onClick={() => onAdd(snapshotFromSearch(product, unit), product)}>
                    Tambah {unit.label} · {formatRupiah(unit.sell_price)}/{unit.label}
                  </button>
                ))}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
