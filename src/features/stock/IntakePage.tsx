import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useCommand } from '../../lib/useCommand'
import { formatQuantity, formatRupiah, todayInShop } from '../../lib/numbers'
import {
  Card, ChoiceGroup, ConfirmDialog, EmptyState, ErrorMessage, Notice, PageHeader, Select, SummaryRow, TextInput,
} from '../../components/ui'
import { CASHBOX_LABEL, PAYMENT_METHOD_LABEL } from '../../components/labels'
import { ProductSearch } from '../../components/ProductSearch'
import type { ProductSummary } from '../../components/productTypes'
import { useSuppliers } from '../suppliers/api'
import { IntakeLineCard } from './IntakeLineCard'
import { IntakePaymentFields } from './IntakePaymentFields'
import {
  buildIntakePayload, lineErrors, newIntakeLine, paymentErrors, rollCount, totalCost,
  type IntakeHeader, type IntakeLine, type IntakeMode, type IntakePayment,
} from './intakeModel'

type Unit = { id: string; label: string; factor_base: string }
type PostResult = {
  ok: boolean
  document_number: string
  total_cost: string
  lines: { line_no: number; product_id: string; qty_base: string; positions?: { label: string; qty_base: string; sealed: boolean }[] }[]
}

const EMPTY_PAYMENT: IntakePayment = { method: 'CASH', cashbox: 'SHOP_DRAWER', reference: '', confirmed: false }

function ResultCard({ result, mode, onNew }: { result: PostResult; mode: IntakeMode; onNew: () => void }) {
  const labels = result.lines.flatMap(l => l.positions ?? [])
  return (
    <Card title={mode === 'OPENING' ? 'Stok awal tersimpan' : 'Barang masuk tersimpan'}>
      <Notice tone="success">Nomor dokumen {result.document_number}. Stok sudah bertambah.</Notice>
      {mode === 'RECEIPT' && <SummaryRow strong label="Total dibayar" value={formatRupiah(result.total_cost)} />}
      {labels.length > 0 && (
        <>
          <h3>Tulis label ini pada tiap roll</h3>
          <ul className="plain-list label-list">
            {labels.map(p => <li key={p.label}><strong>{p.label}</strong> · {formatQuantity(p.qty_base)} {p.sealed ? '· segel' : ''}</li>)}
          </ul>
          <button type="button" className="ui-button ui-button-secondary no-print" onClick={() => window.print()}>Cetak daftar label</button>
        </>
      )}
      <button type="button" className="ui-button ui-button-primary no-print" onClick={onNew}>Catat barang masuk lain</button>
    </Card>
  )
}

export function IntakePage() {
  const queryClient = useQueryClient()
  const [mode, setMode] = useState<IntakeMode>('RECEIPT')
  const [header, setHeader] = useState<IntakeHeader>({ supplierId: '', sourceNote: '', sourceDate: todayInShop() })
  const [lines, setLines] = useState<IntakeLine[]>([])
  const [units, setUnits] = useState<Record<string, Unit[]>>({})
  const [payment, setPayment] = useState<IntakePayment>(EMPTY_PAYMENT)
  const [showErrors, setShowErrors] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const suppliers = useSuppliers('', false, mode === 'RECEIPT')
  const command = useCommand<PostResult, Record<string, unknown>>(mode === 'OPENING' ? 'post_opening_stock_v1' : 'post_stock_receipt_v1')

  const supplier = suppliers.data?.find(s => s.id === header.supplierId) ?? null
  const total = totalCost(lines)
  const errors = [
    ...(lines.length === 0 ? ['Belum ada barang.'] : []),
    ...lines.flatMap(line => lineErrors(line)),
    ...(mode === 'RECEIPT' ? paymentErrors(payment, total, supplier) : []),
  ]

  // Isi berubah = niat baru: jangan memakai ulang nomor operasi pengiriman sebelumnya.
  function changed() { if (!command.busy) command.reset() }

  function addProduct(product: ProductSummary, unitId?: string) {
    setUnits(u => ({ ...u, [product.id]: product.units }))
    setLines(ls => [...ls, newIntakeLine(product, unitId)])
    changed()
  }

  function updateLine(next: IntakeLine) {
    setLines(ls => ls.map(l => l.key === next.key ? next : l))
    changed()
  }

  function switchMode(next: IntakeMode) {
    setMode(next)
    setShowErrors(false)
    changed()
  }

  function startNew() {
    setLines([])
    setHeader({ supplierId: '', sourceNote: '', sourceDate: todayInShop() })
    setPayment(EMPTY_PAYMENT)
    setShowErrors(false)
    command.reset()
  }

  async function post() {
    const result = await command.run(buildIntakePayload(mode, header, lines, payment))
    setConfirming(false)
    if (result) {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['products'] }),
        queryClient.invalidateQueries({ queryKey: ['stock'] }),
        queryClient.invalidateQueries({ queryKey: ['cash'] }),
        queryClient.invalidateQueries({ queryKey: ['suppliers'] }),
      ])
    }
  }

  if (command.result) {
    return (
      <section className="narrow-page">
        <PageHeader title="Barang Masuk" />
        <ResultCard result={command.result} mode={mode} onNew={startNew} />
      </section>
    )
  }

  const rollTotalCount = lines.reduce((n, l) => n + (l.trackSegments ? rollCount(l) + l.positions.length : 0), 0)
  const paymentText = total.isZero() ? 'Tanpa pembayaran (modal nol)'
    : payment.method === 'CASH' ? `Tunai dari ${CASHBOX_LABEL[payment.cashbox]}` : PAYMENT_METHOD_LABEL[payment.method]

  return (
    <section className="narrow-page">
      <PageHeader title="Barang Masuk" description="Catat barang dari distributor atau stok awal saat mulai memakai aplikasi." />
      <ChoiceGroup label="Jenis pencatatan" value={mode} onChange={switchMode} options={[
        { value: 'RECEIPT', label: 'Barang masuk (beli)', description: 'Ada pembayaran ke distributor' },
        { value: 'OPENING', label: 'Stok awal', description: 'Barang yang sudah ada di toko; tanpa pembayaran' },
      ]} />

      <Card title={mode === 'OPENING' ? 'Keterangan stok awal' : 'Nota distributor'}>
        <div className="form-grid">
          {mode === 'RECEIPT' && (
            <Select label="Distributor (boleh kosong)" value={header.supplierId}
              onChange={supplierId => { setHeader(h => ({ ...h, supplierId })); setPayment(p => p.method === 'SUPPLIER_CREDIT' ? EMPTY_PAYMENT : p); changed() }}
              options={[{ value: '', label: 'Tanpa distributor' }, ...(suppliers.data ?? []).map(s => ({ value: s.id, label: s.name }))]} />
          )}
          <TextInput label={mode === 'OPENING' ? 'Catatan (boleh kosong)' : 'Nomor nota (boleh kosong)'} value={header.sourceNote}
            onChange={sourceNote => { setHeader(h => ({ ...h, sourceNote })); changed() }} maxLength={120} />
          <TextInput type="date" label={mode === 'OPENING' ? 'Tanggal stok awal' : 'Tanggal nota'} value={header.sourceDate}
            onChange={sourceDate => { setHeader(h => ({ ...h, sourceDate })); changed() }} />
        </div>
      </Card>

      <Card title="Tambah barang">
        <ProductSearch onSelect={addProduct} withScanner scannerTitle="Scan barang yang masuk" />
      </Card>

      {lines.length === 0 && <EmptyState>Belum ada barang. Scan atau cari barang di atas.</EmptyState>}
      {lines.map(line => (
        <IntakeLineCard key={line.key} line={line} units={units[line.productId] ?? []} onChange={updateLine}
          onRemove={() => { setLines(ls => ls.filter(l => l.key !== line.key)); changed() }} />
      ))}

      {lines.length > 0 && (
        <Card title="Ringkasan">
          <SummaryRow label="Jumlah baris barang" value={lines.length} />
          {rollTotalCount > 0 && <SummaryRow label="Jumlah roll/potongan berlabel" value={rollTotalCount} />}
          <SummaryRow strong label={mode === 'OPENING' ? 'Total modal stok awal' : 'Total bayar ke distributor'} value={formatRupiah(total)} />
          {mode === 'RECEIPT' && !total.isZero() && (
            <IntakePaymentFields payment={payment} total={total} supplier={supplier}
              onChange={next => { setPayment(next); changed() }} />
          )}
          {showErrors && errors.length > 0 && (
            <div className="ui-alert ui-alert-error" role="alert"><ul>{errors.map(e => <li key={e}>{e}</li>)}</ul></div>
          )}
          <ErrorMessage error={command.error} />
          <button type="button" className="ui-button ui-button-primary ui-button-large" disabled={command.busy}
            onClick={() => { setShowErrors(true); if (errors.length === 0) setConfirming(true) }}>
            {mode === 'OPENING' ? 'Periksa & simpan stok awal' : 'Periksa & simpan barang masuk'}
          </button>
        </Card>
      )}

      <ConfirmDialog open={confirming} title={mode === 'OPENING' ? 'Simpan stok awal?' : 'Simpan barang masuk?'}
        confirmLabel="Ya, simpan" busy={command.busy} onConfirm={() => { void post() }} onCancel={() => setConfirming(false)}>
        <SummaryRow label="Barang" value={`${lines.length} baris`} />
        {rollTotalCount > 0 && <SummaryRow label="Roll/potongan" value={rollTotalCount} />}
        <SummaryRow strong label="Total modal" value={formatRupiah(total)} />
        {mode === 'RECEIPT' && <SummaryRow label="Pembayaran" value={paymentText} />}
        {supplier && <SummaryRow label="Distributor" value={supplier.name} />}
        <p>Setelah disimpan, stok bertambah{mode === 'RECEIPT' && !total.isZero() ? ' dan pembayaran tercatat' : ''}. Kesalahan dikoreksi lewat menu Stok.</p>
        <ErrorMessage error={command.error} />
      </ConfirmDialog>
    </section>
  )
}
