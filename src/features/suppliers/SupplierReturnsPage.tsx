import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import Decimal from 'decimal.js'
import { useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Badge, Card, Checkbox, ChoiceGroup, ConfirmDialog, EmptyState, ErrorMessage, Loading, Notice, PageHeader, QuantityInput,
  RupiahInput, Select, SummaryRow, TextArea, TextInput,
} from '../../components/ui'
import {
  CASHBOX_LABEL, CONDITION_LABEL, LOCATION_LABEL, SUPPLIER_RETURN_OUTCOME_LABEL, SUPPLIER_RETURN_STATUS_LABEL, labelOf,
} from '../../components/labels'
import { ProductSearch } from '../../components/ProductSearch'
import type { ProductDetail, ProductSummary } from '../../components/productTypes'
import { useDebounced } from '../../components/useDebounced'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { IntakeLineCard } from '../stock/IntakeLineCard'
import { newIntakeLine, type IntakeLine } from '../stock/intakeModel'
import { stockKeys, type Page, type StockPositionRow } from '../stock/api'
import { catalogKeys } from '../catalog/api'
import { supplierKeys, useSuppliers, type SupplierReturn } from './api'
import {
  createReturnPayload, EMPTY_SETTLE, OUTCOMES, pickIssue, replacementLinesFor, settlementPreview, settlePayload,
  type Outcome, type ReturnPick, type SettleForm,
} from './returnModel'

type Unit = { id: string; label: string; factor_base: string }

function useInvalidate() {
  const queryClient = useQueryClient()
  return () => Promise.all([
    queryClient.invalidateQueries({ queryKey: supplierKeys.all }),
    queryClient.invalidateQueries({ queryKey: stockKeys.all }),
    queryClient.invalidateQueries({ queryKey: ['cash'] }),
  ])
}

/** Pilih posisi stok (toko/dibawa ayah, layak/rusak) yang akan dikembalikan. */
function PositionPicker({ onPick, picked }: { onPick: (pick: ReturnPick) => void; picked: string[] }) {
  const [query, setQuery] = useState('')
  const debounced = useDebounced(query.trim())
  const positions = useQuery({
    queryKey: stockKeys.positions({ query: debounced, purpose: 'supplier-return' }),
    queryFn: () => readRpc<Page<StockPositionRow>>('list_stock_positions_v1', { query: debounced, limit: 30 }),
    enabled: debounced.length >= 2,
  })
  const rows = (positions.data?.rows ?? []).filter(r => !picked.includes(r.position_id))
  return (
    <div>
      <TextInput type="search" label="Cari barang yang dikembalikan" value={query} onChange={setQuery} maxLength={120}
        hint="Barang rusak juga tampil di sini." />
      {positions.isFetching && <Loading label="Mencari…" />}
      <ErrorMessage error={positions.error} />
      {positions.data && rows.length === 0 && <EmptyState>Tidak ada stok yang cocok.</EmptyState>}
      <ul className="card-list">
        {rows.map(r => (
          <li key={r.position_id} className="list-card">
            <button type="button" className="list-card-link" onClick={() => onPick({
              positionId: r.position_id, version: r.version, name: r.name, label: r.label, baseUnit: r.base_unit,
              quantityStep: r.quantity_step, available: r.qty_base, qty: r.qty_base,
            })}>
              <span className="list-card-title">{r.name}{r.label ? ` · ${r.label}` : ''}</span>
              <span className="muted">
                {labelOf(LOCATION_LABEL, r.location)} · {labelOf(CONDITION_LABEL, r.condition)} · {formatQuantity(r.qty_base, r.base_unit)}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}

function CreateReturnCard({ initialSupplierId, onDone }: { initialSupplierId: string; onDone: () => void }) {
  const invalidate = useInvalidate()
  const suppliers = useSuppliers()
  const [supplierId, setSupplierId] = useState(initialSupplierId)
  const [reason, setReason] = useState('')
  const [picks, setPicks] = useState<ReturnPick[]>([])
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useCommand<{ document_number: string; claim_value: string }, Record<string, unknown>>('create_supplier_return_v1')
  const built = createReturnPayload(supplierId, reason, picks)
  const change = () => command.reset()

  async function submit() {
    if (!('payload' in built)) return
    const result = await command.run(built.payload)
    setConfirming(false)
    if (result) { await invalidate(); onDone() }
  }

  return (
    <Card title="Buat retur ke distributor">
      <Select label="Distributor" value={supplierId} onChange={v => { setSupplierId(v); change() }} options={[
        { value: '', label: 'Pilih distributor' },
        ...(suppliers.data ?? []).map(s => ({ value: s.id, label: s.name })),
      ]} />
      <PositionPicker picked={picks.map(p => p.positionId)} onPick={pick => { setPicks(ps => [...ps, pick]); change() }} />
      {picks.length > 0 && (
        <ul className="card-list">
          {picks.map(pick => (
            <li key={pick.positionId} className="list-card">
              <span className="list-card-title">{pick.name}{pick.label ? ` · ${pick.label}` : ''}</span>
              <QuantityInput label="Jumlah dikembalikan" unit={pick.baseUnit} value={pick.qty}
                onChange={qty => { setPicks(ps => ps.map(p => p.positionId === pick.positionId ? { ...p, qty } : p)); change() }} />
              {touched && pickIssue(pick) && <p className="field-error">{pickIssue(pick)}</p>}
              <span className="button-row">
                <button type="button" className="ui-button ui-button-secondary"
                  onClick={() => { setPicks(ps => ps.filter(p => p.positionId !== pick.positionId)); change() }}>Batal pilih</button>
              </span>
            </li>
          ))}
        </ul>
      )}
      <TextArea label="Alasan retur" value={reason} onChange={v => { setReason(v); change() }} rows={2} maxLength={500}
        placeholder="Contoh: lampu mati sejak dari dus" />
      {touched && 'issue' in built && <ErrorMessage error={built.issue} />}
      <ErrorMessage error={command.error} />
      <div className="button-row">
        <button type="button" className="ui-button ui-button-primary" disabled={command.busy}
          onClick={() => { setTouched(true); if ('payload' in built) setConfirming(true) }}>Keluarkan dari stok</button>
        <button type="button" className="ui-button ui-button-secondary" onClick={onDone}>Batal</button>
      </div>
      <ConfirmDialog open={confirming} title="Kembalikan barang ke distributor?" confirmLabel="Ya, keluarkan dari stok"
        busy={command.busy} onConfirm={() => { void submit() }} onCancel={() => setConfirming(false)}>
        <p>Barang keluar dari stok dan dicatat sebagai klaim ke distributor senilai modalnya. Selesaikan klaim setelah distributor menjawab.</p>
      </ConfirmDialog>
    </Card>
  )
}

function ReplacementLines({ lines, initialUnits, onChange }: {
  lines: IntakeLine[]
  initialUnits: Record<string, Unit[]>
  onChange: (lines: IntakeLine[]) => void
}) {
  const [units, setUnits] = useState<Record<string, Unit[]>>(initialUnits)
  function add(product: ProductSummary, unitId?: string) {
    setUnits(u => ({ ...u, [product.id]: product.units }))
    onChange([...lines, newIntakeLine(product, unitId)])
  }
  return (
    <div>
      <p className="muted">
        Terisi otomatis dengan barang dan jumlah yang dikembalikan. Ubah bila barang pengganti berbeda.
        Modal barang pengganti otomatis sama dengan nilai klaim, dibagi menurut jumlahnya.
      </p>
      {lines.map(line => (
        <IntakeLineCard key={line.key} line={line} units={units[line.productId] ?? []} withCost={false}
          onChange={next => onChange(lines.map(l => l.key === next.key ? next : l))}
          onRemove={() => onChange(lines.filter(l => l.key !== line.key))} />
      ))}
      <ProductSearch label="Tambah barang pengganti" onSelect={add} />
    </div>
  )
}

function SettleCard({ item, onDone }: { item: SupplierReturn; onDone: () => void }) {
  const invalidate = useInvalidate()
  const [form, setForm] = useState<SettleForm>({ ...EMPTY_SETTLE, amount: new Decimal(item.claim_value).toDecimalPlaces(0, Decimal.ROUND_HALF_UP).toFixed(0) })
  const [prefilled, setPrefilled] = useState(false)
  const productIds = [...new Set(item.items.map(i => i.product_id))]
  const products = useQueries({
    queries: productIds.map(id => ({
      queryKey: catalogKeys.detail(id),
      queryFn: () => readRpc<ProductDetail>('get_product_v1', { product_id: id }),
    })),
  })
  const loadedProducts = products.every(p => p.data) ? products.map(p => p.data as ProductDetail) : null
  const productError = products.find(p => p.error)?.error ?? null
  // Isi barang pengganti sekali setelah data barang termuat; perubahan pengguna tidak ditimpa.
  useEffect(() => {
    if (prefilled || !loadedProducts) return
    setPrefilled(true)
    setForm(f => (f.lines.length ? f : { ...f, lines: replacementLinesFor(item.items, loadedProducts) }))
  }, [prefilled, loadedProducts, item.items])
  const initialUnits = Object.fromEntries((loadedProducts ?? []).map(p => [p.id, p.units]))
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useCommand<{ settlement_difference: string }, Record<string, unknown>>('settle_supplier_return_v1')
  const built = settlePayload(item.id, item.version, form)
  const preview = settlementPreview(item.claim_value, form)
  const set = (patch: Partial<SettleForm>) => { setForm(f => ({ ...f, ...patch })); command.reset() }

  async function submit() {
    if (!('payload' in built)) return
    const result = await command.run(built.payload)
    setConfirming(false)
    if (result) { await invalidate(); onDone() }
  }

  return (
    <div className="subform">
      <ChoiceGroup<Outcome> label="Jawaban distributor" value={form.outcome} onChange={outcome => set({ outcome })}
        options={OUTCOMES.map(value => ({
          value, label: labelOf(SUPPLIER_RETURN_OUTCOME_LABEL, value),
        }))} />
      {(form.outcome === 'REFUND' || form.outcome === 'CREDIT') && (
        <RupiahInput label={form.outcome === 'REFUND' ? 'Uang yang dikembalikan' : 'Nilai kredit'} value={form.amount}
          onChange={amount => set({ amount })} />
      )}
      {form.outcome === 'REFUND' && (
        <>
          <ChoiceGroup label="Diterima lewat" value={form.method} onChange={method => set({ method })} options={[
            { value: 'CASH', label: 'Tunai' }, { value: 'TRANSFER', label: 'Transfer' }, { value: 'QRIS', label: 'QRIS' },
          ]} />
          {form.method === 'CASH' ? (
            <ChoiceGroup label="Uang masuk ke" value={form.cashbox} onChange={cashbox => set({ cashbox })} options={[
              { value: 'SHOP_DRAWER', label: CASHBOX_LABEL.SHOP_DRAWER }, { value: 'FATHER_WALLET', label: CASHBOX_LABEL.FATHER_WALLET },
            ]} />
          ) : (
            <Checkbox label="Saya sudah memastikan uang masuk" checked={form.confirmed} onChange={confirmed => set({ confirmed })} />
          )}
        </>
      )}
      {form.outcome !== 'REJECTED' && form.outcome !== 'REPLACEMENT' && (
        <TextInput label="Nomor referensi (boleh kosong)" value={form.reference} onChange={reference => set({ reference })} maxLength={100} />
      )}
      {form.outcome === 'REPLACEMENT' && !prefilled && !productError && <Loading label="Menyiapkan barang pengganti…" />}
      {form.outcome === 'REPLACEMENT' && <ErrorMessage error={productError} />}
      {form.outcome === 'REPLACEMENT' && prefilled && (
        <ReplacementLines lines={form.lines} initialUnits={initialUnits} onChange={lines => set({ lines })} />
      )}
      <TextArea label={form.outcome === 'REJECTED' ? 'Alasan ditolak (wajib)' : 'Catatan (boleh kosong)'} value={form.note}
        onChange={note => set({ note })} rows={2} maxLength={500} />
      {preview && (
        <SummaryRow label="Selisih terhadap nilai klaim" value={formatRupiah(preview)} tone={preview.isNegative() ? 'danger' : 'success'} />
      )}
      {touched && 'issue' in built && <ErrorMessage error={built.issue} />}
      <ErrorMessage error={command.error} />
      <div className="button-row">
        <button type="button" className="ui-button ui-button-primary" disabled={command.busy}
          onClick={() => { setTouched(true); if ('payload' in built) setConfirming(true) }}>Selesaikan klaim</button>
        <button type="button" className="ui-button ui-button-secondary" onClick={onDone}>Batal</button>
      </div>
      <ConfirmDialog open={confirming} title="Selesaikan klaim?" confirmLabel="Ya, selesaikan" busy={command.busy}
        onConfirm={() => { void submit() }} onCancel={() => setConfirming(false)}>
        <p>{labelOf(SUPPLIER_RETURN_OUTCOME_LABEL, form.outcome)} untuk klaim {item.document_number}. Tidak dapat diubah lagi.</p>
      </ConfirmDialog>
    </div>
  )
}

function ReturnItem({ item, canSettle }: { item: SupplierReturn; canSettle: boolean }) {
  const [settling, setSettling] = useState(false)
  return (
    <li className="list-card">
      <span className="list-card-title">{item.document_number} · {item.supplier_name}</span>
      <span>
        <Badge tone={item.status === 'PENDING' ? 'warning' : 'success'}>{labelOf(SUPPLIER_RETURN_STATUS_LABEL, item.status)}</Badge>{' '}
        {item.outcome && <Badge tone="info">{labelOf(SUPPLIER_RETURN_OUTCOME_LABEL, item.outcome)}</Badge>}
      </span>
      <span className="muted">{formatDateTime(item.created_at)} · {item.reason}</span>
      <ul className="plain-list">
        {item.items.map(i => (
          <li key={i.line_no}>{i.name}{i.position_label ? ` (${i.position_label})` : ''} · {formatQuantity(i.qty_base, i.unit)} · {labelOf(CONDITION_LABEL, i.condition)}</li>
        ))}
      </ul>
      <SummaryRow label="Nilai klaim (modal)" value={formatRupiah(item.claim_value)} />
      {item.status === 'SETTLED' && (
        <>
          {item.settled_amount && <SummaryRow label="Diterima" value={formatRupiah(item.settled_amount)} />}
          {item.settlement_difference && (
            <SummaryRow label="Selisih" value={formatRupiah(item.settlement_difference)}
              tone={item.settlement_difference.startsWith('-') ? 'danger' : 'success'} />
          )}
          {item.replacement_document_number && <span className="muted">Barang pengganti: dokumen {item.replacement_document_number}</span>}
          {item.settlement_note && <span className="muted">{item.settlement_note}</span>}
        </>
      )}
      {canSettle && item.status === 'PENDING' && (settling
        ? <SettleCard key={item.version} item={item} onDone={() => setSettling(false)} />
        : <span className="button-row">
            <button type="button" className="ui-button ui-button-primary" onClick={() => setSettling(true)}>Catat jawaban distributor</button>
          </span>)}
    </li>
  )
}

/** Retur barang ke distributor dan penyelesaian klaimnya (D5). */
export function SupplierReturnsPage() {
  const profile = useProfile()
  const canEdit = permissions.manageStock(profile)
  const [params] = useSearchParams()
  const initialSupplier = params.get('distributor') ?? ''
  const [creating, setCreating] = useState(false)
  const [status, setStatus] = useState<'' | 'PENDING' | 'SETTLED'>('PENDING')
  const filter = { ...(status ? { status } : {}), ...(initialSupplier ? { supplier_id: initialSupplier } : {}), limit: '50' }
  const returns = useQuery({
    queryKey: supplierKeys.returns(filter),
    queryFn: () => readRpc<{ items: SupplierReturn[] }>('list_supplier_returns_v1', filter),
  })
  const items = returns.data?.items ?? []

  return (
    <section>
      <PageHeader title="Retur ke distributor" description="Barang rusak/cacat dikembalikan ke distributor, lalu dicatat jawabannya."
        actions={canEdit && !creating
          ? <button type="button" className="ui-button ui-button-primary" onClick={() => setCreating(true)}>+ Retur baru</button>
          : undefined} />
      {creating && <CreateReturnCard initialSupplierId={initialSupplier} onDone={() => setCreating(false)} />}
      {!canEdit && <Notice tone="info">Akun ini hanya dapat melihat.</Notice>}
      <Select label="Tampilkan" value={status} onChange={setStatus} options={[
        { value: 'PENDING', label: 'Belum selesai' }, { value: 'SETTLED', label: 'Sudah selesai' }, { value: '', label: 'Semua' },
      ]} />
      {returns.isLoading && <Loading label="Memuat retur…" />}
      <ErrorMessage error={returns.error} />
      {returns.data && items.length === 0 && <EmptyState>Tidak ada retur ke distributor.</EmptyState>}
      <ul className="card-list">
        {items.map(item => <ReturnItem key={item.id} item={item} canSettle={canEdit} />)}
      </ul>
    </section>
  )
}
