import { useState } from 'react'
import Decimal from 'decimal.js'
import { Badge, EmptyState, ErrorMessage, Loading, PageHeader, Select } from '../../components/ui'
import { DateRangeFields, rangeError, type DateRangeValue } from '../../components/DateRange'
import { CONDITION_LABEL, LOCATION_LABEL, STOCK_MOVEMENT_LABEL, labelOf } from '../../components/labels'
import { ProductSearch } from '../../components/ProductSearch'
import { productTitle, type ProductSummary } from '../../components/productTypes'
import { formatDateTime, formatQuantity, formatRupiah, todayInShop } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { stockKeys, usePagedRpc, type StockMovementRow } from './api'
import { StockNav } from './StockNav'

const KIND_OPTIONS = [
  { value: '', label: 'Semua jenis' },
  ...Object.entries(STOCK_MOVEMENT_LABEL).map(([value, label]) => ({ value, label })),
]

/** Sumber mutasi yang dapat dilacak (nota, tiket servis, atau dokumen stok). */
function sourceText(row: StockMovementRow): string | null {
  if (row.invoice_number) return `Nota ${row.invoice_number}`
  if (row.service_ticket_number) return `Servis ${row.service_ticket_number}`
  if (row.document_number) return `Dokumen ${row.document_number}`
  return null
}

function MovementItem({ row, showCost }: { row: StockMovementRow; showCost: boolean }) {
  const qty = new Decimal(row.qty_delta)
  const source = sourceText(row)
  return (
    <li className="list-card">
      <span className="list-card-title">{row.name}</span>
      <span className="muted">
        {formatDateTime(row.occurred_at)} · Kode {row.sku}{row.label ? ` · Label ${row.label}` : ''}
      </span>
      <span>
        <Badge tone={qty.isNegative() ? 'warning' : 'success'}>{labelOf(STOCK_MOVEMENT_LABEL, row.kind)}</Badge>{' '}
        <Badge>{labelOf(LOCATION_LABEL, row.location)}</Badge>{' '}
        <Badge tone={row.condition === 'DAMAGED' ? 'danger' : 'neutral'}>{labelOf(CONDITION_LABEL, row.condition)}</Badge>
      </span>
      <span className="list-card-money">{qty.isNegative() ? '−' : '+'}{formatQuantity(qty.abs(), row.base_unit)}</span>
      {showCost && row.cost_delta && <span className="muted">Nilai modal {formatRupiah(row.cost_delta)}</span>}
      {(source || row.reason || row.actor_name) && (
        <span className="muted">
          {[source, row.reason, row.actor_name ? `oleh ${row.actor_name}` : null].filter(Boolean).join(' · ')}
        </span>
      )}
    </li>
  )
}

/** Riwayat mutasi stok (BR-06 ledger): per barang atau per rentang tanggal WIB. */
export function StockMovementsPage() {
  const profile = useProfile()
  const [product, setProduct] = useState<ProductSummary | null>(null)
  const [range, setRange] = useState<DateRangeValue>({ start: todayInShop(-6), end: todayInShop() })
  const [kind, setKind] = useState('')
  const invalidRange = rangeError(range)

  const input: Record<string, unknown> = {
    ...(product ? { product_id: product.id } : { start_date: range.start, end_date: range.end }),
    ...(kind ? { kind } : {}),
  }
  const enabled = product !== null || invalidRange === null
  const movements = usePagedRpc<StockMovementRow>('list_stock_movements_v1', stockKeys.movements(input), input, enabled)
  const rows = movements.data?.pages.flatMap(p => p.rows) ?? []

  return (
    <section>
      <PageHeader title="Riwayat mutasi stok" description="Setiap barang masuk, terjual, dipindah, dikoreksi, atau dibuang tercatat di sini." />
      <StockNav />
      <div className="ui-card">
        {product ? (
          <div className="button-row">
            <span>Barang: <strong>{productTitle(product)}</strong></span>
            <button type="button" className="ui-button ui-button-secondary" onClick={() => setProduct(null)}>
              Tampilkan semua barang
            </button>
          </div>
        ) : (
          <>
            <DateRangeFields value={range} onChange={setRange} />
            <ProductSearch label="Atau pilih satu barang" onSelect={setProduct} />
          </>
        )}
        <Select label="Jenis mutasi" value={kind} onChange={setKind} options={KIND_OPTIONS} />
      </div>

      {movements.isLoading && <Loading label="Memuat riwayat…" />}
      <ErrorMessage error={movements.error} />
      {movements.data && rows.length === 0 && <EmptyState>Belum ada mutasi yang cocok.</EmptyState>}
      <ul className="card-list">
        {rows.map(row => <MovementItem key={row.id} row={row} showCost={permissions.viewCost(profile)} />)}
      </ul>
      {movements.hasNextPage && (
        <button type="button" className="ui-button ui-button-secondary" disabled={movements.isFetchingNextPage}
          onClick={() => { void movements.fetchNextPage() }}>
          {movements.isFetchingNextPage ? 'Memuat…' : 'Muat lebih banyak'}
        </button>
      )}
    </section>
  )
}
