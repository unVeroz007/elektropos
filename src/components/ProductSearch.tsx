import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { readRpc } from '../lib/rpc'
import { formatQuantity } from '../lib/numbers'
import { BarcodeScanner } from '../features/scanner'
import { ErrorMessage, Loading, Notice, TextInput } from './ui'
import { useDebounced } from './useDebounced'
import { productTitle, type ProductSummary } from './productTypes'

type Props = {
  /** Dipanggil saat pengguna memilih produk; `unitId` terisi bila barcode terdaftar ke satuan tertentu. */
  onSelect: (product: ProductSummary, unitId?: string) => void
  label?: string
  withScanner?: boolean
  scannerTitle?: string
}

type BarcodeHit = { found: boolean; code: string; product_id?: string; sku?: string; unit_id?: string }

export async function findProductByBarcode(code: string): Promise<{ product: ProductSummary; unitId?: string } | null> {
  const hit = await readRpc<BarcodeHit>('find_by_barcode_v1', { code })
  if (!hit.found || !hit.sku) return null
  const rows = await readRpc<ProductSummary[]>('search_products_v1', { query: hit.sku, limit: 10 })
  const product = rows.find(p => p.id === hit.product_id)
  return product ? { product, unitId: hit.unit_id } : null
}

/** Cari produk dengan nama/SKU/barcode, atau scan. Tidak mengubah data apa pun. */
export function ProductSearch({ onSelect, label = 'Cari barang (nama, kode, atau barcode)', withScanner, scannerTitle }: Props) {
  const [query, setQuery] = useState('')
  const [scanMessage, setScanMessage] = useState<string | null>(null)
  const [scanError, setScanError] = useState<unknown>(null)
  const debounced = useDebounced(query.trim())

  const results = useQuery({
    queryKey: ['products', 'search', debounced],
    queryFn: () => readRpc<ProductSummary[]>('search_products_v1', { query: debounced, limit: 20 }),
    enabled: debounced.length > 0,
  })

  async function handleScan(code: string) {
    setScanMessage(null)
    setScanError(null)
    try {
      const found = await findProductByBarcode(code)
      if (!found) {
        setScanMessage(`Barcode ${code} belum terdaftar. Cari dengan nama barang, atau daftarkan barcode di Katalog.`)
        return
      }
      onSelect(found.product, found.unitId)
    } catch (err) {
      setScanError(err)
    }
  }

  function choose(product: ProductSummary) {
    onSelect(product)
    setQuery('')
  }

  return (
    <div className="product-search">
      {withScanner && (
        <BarcodeScanner onScan={code => { void handleScan(code) }} title={scannerTitle ?? 'Scan barcode barang'}
          description="Scan hanya memilih barang. Belum ada data yang tersimpan." />
      )}
      {scanMessage && <Notice tone="warning">{scanMessage}</Notice>}
      <ErrorMessage error={scanError} />
      <TextInput type="search" label={label} value={query} onChange={setQuery} maxLength={120}
        placeholder="Contoh: kabel NYA 1,5 / LMP-001" />
      {results.isFetching && <Loading label="Mencari barang…" />}
      <ErrorMessage error={results.error} />
      {results.data && debounced.length > 0 && (
        results.data.length === 0
          ? <p className="muted">Tidak ada barang yang cocok dengan “{debounced}”.</p>
          : (
            <ul className="pick-list" aria-label="Hasil pencarian barang">
              {results.data.map(p => (
                <li key={p.id}>
                  <button type="button" className="pick-item" onClick={() => choose(p)}>
                    <strong>{productTitle(p)}</strong>
                    <span>Kode {p.sku} · Stok toko {formatQuantity(p.stock_shop, p.base_unit)}</span>
                  </button>
                </li>
              ))}
            </ul>
          )
      )}
    </div>
  )
}
