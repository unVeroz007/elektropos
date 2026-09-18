import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  Card, ConfirmDialog, EmptyState, ErrorMessage, Loading, Notice, PageHeader, RupiahInput, Select, TextInput,
} from '../../components/ui'
import { deleteDraft, getDeviceId, listDrafts, saveDraft, type DraftStatus } from '../../lib/drafts'
import { rupiahOrNull } from '../../lib/numbers'
import { OFFLINE_MESSAGES, useOnlineStatus } from '../../lib/online'
import { readRpc } from '../../lib/rpc'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { BarcodeScanner } from '../scanner'
import { findByBarcode, getProduct, getShopDrawer } from './api'
import {
  acknowledgePriceChanges, addToCart, applyProductRefresh, buildSaleInput, cartIssues, hasPendingPriceReview,
  invoiceDiscountIssue, NO_DISCOUNT, removeLine, snapshotFromBarcode, updateLine,
  type CartLine, type InvoiceDiscount, type ProductSnapshot,
} from './cart'
import { draftLabel, parseCartDraft, type CartDraft, type CartDraftContent } from './cartDraft'
import { CartLineRow } from './CartLineRow'
import { CustomerPicker } from './CustomerPicker'
import { HeldCarts } from './HeldCarts'
import { useSalePreview } from './hooks'
import { buildFinalizeInput, buildPreviewInput, payBlocker, type PaymentForm } from './payment'
import { PaymentPanel } from './PaymentPanel'
import { ProductSearch } from './ProductSearch'
import type { CustomerSummary, DiscountMode, FinalizeResult, SaleInput } from './types'
import { UnknownBarcode } from './UnknownBarcode'
import './sales.css'

type FormState = Omit<PaymentForm, 'tendered'>
type Message = { tone: 'info' | 'success' | 'warning'; text: string }

const EMPTY_FORM: FormState = { method: 'CASH', tenderedText: '', confirmedTotal: null, reference: '', freeReason: '' }

const newId = () => crypto.randomUUID()

/**
 * Kasir (WF-01, FR-POS-01/02). Keranjang menyimpan snapshot barang; total dari server
 * (preview_sale_v1); finalisasi idempoten lewat useCommand dan client_reference_id.
 */
export function CashierPage() {
  const profile = useProfile()
  const canSell = permissions.sell(profile)
  const canDiscount = permissions.giveDiscount(profile)
  const navigate = useNavigate()
  const online = useOnlineStatus()
  const [deviceId] = useState(getDeviceId)

  const [lines, setLines] = useState<CartLine[]>([])
  const [invoiceDiscount, setInvoiceDiscount] = useState<InvoiceDiscount>(NO_DISCOUNT)
  const [customer, setCustomer] = useState<CustomerSummary | null>(null)
  const [formState, setFormState] = useState<FormState>(EMPTY_FORM)
  const [clientRef, setClientRef] = useState(newId)
  const [draftId, setDraftId] = useState<number | null>(null)
  const [drafts, setDrafts] = useState<CartDraft[]>([])
  const [unknownCode, setUnknownCode] = useState<string | null>(null)
  const [message, setMessage] = useState<Message | null>(null)
  const [actionError, setActionError] = useState<unknown>(null)
  const [confirmClear, setConfirmClear] = useState(false)
  const [refreshing, setRefreshing] = useState(false)

  const drawer = useQuery({ queryKey: ['sales', 'drawer'], queryFn: getShopDrawer, enabled: canSell, staleTime: 30_000 })
  const drawerClosed = drawer.data?.open === false
  const pay = useCommand<FinalizeResult, SaleInput>('finalize_sale_v1')
  const { reset: resetPay } = pay

  const form: PaymentForm = { ...formState, tendered: rupiahOrNull(formState.tenderedText) }
  const issues = useMemo(() => cartIssues(lines), [lines])
  const discountIssue = canDiscount ? invoiceDiscountIssue(invoiceDiscount) : null
  const priceReview = hasPendingPriceReview(lines)
  const baseInput = useMemo(() => buildSaleInput({
    lines, canDiscount, invoiceDiscount, customerId: customer?.id ?? null, clientReferenceId: clientRef,
  }), [lines, canDiscount, invoiceDiscount, customer, clientRef])
  const previewInput = useMemo(
    () => (canSell ? buildPreviewInput(baseInput, { ...EMPTY_FORM, method: formState.method, tendered: form.tendered }) : null),
    [canSell, baseInput, formState.method, form.tendered],
  )

  const refreshPrices = useCallback(async () => {
    const ids = [...new Set(lines.map(l => l.productId))]
    if (ids.length === 0) return
    setRefreshing(true)
    try {
      const products = await Promise.all(ids.map(getProduct))
      setLines(current => applyProductRefresh(current, products))
      setMessage({
        tone: 'warning',
        text: 'Harga atau satuan sebagian barang baru saja berubah. Baris bertanda "Harga berubah" sudah memakai '
          + 'harga baru. Belum ada yang tercatat; periksa lalu tekan "Harga sudah saya periksa".',
      })
    } catch (err) {
      setActionError(err)
    } finally {
      setRefreshing(false)
    }
  }, [lines])

  const preview = useSalePreview(previewInput, error => {
    if (error.code === 'PRICE_CHANGED') void refreshPrices()
  })

  // Isi transaksi berubah → operation_id lama tidak boleh dipakai lagi (T01).
  const contentKey = JSON.stringify([baseInput, formState])
  useEffect(() => { resetPay() }, [contentKey, resetPay])

  const handlers = useRef({ refreshPrices, refetchDrawer: drawer.refetch })
  useEffect(() => { handlers.current = { refreshPrices, refetchDrawer: drawer.refetch } })
  useEffect(() => {
    if (pay.error?.code === 'PRICE_CHANGED') void handlers.current.refreshPrices()
    if (pay.error?.code === 'CASH_SESSION_CLOSED') void handlers.current.refetchDrawer()
  }, [pay.error])

  const reloadDrafts = useCallback(async () => {
    try {
      setDrafts(await listDrafts<CartDraftContent>(profile.id, deviceId))
    } catch (err) {
      setActionError(err)
    }
  }, [profile.id, deviceId])
  useEffect(() => { void reloadDrafts() }, [reloadDrafts])

  const addSnapshot = useCallback((snapshot: ProductSnapshot) => {
    setMessage(null)
    setLines(current => addToCart(current, snapshot, newId()))
  }, [])

  const handleScan = useCallback(async (code: string) => {
    setUnknownCode(null)
    setActionError(null)
    try {
      const found = await findByBarcode(code)
      if (found.found) addSnapshot(snapshotFromBarcode(found))
      else setUnknownCode(found.code)
    } catch (err) {
      setActionError(err)
    }
  }, [addSnapshot])

  function startNewCart() {
    setLines([])
    setInvoiceDiscount(NO_DISCOUNT)
    setCustomer(null)
    setFormState(EMPTY_FORM)
    setClientRef(newId())
    setDraftId(null)
    setUnknownCode(null)
    resetPay()
  }

  async function persistDraft(status: DraftStatus, operationId?: string): Promise<number | null> {
    const content: CartDraftContent = {
      kind: 'sale-cart', lines, invoiceDiscount, customer, paymentMethod: formState.method, clientReferenceId: clientRef,
    }
    try {
      const id = await saveDraft(profile.id, deviceId, {
        label: draftLabel(lines, customer), content, status, operation_id: operationId,
      }, draftId ?? undefined)
      setDraftId(id)
      await reloadDrafts()
      return id
    } catch (err) {
      setActionError(err)
      return null
    }
  }

  async function holdCart() {
    setActionError(null)
    const pending = pay.pendingOperationId()
    const id = await persistDraft(pending ? 'unknown' : 'draft', pending ?? undefined)
    if (id === null) return
    startNewCart()
    setMessage({ tone: 'success', text: 'Transaksi ditahan. Lanjutkan kapan saja dari daftar "Transaksi ditahan".' })
  }

  async function removeDraft(draft: CartDraft) {
    if (draft.id === undefined) return
    try {
      await deleteDraft(profile.id, draft.id)
      if (draft.id === draftId) setDraftId(null)
      await reloadDrafts()
    } catch (err) {
      setActionError(err)
    }
  }

  async function resumeDraft(draft: CartDraft) {
    setActionError(null)
    const content = parseCartDraft(draft.content)
    if (!content) {
      setActionError('Transaksi ini tidak dapat dibaca (dibuat oleh versi aplikasi lama). Hapus lalu buat ulang.')
      return
    }
    const uncertain = (draft.status === 'unknown' || draft.status === 'sending') && draft.operation_id
    if (uncertain) {
      try {
        const status = await readRpc<{ found: boolean; result?: FinalizeResult }>('get_operation_v1', {
          command: 'finalize_sale_v1', operation_id: draft.operation_id,
        })
        if (status.found && status.result) {
          if (draft.id !== undefined) await deleteDraft(profile.id, draft.id)
          await reloadDrafts()
          navigate(`/struk/${status.result.entity_id}`)
          return
        }
      } catch (err) {
        setActionError(err)
        return
      }
    }
    setLines(content.lines)
    setInvoiceDiscount(canDiscount ? content.invoiceDiscount : NO_DISCOUNT)
    setCustomer(content.customer)
    setFormState({ ...EMPTY_FORM, method: content.paymentMethod })
    setClientRef(content.clientReferenceId)
    setDraftId(draft.id ?? null)
    setMessage(uncertain
      ? { tone: 'warning', text: 'Pembayaran sebelumnya tidak tercatat di sistem. Periksa uang yang sudah diterima, '
          + 'lalu tekan Bayar. Sistem menolak bila keranjang ini ternyata sudah menjadi nota.' }
      : { tone: 'info', text: 'Transaksi yang ditahan dilanjutkan. Harga diperiksa ulang oleh sistem sebelum bayar.' })
  }

  const blocker = payBlocker({
    canSell, canDiscount, online, lineCount: lines.length, hasIssues: issues.size > 0 || discountIssue !== null,
    priceReview, drawerClosed, preview: preview.state, form,
  })

  async function handlePay() {
    if (blocker || !baseInput || preview.state.status !== 'ready') return
    const input = buildFinalizeInput(baseInput, preview.state.data, form)
    setMessage(null)
    setActionError(null)
    const result = await pay.run(input)
    if (result) {
      if (draftId !== null) {
        try {
          await deleteDraft(profile.id, draftId)
        } catch (err) {
          // Nota sudah tercatat; draf lama hanya perlu dihapus manual.
          setActionError(err)
        }
      }
      startNewCart()
      navigate(`/struk/${result.entity_id}`)
      return
    }
    const pending = pay.pendingOperationId()
    if (pending) await persistDraft('unknown', pending)
  }

  const previewLines = preview.state.status === 'ready' ? preview.state.data.items : null

  return (
    <div className="sl-page">
      <PageHeader title="Kasir" description="Scan atau cari barang, periksa keranjang, lalu bayar."
        actions={(
          <>
            <button type="button" className="ui-button ui-button-secondary" disabled={lines.length === 0 || pay.busy}
              onClick={() => { void holdCart() }}>Tahan dulu</button>
            <button type="button" className="ui-button ui-button-secondary" disabled={lines.length === 0 || pay.busy}
              onClick={() => setConfirmClear(true)}>Kosongkan keranjang</button>
          </>
        )} />

      {!online && <Notice tone="warning">{OFFLINE_MESSAGES.banner} {OFFLINE_MESSAGES.finalize}</Notice>}
      {!canSell && <Notice tone="info">Akun ini hanya dapat melihat. Penjualan dilakukan pemilik atau karyawan.</Notice>}
      {message && <Notice tone={message.tone}>{message.text}</Notice>}
      <ErrorMessage error={actionError} />

      <HeldCarts drafts={drafts} cartEmpty={lines.length === 0} onResume={d => { void resumeDraft(d) }}
        onDelete={removeDraft} />

      <div className="sl-cashier">
        <div className="sl-col">
          <BarcodeScanner onScan={code => { void handleScan(code) }} title="Scan barang"
            description="Kamera HP/laptop atau scanner fisik. Setiap scan menambah satu." />
          {unknownCode && (
            <UnknownBarcode code={unknownCode} canRegister={permissions.manageCatalog(profile)}
              onClose={() => setUnknownCode(null)}
              onRegistered={snapshot => { addSnapshot(snapshot); setUnknownCode(null) }} />
          )}
          <Card title="Cari barang">
            <ProductSearch onAdd={snapshot => addSnapshot(snapshot)} />
          </Card>
        </div>

        <div className="sl-col sl-col-side">
          <Card title={`Keranjang (${lines.length} baris)`}>
            {lines.length === 0
              ? <EmptyState>Keranjang kosong. Scan barang atau cari lewat kolom pencarian.</EmptyState>
              : (
                <ul className="sl-lines" aria-label="Isi keranjang">
                  {lines.map((line, index) => (
                    <CartLineRow key={line.key} line={line} lines={lines} issue={issues.get(line.key) ?? null}
                      preview={previewLines?.[index] ?? null} canDiscount={canDiscount}
                      onChange={patch => setLines(current => updateLine(current, line.key, patch))}
                      onRemove={() => setLines(current => removeLine(current, line.key))} />
                  ))}
                </ul>
              )}
            {refreshing && <Loading label="Memuat harga terbaru…" />}
            {priceReview && (
              <button type="button" className="ui-button ui-button-primary"
                onClick={() => { setLines(acknowledgePriceChanges); setMessage(null) }}>
                Harga sudah saya periksa
              </button>
            )}
            {canDiscount && lines.length > 0 && (
              <InvoiceDiscountFields value={invoiceDiscount} onChange={setInvoiceDiscount} issue={discountIssue} />
            )}
            <CustomerPicker value={customer} onChange={setCustomer} />
          </Card>

          <PaymentPanel preview={preview.state} form={form} canDiscount={canDiscount} drawerClosed={drawerClosed}
            onFormChange={patch => setFormState(current => ({ ...current, ...patch }))}
            blocker={blocker} busy={pay.busy} unknownResult={pay.error?.kind === 'network'}
            error={pay.error && pay.error.code !== 'PRICE_CHANGED' ? pay.error : null}
            onPay={() => { void handlePay() }} onRetryPreview={preview.retry} />
        </div>
      </div>

      <ConfirmDialog open={confirmClear} title="Kosongkan keranjang?" danger confirmLabel="Ya, kosongkan"
        onCancel={() => setConfirmClear(false)}
        onConfirm={() => {
          startNewCart()
          setConfirmClear(false)
        }}>
        <p>Semua barang di keranjang ({lines.length} baris) akan dihapus. Tidak ada yang terjual.</p>
        {draftId !== null && <p>Salinan di daftar “Transaksi ditahan” tetap ada sampai Anda menghapusnya.</p>}
      </ConfirmDialog>
    </div>
  )
}

function InvoiceDiscountFields({ value, onChange, issue }: {
  value: InvoiceDiscount
  onChange: (value: InvoiceDiscount) => void
  issue: string | null
}) {
  const mode: '' | DiscountMode = value.mode ?? ''
  return (
    <div className="sl-discount">
      <Select<'' | DiscountMode> label="Diskon seluruh nota (khusus pemilik)" value={mode}
        onChange={next => onChange({ mode: next || null, text: '' })}
        options={[
          { value: '', label: 'Tanpa diskon nota' },
          { value: 'percent', label: 'Persen (%)' },
          { value: 'amount', label: 'Potongan Rupiah' },
        ]} />
      {mode === 'percent' && (
        <TextInput label="Besar diskon nota (%)" value={value.text} onChange={text => onChange({ ...value, text })}
          placeholder="Contoh: 5" />
      )}
      {mode === 'amount' && (
        <RupiahInput label="Potongan untuk seluruh nota" value={value.text} onChange={text => onChange({ ...value, text })} />
      )}
      {issue && (mode === 'percent' || value.text.trim() === '') && <p className="sl-line-issue" role="alert">{issue}</p>}
    </div>
  )
}
