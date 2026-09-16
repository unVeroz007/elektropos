import { useState, useEffect, useCallback } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { rupiahHalfUp } from '../lib/numbers'
import Decimal from 'decimal.js'

type InvoiceItem = {
  id: string
  line_no: number
  description: string
  qty_sell: string
  qty_base: string
  unit_price: string
  net_total: string
}

type ReturnItem = {
  invoice_item_id: string
  qty_base: string
  disposition: 'SALEABLE' | 'DAMAGED' | 'NONE'
}

export function ReturnSale({ profile }: { profile: { id: string; role: 'OWNER' | 'STAFF' | 'MAINTAINER' } }) {
  const { invoiceId } = useParams<{ invoiceId: string }>()
  const navigate = useNavigate()

  const [invoice, setInvoice] = useState<{
    id: string
    number: string
    total: string
    items: InvoiceItem[]
  } | null>(null)
  const [returns, setReturns] = useState<ReturnItem[]>([])
  const [reason, setReason] = useState('')
  const [refundMethod, setRefundMethod] = useState('CASH')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')

  const loadInvoice = useCallback(async () => {
    if (!supabase || !invoiceId) return
    try {
      const { data, error } = await supabase.rpc('get_invoice_v1', { p_input: { invoice_id: invoiceId } })
      if (error || !data) throw error || new Error('Gagal memuat nota')
      setInvoice(data as never)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal memuat nota')
    }
  }, [invoiceId])

  useEffect(() => {
    if (!invoiceId) return
    loadInvoice()
  }, [invoiceId, loadInvoice])

  function updateReturn(itemId: string, field: keyof ReturnItem, value: string) {
    setReturns(prev => {
      const existing = prev.find(r => r.invoice_item_id === itemId)
      if (existing) {
        return prev.map(r => r.invoice_item_id === itemId ? { ...r, [field]: value } : r)
      }
      return [...prev, { invoice_item_id: itemId, qty_base: '0', disposition: 'SALEABLE', [field]: value }]
    })
  }

  function removeReturn(itemId: string) {
    setReturns(prev => prev.filter(r => r.invoice_item_id !== itemId))
  }

  function calculateRefund(): Decimal {
    if (!invoice) return new Decimal(0)
    let total = new Decimal(0)
    for (const ret of returns) {
      const item = invoice.items.find(i => i.id === ret.invoice_item_id)
      if (!item) continue
      try {
        const retQty = new Decimal(ret.qty_base)
        const lineNet = new Decimal(item.net_total)
        const lineQty = new Decimal(item.qty_base)
        if (lineQty.isZero()) continue
        const refund = lineNet.mul(retQty).div(lineQty).toDecimalPlaces(0, 1)
        total = total.add(refund)
      } catch {
        // skip invalid
      }
    }
    return total
  }

  async function submitReturn() {
    if (!supabase || !invoice) return
    if (returns.length === 0) { setError('Pilih item yang diretur'); return }
    if (!reason) { setError('Alasan retur wajib'); return }
    if (profile.role !== 'OWNER') { setError('Hanya owner dapat memproses retur'); return }

    setBusy(true); setError('')
    try {
      const items = returns.map(r => ({
        invoice_item_id: r.invoice_item_id,
        qty_base: r.qty_base,
        disposition: r.disposition
      }))
      const { data, error } = await supabase.rpc('return_sale_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          invoice_id: invoiceId,
          reason,
          refund_method: refundMethod,
          items
        }
      })
      if (error) throw new Error(error.message)
      const res = data as { ok?: boolean; refund_total?: string; document_number?: string }
      if (res?.ok) {
        setSuccess(`Retur ${res.document_number} sukses, refund ${rupiahHalfUp(res.refund_total || '0')}`)
        setReturns([])
        setTimeout(() => navigate('/riwayat'), 2000)
      } else {
        setError('Retur gagal: ' + JSON.stringify(data))
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal')
    } finally {
      setBusy(false)
    }
  }

  if (!invoiceId) return <div className="empty">ID nota tidak ditemukan</div>
  if (!invoice) return <p>Memuat…</p>

  const refund = calculateRefund()

  return (
    <section className="return-page">
      <div className="section-head">
        <div>
          <div className="eyebrow">RETUR</div>
          <h2>Retur / Refund</h2>
          <p>Pilih item dan jumlah yang diretur.</p>
        </div>
      </div>

      <div className="invoice-card-header">
        <strong>{invoice.number}</strong>
        <span className="total">Rp{Number(invoice.total).toLocaleString('id-ID')}</span>
      </div>

      {success && <div className="success">{success}</div>}
      {error && <div className="error" role="alert">{error}</div>}

      <div className="return-list">
        {invoice.items.map(item => {
          const ret = returns.find(r => r.invoice_item_id === item.id)
          const maxQty = Number(item.qty_base)
          return (
            <article key={item.id} className="return-card">
              <div className="return-card-header">
                <strong>{item.description}</strong>
                <span>Net: Rp{Number(item.net_total).toLocaleString('id-ID')}</span>
              </div>
              <div className="return-card-info">
                <small>Qty jual: {item.qty_sell} · Base: {item.qty_base}</small>
              </div>
              <div className="return-card-controls">
                <label>Qty diretur (base)
                  <input
                    type="number"
                    step="0.001"
                    max={maxQty}
                    value={ret?.qty_base ?? '0'}
                    onChange={e => updateReturn(item.id, 'qty_base', e.target.value)}
                    placeholder="0"
                  />
                </label>
                <label>Kondisi
                  <select
                    value={ret?.disposition ?? 'SALEABLE'}
                    onChange={e => updateReturn(item.id, 'disposition', e.target.value)}
                  >
                    <option value="SALEABLE">Layak jual</option>
                    <option value="DAMAGED">Rusak</option>
                    <option value="NONE">Tidak dikembalikan</option>
                  </select>
                </label>
              </div>
              {ret && Number(ret.qty_base) > 0 && (
                <button className="ghost small" onClick={() => removeReturn(item.id)}>Hapus retur</button>
              )}
            </article>
          )
        })}
      </div>

      <div className="form-group">
        <label>Alasan retur
          <input
            value={reason}
            onChange={e => setReason(e.target.value)}
            placeholder="Contoh: Salah beli, barang rusak"
          />
        </label>

        <label>Metode refund
          <select value={refundMethod} onChange={e => setRefundMethod(e.target.value)}>
            <option value="CASH">Tunai (dari laci)</option>
            <option value="TRANSFER">Transfer</option>
            <option value="QRIS">QRIS</option>
          </select>
        </label>
      </div>

      <div className="return-summary">
        <div>Total refund (estimasi): <strong>Rp{rupiahHalfUp(refund.toFixed(0))}</strong></div>
      </div>

      <button onClick={submitReturn} disabled={busy || returns.length === 0 || profile.role !== 'OWNER'} className="primary">
        {busy ? 'Memproses…' : 'Proses Retur'}
      </button>

      {profile.role !== 'OWNER' && (
        <p className="notice">Retur hanya dapat diproses oleh owner.</p>
      )}
    </section>
  )
}