import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Badge, Card, EmptyState, ErrorMessage, Loading, Notice, PageHeader, Select } from '../../components/ui'
import { LOCATION_LABEL } from '../../components/labels'
import { ProductSearch } from '../../components/ProductSearch'
import { productTitle, type ProductSummary } from '../../components/productTypes'
import { formatDateTime } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { stockKeys, usePagedRpc } from './api'
import { StockNav } from './StockNav'

type CountRow = {
  id: string
  status: 'DRAFT' | 'POSTED'
  note: string | null
  created_at: string
  posted_at: string | null
  item_count: number
  document_number: string | null
}

type CreateResult = { entity_id: string; item_count: number }

const MAX_PRODUCTS = 100

/** Mulai hitungan untuk barang terpilih. Toko tetap bisa berjualan selama menghitung. */
function NewCountCard() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [products, setProducts] = useState<ProductSummary[]>([])
  const [location, setLocation] = useState<'' | 'SHOP' | 'FIELD_FATHER'>('SHOP')
  const command = useCommand<CreateResult, Record<string, unknown>>('create_stock_count_v1')

  function add(product: ProductSummary) {
    command.reset()
    setProducts(list => list.some(p => p.id === product.id) || list.length >= MAX_PRODUCTS ? list : [...list, product])
  }

  async function start() {
    const result = await command.run({
      product_ids: products.map(p => p.id),
      ...(location ? { location } : {}),
    })
    if (result) {
      await queryClient.invalidateQueries({ queryKey: stockKeys.counts })
      navigate(`/stok/hitung/${result.entity_id}`)
    }
  }

  return (
    <Card title="Mulai hitung stok">
      <p className="muted">
        Pilih barang yang akan dihitung. Sistem mencatat jumlah tercatat saat ini; bila ada penjualan atau
        perpindahan barang itu sebelum hasil disimpan, hitungan perlu diulang.
      </p>
      <ProductSearch onSelect={add} />
      {products.length > 0 && (
        <ul className="card-list">
          {products.map(p => (
            <li key={p.id} className="list-card">
              <span className="list-card-title">{productTitle(p)}</span>
              <span className="button-row">
                <button type="button" className="ui-button ui-button-secondary"
                  onClick={() => setProducts(list => list.filter(x => x.id !== p.id))}>Batal pilih</button>
              </span>
            </li>
          ))}
        </ul>
      )}
      <Select label="Tempat yang dihitung" value={location} onChange={setLocation} options={[
        { value: 'SHOP', label: LOCATION_LABEL.SHOP },
        { value: 'FIELD_FATHER', label: LOCATION_LABEL.FIELD_FATHER },
        { value: '', label: 'Semua tempat' },
      ]} />
      <ErrorMessage error={command.error} />
      <button type="button" className="ui-button ui-button-primary" disabled={products.length === 0 || command.busy}
        onClick={() => { void start() }}>
        {command.busy ? 'Menyiapkan…' : `Mulai hitung ${products.length} barang`}
      </button>
    </Card>
  )
}

/** Daftar hitung stok (opname) dan awal hitungan baru (FR-INV-03). */
export function StockCountListPage() {
  const profile = useProfile()
  const counts = usePagedRpc<CountRow>('list_stock_counts_v1', stockKeys.counts, {})
  const rows = counts.data?.pages.flatMap(p => p.rows) ?? []
  const canCreate = permissions.manageStock(profile)

  return (
    <section>
      <PageHeader title="Hitung stok" description="Cocokkan jumlah di rak dengan catatan sistem, per barang yang dipilih." />
      <StockNav />
      {canCreate ? <NewCountCard /> : <Notice tone="info">Akun ini hanya dapat melihat hasil hitung stok.</Notice>}
      {counts.isLoading && <Loading label="Memuat hitungan…" />}
      <ErrorMessage error={counts.error} />
      {counts.data && rows.length === 0 && <EmptyState>Belum pernah hitung stok.</EmptyState>}
      <ul className="card-list">
        {rows.map(row => (
          <li key={row.id} className="list-card">
            <Link className="list-card-link" to={`/stok/hitung/${row.id}`}>
              <span className="list-card-title">Hitungan {formatDateTime(row.created_at)}</span>
              <span>
                <Badge tone={row.status === 'POSTED' ? 'success' : 'warning'}>
                  {row.status === 'POSTED' ? 'Sudah disimpan' : 'Belum selesai'}
                </Badge>{' '}{row.item_count} posisi{row.document_number ? ` · Dokumen ${row.document_number}` : ''}
              </span>
            </Link>
          </li>
        ))}
      </ul>
      {counts.hasNextPage && (
        <button type="button" className="ui-button ui-button-secondary" disabled={counts.isFetchingNextPage}
          onClick={() => { void counts.fetchNextPage() }}>Muat lebih banyak</button>
      )}
    </section>
  )
}
