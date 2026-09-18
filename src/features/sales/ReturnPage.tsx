import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Card, Checkbox, ChoiceGroup, ConfirmDialog, ErrorMessage, Loading, Notice, PageHeader, QuantityInput, SummaryRow,
  TextArea, TextInput,
} from '../../components/ui'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { getInvoice, getProduct, getShopDrawer } from './api'
import { DISPOSITION_LABEL, PAYMENT_LABEL } from './labels'
import { itemName } from './receipt'
import {
  allocationRemaining, buildReturnInput, EMPTY_RETURN_LINE, estimateRefund, returnableSell, returnLineIssue,
  type ReturnFormState, type ReturnLineForm, type ReturnProductInfo,
} from './returns'
import type { Disposition, InvoiceItem, PaymentMethod, ReturnInput, ReturnResult } from './types'
import './sales.css'

const DISPOSITIONS = (Object.keys(DISPOSITION_LABEL) as Disposition[])
  .map(value => ({ value, label: DISPOSITION_LABEL[value].label, description: DISPOSITION_LABEL[value].description }))

const REFUND_METHODS = (Object.keys(PAYMENT_LABEL) as PaymentMethod[]).map(value => ({ value, label: PAYMENT_LABEL[value] }))

/** Retur penjualan (FR-POS-04, BR-08). Hanya pemilik; nilai uang kembali final dihitung server. */
export function ReturnPage() {
  const { invoiceId = '' } = useParams<{ invoiceId: string }>()
  const profile = useProfile()
  const invoice = useQuery({ queryKey: ['sales', 'invoice', invoiceId], queryFn: () => getInvoice(invoiceId), enabled: invoiceId !== '' })

  if (!permissions.processReturn(profile)) {
    return <Notice tone="warning">Retur hanya dapat diproses oleh pemilik toko.</Notice>
  }
  if (invoice.isPending) return <Loading label="Memuat nota…" />
  if (invoice.isError) {
    return (
      <div className="sl-page">
        <ErrorMessage error={invoice.error} />
        <Link className="ui-button ui-button-secondary" to="/riwayat">Kembali ke riwayat</Link>
      </div>
    )
  }
  if (invoice.data.kind !== 'SALE') {
    return <Notice tone="warning">Nota servis dikoreksi dari halaman tiket servis, bukan lewat retur barang.</Notice>
  }
  return <ReturnForm key={invoice.data.id} invoiceId={invoice.data.id} items={invoice.data.items} number={invoice.data.number}
    postedAt={invoice.data.posted_at} />
}

function ReturnForm({ invoiceId, items, number, postedAt }: {
  invoiceId: string
  items: InvoiceItem[]
  number: string
  postedAt: string
}) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const returnable = items.filter(i => i.product_id && Number(i.returnable_qty) > 0)
  const productIds = [...new Set(returnable.map(i => i.product_id as string))]
  const productQueries = useQueries({
    queries: productIds.map(id => ({ queryKey: ['sales', 'product', id], queryFn: () => getProduct(id), staleTime: 60_000 })),
  })
  const drawer = useQuery({ queryKey: ['sales', 'drawer'], queryFn: getShopDrawer, staleTime: 30_000 })
  const command = useCommand<ReturnResult, ReturnInput & Record<string, unknown>>('return_sale_v1')

  const [state, setState] = useState<ReturnFormState>({ forms: {}, reason: '', refundMethod: '', refundReference: '' })
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)

  const products: Record<string, ReturnProductInfo> = {}
  productQueries.forEach((q, index) => {
    if (q.data) products[productIds[index]] = q.data
  })
  const productsLoading = productQueries.some(q => q.isPending)
  const productsError = productQueries.find(q => q.isError)?.error

  const refund = estimateRefund(items, state.forms)
  const built = buildReturnInput(invoiceId, items, products, state)
  const cashBlocked = state.refundMethod === 'CASH' && refund.greaterThan(0) && drawer.data?.open === false

  function patchLine(itemId: string, patch: Partial<ReturnLineForm>) {
    command.reset()
    setState(s => ({ ...s, forms: { ...s.forms, [itemId]: { ...(s.forms[itemId] ?? EMPTY_RETURN_LINE), ...patch } } }))
  }
  function patchState(patch: Partial<ReturnFormState>) {
    command.reset()
    setState(s => ({ ...s, ...patch }))
  }

  function review() {
    setTouched(true)
    if ('input' in built && !cashBlocked) setConfirming(true)
  }

  async function submit() {
    if (!('input' in built)) return
    const result = await command.run(built.input)
    setConfirming(false)
    if (result) {
      await queryClient.invalidateQueries({ queryKey: ['sales'] })
      navigate(`/struk/${invoiceId}`, { replace: true })
    }
  }

  if (returnable.length === 0) {
    return (
      <div className="sl-page">
        <PageHeader title={`Retur nota ${number}`} />
        <Notice tone="info">Semua barang di nota ini sudah diretur atau bukan barang stok.</Notice>
        <Link className="ui-button ui-button-secondary" to={`/struk/${invoiceId}`}>Kembali ke struk</Link>
      </div>
    )
  }

  return (
    <div className="sl-page">
      <PageHeader title={`Retur nota ${number}`} description={`Nota ${formatDateTime(postedAt)}. Pilih barang yang dikembalikan pembeli.`}
        actions={<Link className="ui-button ui-button-secondary" to={`/struk/${invoiceId}`}>Batal</Link>} />
      {productsLoading && <Loading label="Memuat data barang…" />}
      <ErrorMessage error={productsError} />

      <Card title="Barang yang dikembalikan">
        <ul className="sl-return-items">
          {returnable.map(item => (
            <ReturnItemRow key={item.id} item={item} form={state.forms[item.id] ?? EMPTY_RETURN_LINE}
              product={item.product_id ? products[item.product_id] : undefined} showIssue={touched}
              onChange={patch => patchLine(item.id, patch)} />
          ))}
        </ul>
      </Card>

      <Card title="Alasan & uang kembali">
        <TextArea label="Alasan retur" value={state.reason} onChange={reason => patchState({ reason })} required maxLength={500}
          placeholder="Contoh: lampu mati saat dicoba di rumah" />
        <SummaryRow strong label="Perkiraan uang kembali" value={formatRupiah(refund)} />
        <p className="sl-muted">Dihitung dari harga bersih di nota asal (setelah diskon), bukan harga sekarang. Angka pasti dari sistem.</p>
        {refund.greaterThan(0) && (
          <>
            <ChoiceGroup<PaymentMethod | ''> label="Cara uang dikembalikan" value={state.refundMethod}
              onChange={refundMethod => patchState({ refundMethod })} options={REFUND_METHODS} />
            {state.refundMethod !== '' && state.refundMethod !== 'CASH' && (
              <TextInput label="Nomor referensi transfer (boleh kosong)" value={state.refundReference} maxLength={100}
                onChange={refundReference => patchState({ refundReference })} />
            )}
          </>
        )}
        {cashBlocked && (
          <Notice tone="warning">Laci kas belum dibuka. <Link to="/kas">Buka kas</Link> atau pilih cara lain.</Notice>
        )}
        {touched && 'issue' in built && <ErrorMessage error={built.issue} />}
        <ErrorMessage error={command.error} />
        <button type="button" className="ui-button ui-button-primary ui-button-large" disabled={command.busy || productsLoading}
          onClick={review}>Periksa & proses retur</button>
      </Card>

      <ConfirmDialog open={confirming} title="Proses retur?" confirmLabel="Ya, proses retur" busy={command.busy}
        onConfirm={() => { void submit() }} onCancel={() => setConfirming(false)}>
        <p>Barang dikembalikan sesuai pilihan dan tidak bisa dibatalkan.</p>
        {refund.greaterThan(0) && state.refundMethod !== '' && (
          <p>Serahkan sekitar <strong>{formatRupiah(refund)}</strong> ke pembeli ({PAYMENT_LABEL[state.refundMethod]}).</p>
        )}
      </ConfirmDialog>
    </div>
  )
}

function ReturnItemRow({ item, form, product, showIssue, onChange }: {
  item: InvoiceItem
  form: ReturnLineForm
  product: ReturnProductInfo | undefined
  showIssue: boolean
  onChange: (patch: Partial<ReturnLineForm>) => void
}) {
  const unit = item.unit_label ?? product?.base_unit ?? ''
  const issue = product ? returnLineIssue(form, item, product) : null
  const allocations = item.cost_allocations ?? []
  return (
    <li className={`sl-return-item${form.selected ? ' is-selected' : ''}`}>
      <Checkbox label={`${itemName(item)} — bisa dikembalikan ${formatQuantity(returnableSell(item), unit)}`}
        checked={form.selected} onChange={selected => onChange({ selected })} />
      {form.selected && (
        <div className="sl-return-detail">
          <QuantityInput label="Jumlah dikembalikan" unit={unit} value={form.qtyText} onChange={qtyText => onChange({ qtyText })} />
          <ChoiceGroup label="Kondisi barang" value={form.disposition} options={DISPOSITIONS}
            onChange={disposition => onChange({ disposition })} />
          {form.disposition !== 'NONE' && product?.track_segments && (
            <TextInput label="Label potongan baru (boleh kosong)" value={form.label} maxLength={40}
              onChange={label => onChange({ label })} hint="Potongan yang kembali dicatat sebagai potongan baru, tidak disambung ke roll asal." />
          )}
          {form.disposition !== 'NONE' && allocations.length > 1 && (
            <>
              <Checkbox label="Saya tahu barang ini berasal dari roll/stok mana" checked={form.manualAllocation}
                onChange={manualAllocation => onChange({ manualAllocation })} />
              {form.manualAllocation && (
                <div className="sl-alloc">
                  {allocations.map(a => (
                    <QuantityInput key={a.id} unit={product?.base_unit}
                      label={`Dari ${a.origin_label ?? 'stok'} (masuk ${formatDateTime(a.lot_posted_at)}, sisa ${formatQuantity(allocationRemaining(a))})`}
                      value={form.allocationTexts[a.id] ?? ''}
                      onChange={text => onChange({ allocationTexts: { ...form.allocationTexts, [a.id]: text } })} />
                  ))}
                </div>
              )}
            </>
          )}
          {showIssue && issue && <p className="sl-line-issue" role="alert">{issue}</p>}
        </div>
      )}
    </li>
  )
}
