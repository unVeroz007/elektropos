import { useCallback, useState } from 'react'
import { supabase } from '../lib/supabase'
import { rupiahHalfUp } from '../lib/numbers'
import { BarcodeScanner } from './scanner'
import Decimal from 'decimal.js'

type ProductUnit = { id: string; label: string; factor_base: string; sell_price: string; is_default?: boolean }
type Product = {
  id: string
  sku: string
  name: string
  specification: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  units: ProductUnit[]
}

type Line = {
  product_unit_id: string
  name: string
  unit_label: string
  factor_base: string
  qty: string
  cost: string
  track_segments: boolean
  label: string
  sealed: boolean
}

type Mode = 'RECEIPT' | 'OPENING'

export function StockIntake({ profile }: { profile: { role: 'OWNER' | 'STAFF' | 'MAINTAINER' } }) {
  const [mode, setMode] = useState<Mode>('RECEIPT')
  const [lines, setLines] = useState<Line[]>([])
  const [sourceNote, setSourceNote] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('TRANSFER')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')

  const addProduct = useCallback((p: Product, unit: ProductUnit) => {
    setLines(prev => [...prev, {
      product_unit_id: unit.id,
      name: p.name,
      unit_label: unit.label,
      factor_base: unit.factor_base,
      qty: '1',
      cost: '',
      track_segments: p.track_segments,
      label: '',
      sealed: false,
    }])
  }, [])

  async function handleScan(code: string) {
    if (!supabase) return
    setError('')
    const { data, error: err } = await supabase.rpc('search_products_v1', { p_input: { query: code, limit: 5 } })
    if (err) { setError(err.message); return }
    const list = (data as Product[]) ?? []
    const match = list.find(p => p.units.length > 0)
    if (!match) { setError(`Barcode ${code} tidak dikenal. Daftarkan produk terlebih dahulu.`); return }
    const unit = match.units.find(u => u.is_default !== false) || match.units[0]
    addProduct(match, unit)
  }

  function updateLine(index: number, patch: Partial<Line>) {
    setLines(prev => prev.map((l, i) => i === index ? { ...l, ...patch } : l))
  }

  function removeLine(index: number) {
    setLines(prev => prev.filter((_, i) => i !== index))
  }

  function totalCost(): Decimal {
    return lines.reduce((sum, l) => {
      try {
        if (!l.cost) return sum
        return sum.add(new Decimal(l.cost))
      } catch { return sum }
    }, new Decimal(0))
  }

  function validate(): string | null {
    if (lines.length === 0) return 'Belum ada barang.'
    if (mode === 'RECEIPT' && lines.some(l => !l.cost)) return 'Setiap baris penerimaan wajib memiliki total biaya.'
    for (const l of lines) {
      const qty = Number(l.qty)
      if (!Number.isFinite(qty) || qty <= 0) return 'Jumlah harus lebih dari nol.'
      if (!/^\d+(\.\d+)?$/.test(l.qty)) return 'Format jumlah tidak sah.'
      if (l.track_segments && !l.label.trim()) return `Posisi roll ${l.name} memerlukan label.`
    }
    return null
  }

  async function submit() {
    const invalid = validate()
    if (invalid) { setError(invalid); return }
    if (!supabase) return

    setBusy(true); setError(''); setSuccess('')
    try {
      const items = lines.map(l => ({
        product_unit_id: l.product_unit_id,
        qty: l.qty,
        acquisition_cost: mode === 'RECEIPT' ? l.cost : (l.cost || '0'),
        ...(mode === 'OPENING' && !l.cost ? { free_reason: 'Stok awal tanpa modal' } : {}),
        ...(l.track_segments ? {
          positions: [{
            qty_base: new Decimal(l.qty).mul(l.factor_base).toString(),
            segment_capacity: new Decimal(l.qty).mul(l.factor_base).toString(),
            sealed: l.sealed,
            label: l.label.trim(),
          }],
        } : {}),
      }))

      const payload: Record<string, unknown> = {
        operation_id: crypto.randomUUID(),
        reason: mode === 'OPENING' ? 'Stok awal' : 'Barang masuk',
        items,
      }
      if (mode === 'RECEIPT') {
        payload.source_note = sourceNote || undefined
        payload.payment = {
          method: paymentMethod,
          confirmed: true,
          amount: totalCost().toFixed(0),
        }
      }

      const rpc = mode === 'OPENING' ? 'post_opening_stock_v1' : 'post_stock_receipt_v1'
      const { data, error: err } = await supabase.rpc(rpc, { p_input: payload })
      if (err) throw new Error(err.message)
      const res = data as { ok?: boolean; document_number?: string }
      if (res?.ok) {
        setSuccess(`Tersimpan: ${res.document_number}`)
        setLines([])
        setSourceNote('')
      } else {
        throw new Error('Operasi tidak berhasil.')
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal menyimpan.')
    } finally {
      setBusy(false)
    }
  }

  if (profile.role !== 'OWNER') {
    return <section><div className="notice">Hanya owner yang dapat mencatat barang masuk dan stok awal.</div></section>
  }

  return (
    <section>
      <div className="section-head">
        <div>
          <div className="eyebrow">PERSEDIAAN</div>
          <h2>Barang Masuk &amp; Stok Awal</h2>
          <p>Scan produk, masukkan jumlah dan modal. Posting menambah lot dan stok.</p>
        </div>
        <div className="section-actions">
          <button className={mode === 'RECEIPT' ? '' : 'ghost'} onClick={() => setMode('RECEIPT')}>Barang Masuk</button>
          <button className={mode === 'OPENING' ? '' : 'ghost'} onClick={() => setMode('OPENING')}>Stok Awal</button>
        </div>
      </div>

      <BarcodeScanner onScan={handleScan} title="Scan barang masuk" description="Scan hanya memilih produk; stok belum bertambah sampai diposting." />

      {mode === 'RECEIPT' && (
        <div className="filter-group">
          <label>Nomor nota / supplier
            <input value={sourceNote} onChange={e => setSourceNote(e.target.value)} placeholder="Contoh: Nota 123 / Toko Sumber" maxLength={120} />
          </label>
          <label>Metode bayar pembelian
            <select value={paymentMethod} onChange={e => setPaymentMethod(e.target.value)}>
              <option value="TRANSFER">Transfer</option>
              <option value="QRIS">QRIS</option>
            </select>
          </label>
        </div>
      )}

      {success && <div className="success">{success}</div>}
      {error && <div className="error" role="alert">{error}</div>}

      {lines.length === 0 && <div className="empty">Belum ada barang. Scan atau cari produk untuk mulai.</div>}

      <div className="intake-list">
        {lines.map((l, i) => (
          <article key={`${l.product_unit_id}-${i}`} className="intake-card">
            <div className="intake-header">
              <strong>{l.name} ({l.unit_label})</strong>
              <button className="ghost small" onClick={() => removeLine(i)}>Hapus</button>
            </div>
            <div className="intake-controls">
              <label>Jumlah ({l.unit_label})
                <input type="text" inputMode="decimal" value={l.qty} onChange={e => updateLine(i, { qty: e.target.value })} />
              </label>
              <label>Total biaya baris (Rp)
                <input type="text" inputMode="numeric" value={l.cost} onChange={e => updateLine(i, { cost: e.target.value })} placeholder={mode === 'OPENING' ? '0 jika tanpa modal' : 'wajib'} />
              </label>
            </div>
            {l.track_segments && (
              <div className="intake-controls">
                <label>Label posisi roll
                  <input value={l.label} onChange={e => updateLine(i, { label: e.target.value })} placeholder="Contoh: R-01" maxLength={40} />
                </label>
                <label className="check-inline">
                  <input type="checkbox" checked={l.sealed} onChange={e => updateLine(i, { sealed: e.target.checked })} />
                  Roll masih segel
                </label>
              </div>
            )}
          </article>
        ))}
      </div>

      {lines.length > 0 && (
        <>
          <div className="cart-summary">
            <div className="cart-row"><span>Jumlah baris</span><span>{lines.length}</span></div>
            {mode === 'RECEIPT' && (
              <div className="cart-row total"><span>Total pembelian</span><strong>Rp{rupiahHalfUp(totalCost().toFixed(0))}</strong></div>
            )}
          </div>
          <button className="primary" onClick={submit} disabled={busy}>
            {busy ? 'Memposting…' : mode === 'OPENING' ? 'Posting Stok Awal' : 'Posting Barang Masuk'}
          </button>
        </>
      )}
    </section>
  )
}
