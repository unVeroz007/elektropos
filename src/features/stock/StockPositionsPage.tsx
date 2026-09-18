import { useRef, useState } from 'react'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { Badge, EmptyState, ErrorMessage, Loading, PageHeader, Select, TextInput } from '../../components/ui'
import { CONDITION_LABEL, LOCATION_LABEL, labelOf } from '../../components/labels'
import { useDebounced } from '../../components/useDebounced'
import { stockKeys, usePagedRpc, type StockPositionRow } from './api'
import { PositionActionCard, type PositionAction } from './PositionForms'
import { StockNav } from './StockNav'

function PositionItem({ row, canEdit, showCost, onAction }: {
  row: StockPositionRow
  canEdit: boolean
  showCost: boolean
  onAction: (action: PositionAction) => void
}) {
  return (
    <li className="list-card">
      <span className="list-card-title">{row.name}</span>
      <span className="muted">Kode {row.sku}{row.label ? ` · Label ${row.label}` : ''} · masuk {formatDateTime(row.lot_posted_at)}</span>
      <span>
        <Badge tone={row.location === 'SHOP' ? 'info' : 'warning'}>{labelOf(LOCATION_LABEL, row.location)}</Badge>{' '}
        <Badge tone={row.condition === 'SALEABLE' ? 'success' : 'danger'}>{labelOf(CONDITION_LABEL, row.condition)}</Badge>
        {row.track_segments && <> {row.sealed ? <Badge tone="success">segel</Badge> : <Badge>sudah dipotong</Badge>}</>}
      </span>
      <span className="list-card-money">
        {formatQuantity(row.qty_base, row.base_unit)}
        {row.segment_capacity && row.track_segments && ` dari ${formatQuantity(row.segment_capacity, row.base_unit)}`}
      </span>
      {showCost && row.lot_remaining_cost && <span className="muted">Sisa modal lot {formatRupiah(row.lot_remaining_cost)}</span>}
      {canEdit && (
        <span className="button-row">
          <button type="button" className="ui-button ui-button-secondary" onClick={() => onAction('transfer')}>Pindah</button>
          <button type="button" className="ui-button ui-button-secondary" onClick={() => onAction('adjust')}>Koreksi kurang</button>
          <button type="button" className="ui-button ui-button-secondary" onClick={() => onAction('dispose')}>Buang</button>
        </span>
      )}
    </li>
  )
}

export function StockPositionsPage() {
  const profile = useProfile()
  const canEdit = permissions.manageStock(profile)
  const [query, setQuery] = useState('')
  const [location, setLocation] = useState('')
  const [condition, setCondition] = useState('')
  const [selected, setSelected] = useState<{ row: StockPositionRow; action: PositionAction } | null>(null)
  const top = useRef<HTMLDivElement>(null)
  const debounced = useDebounced(query.trim())
  const input = {
    ...(debounced ? { query: debounced } : {}), ...(location ? { location } : {}), ...(condition ? { condition } : {}),
  }
  const positions = usePagedRpc<StockPositionRow>('list_stock_positions_v1', stockKeys.positions(input), input)
  const rows = positions.data?.pages.flatMap(p => p.rows) ?? []

  function choose(row: StockPositionRow, action: PositionAction) {
    setSelected({ row, action })
    top.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  return (
    <section>
      <PageHeader title="Stok" description="Stok per barang, tempat, dan kondisi. Roll kabel tampil satu per satu." />
      <StockNav />
      <div ref={top}>
        {selected && (
          <PositionActionCard key={`${selected.row.position_id}-${selected.action}`} position={selected.row}
            action={selected.action} onDone={() => setSelected(null)} />
        )}
      </div>
      <div className="form-grid">
        <TextInput type="search" label="Cari awal nama, kode persis, atau label roll" value={query} onChange={setQuery} maxLength={120} />
        <Select label="Tempat" value={location} onChange={setLocation} options={[
          { value: '', label: 'Semua tempat' }, { value: 'SHOP', label: LOCATION_LABEL.SHOP }, { value: 'FIELD_FATHER', label: LOCATION_LABEL.FIELD_FATHER },
        ]} />
        <Select label="Kondisi" value={condition} onChange={setCondition} options={[
          { value: '', label: 'Semua kondisi' }, { value: 'SALEABLE', label: CONDITION_LABEL.SALEABLE }, { value: 'DAMAGED', label: CONDITION_LABEL.DAMAGED },
        ]} />
      </div>
      {positions.isLoading && <Loading label="Memuat stok…" />}
      <ErrorMessage error={positions.error} />
      {positions.data && rows.length === 0 && <EmptyState>Tidak ada stok yang cocok.</EmptyState>}
      <ul className="card-list">
        {rows.map(row => (
          <PositionItem key={row.position_id} row={row} canEdit={canEdit} showCost={permissions.viewCost(profile)}
            onAction={action => choose(row, action)} />
        ))}
      </ul>
      {positions.hasNextPage && (
        <button type="button" className="ui-button ui-button-secondary" disabled={positions.isFetchingNextPage}
          onClick={() => { void positions.fetchNextPage() }}>
          {positions.isFetchingNextPage ? 'Memuat…' : 'Muat lebih banyak'}
        </button>
      )}
    </section>
  )
}
