import { useState, type FormEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'
import { useCommand } from '../../lib/useCommand'
import { formatQuantity } from '../../lib/numbers'
import {
  Card, Checkbox, ChoiceGroup, EmptyState, ErrorMessage, Loading, Notice, PageHeader, QuantityInput, RupiahInput, TextInput,
} from '../../components/ui'
import { CONDITION_LABEL, LOCATION_LABEL } from '../../components/labels'
import { ProductSearch } from '../../components/ProductSearch'
import { productTitle, type ProductSummary } from '../../components/productTypes'
import { stockKeys, type Page, type StockPositionRow } from './api'
import { adjustInErrors, buildAdjustInPayload, type AdjustInState } from './adjustModel'
import { AdjustOutForm, FormFooter, positionText } from './PositionForms'
import { StockNav } from './StockNav'

type Direction = 'IN' | 'OUT'

const EMPTY_IN: Omit<AdjustInState, 'productId' | 'trackSegments'> = {
  location: 'SHOP', condition: 'SALEABLE', qty: '', costMode: 'COST', cost: '', costConfirmed: false,
  zeroReason: '', label: '', capacity: '', reason: '',
}

function AdjustInForm({ product, onDone }: { product: ProductSummary; onDone: (message: string) => void }) {
  const queryClient = useQueryClient()
  const [state, setState] = useState<AdjustInState>({ ...EMPTY_IN, productId: product.id, trackSegments: product.track_segments })
  const [shown, setShown] = useState(false)
  const command = useCommand<{ ok: boolean; document_number: string }, Record<string, unknown>>('adjust_stock_v1')
  const errors = adjustInErrors(state)
  const set = (patch: Partial<AdjustInState>) => { setState(s => ({ ...s, ...patch })); command.reset() }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setShown(true)
    if (errors.length) return
    const result = await command.run(buildAdjustInPayload(state))
    if (result) {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['stock'] }),
        queryClient.invalidateQueries({ queryKey: ['products'] }),
      ])
      onDone(`Stok ${product.name} bertambah ${formatQuantity(state.qty.replace(',', '.'), product.base_unit)}. Dokumen ${result.document_number}.`)
    }
  }

  return (
    <form onSubmit={submit}>
      <ChoiceGroup label="Tempat" value={state.location} onChange={location => set({ location })} options={[
        { value: 'SHOP', label: LOCATION_LABEL.SHOP }, { value: 'FIELD_FATHER', label: LOCATION_LABEL.FIELD_FATHER },
      ]} />
      <ChoiceGroup label="Kondisi" value={state.condition} onChange={condition => set({ condition })} options={[
        { value: 'SALEABLE', label: CONDITION_LABEL.SALEABLE }, { value: 'DAMAGED', label: CONDITION_LABEL.DAMAGED },
      ]} />
      <QuantityInput label="Jumlah ditambah" unit={product.base_unit} value={state.qty} onChange={qty => set({ qty })} />
      {product.track_segments && (
        <div className="form-grid">
          <TextInput label="Label roll/potongan" value={state.label} onChange={label => set({ label })} maxLength={40} />
          <QuantityInput label="Panjang roll asal (boleh kosong)" unit={product.base_unit} value={state.capacity}
            onChange={capacity => set({ capacity })} />
        </div>
      )}
      <ChoiceGroup label="Modal barang yang ditambah" value={state.costMode} onChange={costMode => set({ costMode })} options={[
        { value: 'COST', label: 'Ada modal', description: 'Isi total harga belinya' },
        { value: 'ZERO', label: 'Tanpa modal', description: 'Mis. bonus/temuan; wajib alasan' },
      ]} />
      {state.costMode === 'COST' ? (
        <>
          <RupiahInput label="Total modal untuk jumlah ini" value={state.cost} onChange={cost => set({ cost })} />
          <Checkbox label="Nilai modal ini sudah benar" checked={state.costConfirmed} onChange={costConfirmed => set({ costConfirmed })} />
        </>
      ) : (
        <TextInput label="Alasan tanpa modal" value={state.zeroReason} onChange={zeroReason => set({ zeroReason })} maxLength={500} />
      )}
      <TextInput label="Alasan koreksi" value={state.reason} onChange={reason => set({ reason })} maxLength={500}
        placeholder="Contoh: ditemukan di gudang" />
      <p className="muted">Koreksi tambah bukan pembelian: tidak mengurangi kas dan tidak tercatat sebagai barang masuk.</p>
      <FormFooter errors={shown ? errors : []} error={command.error} busy={command.busy} label="Simpan koreksi tambah" />
    </form>
  )
}

function AdjustOutPicker({ product, onDone }: { product: ProductSummary; onDone: (message: string) => void }) {
  const [position, setPosition] = useState<StockPositionRow | null>(null)
  const positions = useQuery({
    queryKey: stockKeys.positions({ product_id: product.id }),
    queryFn: () => readRpc<Page<StockPositionRow>>('list_stock_positions_v1', { product_id: product.id, limit: 100 }),
  })
  if (positions.isLoading) return <Loading label="Memuat stok barang…" />
  if (position) {
    return (
      <>
        <p><strong>{positionText(position)}</strong></p>
        <AdjustOutForm position={position} onDone={() => onDone(`Koreksi kurang untuk ${positionText(position)} tersimpan.`)} />
      </>
    )
  }
  const rows = positions.data?.rows ?? []
  return (
    <>
      <ErrorMessage error={positions.error} />
      {rows.length === 0 && <EmptyState>Barang ini tidak punya stok untuk dikurangi.</EmptyState>}
      <p>Pilih stok yang dikurangi:</p>
      <ul className="pick-list">
        {rows.map(row => (
          <li key={row.position_id}>
            <button type="button" className="pick-item" onClick={() => setPosition(row)}>
              <strong>{positionText(row)}</strong>
              <span>{formatQuantity(row.qty_base, row.base_unit)}</span>
            </button>
          </li>
        ))}
      </ul>
    </>
  )
}

/** Koreksi stok dengan arah jelas: Tambah atau Kurang (T05, BR-06). */
export function StockAdjustPage() {
  const [direction, setDirection] = useState<Direction>('OUT')
  const [product, setProduct] = useState<ProductSummary | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  function done(text: string) {
    setMessage(text)
    setProduct(null)
  }

  return (
    <section className="narrow-page">
      <PageHeader title="Koreksi stok" description="Untuk selisih yang ditemukan di luar hitung stok. Barang rusak dibuang lewat daftar Posisi stok." />
      <StockNav />
      {message && <Notice tone="success">{message}</Notice>}
      <ChoiceGroup label="Arah koreksi" value={direction} onChange={d => { setDirection(d); setProduct(null); setMessage(null) }} options={[
        { value: 'OUT', label: 'Kurangi stok', description: 'Barang kurang dari catatan' },
        { value: 'IN', label: 'Tambah stok', description: 'Barang lebih dari catatan' },
      ]} />
      <Card title={product ? productTitle(product) : 'Pilih barang'}
        actions={product && <button type="button" className="ui-button ui-button-secondary" onClick={() => setProduct(null)}>Ganti barang</button>}>
        {!product && <ProductSearch onSelect={p => { setProduct(p); setMessage(null) }} withScanner />}
        {product && direction === 'IN' && <AdjustInForm key={product.id} product={product} onDone={done} />}
        {product && direction === 'OUT' && <AdjustOutPicker key={product.id} product={product} onDone={done} />}
      </Card>
    </section>
  )
}
