import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'
import { formatQuantity, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { EmptyState, ErrorMessage, Loading, PageHeader, Select, TextInput } from '../../components/ui'
import { useDebounced } from '../../components/useDebounced'
import { defaultUnit, type ProductSummary } from '../../components/productTypes'
import { useCategories } from './api'

const LIMIT = 100

function ProductCard({ product }: { product: ProductSummary }) {
  const unit = defaultUnit(product)
  return (
    <li>
      <Link className="list-card" to={`/katalog/${product.id}`}>
        <span className="list-card-title">{product.name}</span>
        {product.specification && <span>{product.specification}</span>}
        <span className="muted">Kode {product.sku}{product.shelf ? ` · Rak ${product.shelf}` : ''}</span>
        {unit && <span className="list-card-money">{formatRupiah(unit.sell_price)} / {unit.label}</span>}
        <span>
          Stok toko <strong>{formatQuantity(product.stock_shop, product.base_unit)}</strong>
          {' · '}Dibawa ayah <strong>{formatQuantity(product.stock_field, product.base_unit)}</strong>
        </span>
      </Link>
    </li>
  )
}

export function CatalogPage() {
  const profile = useProfile()
  const canEdit = permissions.manageCatalog(profile)
  const [query, setQuery] = useState('')
  const [categoryId, setCategoryId] = useState('')
  const debounced = useDebounced(query.trim())
  const categories = useCategories()

  const products = useQuery({
    queryKey: ['products', 'list', debounced, categoryId],
    queryFn: () => readRpc<ProductSummary[]>('search_products_v1', {
      query: debounced, limit: LIMIT, ...(categoryId ? { category_id: categoryId } : {}),
    }),
  })

  return (
    <section>
      <PageHeader title="Katalog" description="Harga jual dan stok dibaca langsung dari server."
        actions={canEdit && (
          <>
            <Link className="ui-button ui-button-primary" to="/katalog/baru">Tambah barang</Link>
            <Link className="ui-button ui-button-secondary" to="/katalog/impor">Impor dari berkas</Link>
            <Link className="ui-button ui-button-secondary" to="/katalog/kategori">Kategori</Link>
          </>
        )} />
      <div className="form-grid">
        <TextInput type="search" label="Cari nama, kode, atau barcode" value={query} onChange={setQuery}
          maxLength={120} placeholder="Contoh: kabel NYA, LMP-001" />
        <Select label="Kategori" value={categoryId} onChange={setCategoryId}
          options={[{ value: '', label: 'Semua kategori' }, ...(categories.data ?? []).map(c => ({ value: c.id, label: c.name }))]} />
      </div>
      {products.isLoading && <Loading label="Memuat katalog…" />}
      <ErrorMessage error={products.error} />
      {products.data && products.data.length === 0 && (
        <EmptyState>{debounced ? 'Tidak ada barang yang cocok.' : 'Katalog masih kosong.'}</EmptyState>
      )}
      {products.data && products.data.length > 0 && (
        <>
          <ul className="card-list">{products.data.map(p => <ProductCard key={p.id} product={p} />)}</ul>
          {products.data.length >= LIMIT && (
            <p className="muted">Menampilkan {LIMIT} barang pertama. Ketik nama atau kode untuk mempersempit.</p>
          )}
        </>
      )}
    </section>
  )
}
