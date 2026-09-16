import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { BarcodeScanner } from './scanner'

type Product = {
  id: string
  sku: string
  name: string
  units: { id: string; label: string; is_default: boolean }[]
}
type BarcodeRow = { id: string; code: string; unit_id: string | null; unit_label: string | null }

/**
 * Form produk baru. Barcode dapat diisi manual atau diambil langsung
 * dari hasil scan kamera/scanner fisik.
 */
export function NewProduct() {
  const navigate = useNavigate()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [barcode, setBarcode] = useState('')

  const onScan = useCallback((code: string) => {
    setBarcode(code)
    setError('')
  }, [])

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase) return
    const fields = new FormData(event.currentTarget)
    const input = Object.fromEntries(fields.entries()) as Record<string, string>
    setBusy(true); setError('')
    const { error: err } = await supabase.rpc('upsert_product_v1', {
      p_input: {
        operation_id: crypto.randomUUID(),
        sku: input.sku,
        name: input.name,
        specification: input.specification,
        base_unit: input.base_unit,
        quantity_step: input.quantity_step,
        track_segments: input.track_segments === 'on',
        unit_label: input.unit_label,
        factor_base: input.factor_base,
        sale_step: input.sale_step,
        sell_price: input.sell_price,
        barcode: barcode || null,
        shelf: input.shelf || null,
      },
    })
    setBusy(false)
    if (err) setError(err.message)
    else navigate('/katalog')
  }

  return (
    <section className="form-page">
      <div className="eyebrow">KHUSUS OWNER</div>
      <h2>Produk Baru</h2>
      <p>Isi satuan dasar dan satu opsi jual. Stok belum bertambah sampai barang masuk atau stok awal diposting.</p>

      <BarcodeScanner
        onScan={onScan}
        title="Daftarkan barcode"
        description="Scan barcode fisik produk ini, atau ketik kodenya."
      />
      {barcode && <div className="notice">Barcode terpilih: <code>{barcode}</code></div>}

      <form onSubmit={submit} className="editor">
        <label>SKU<input name="sku" required maxLength={60} /></label>
        <label>Nama produk<input name="name" required maxLength={150} /></label>
        <label>Spesifikasi pembeda<input name="specification" maxLength={500} /></label>
        <label>Rak<input name="shelf" maxLength={60} /></label>
        <label>Satuan stok dasar<input name="base_unit" placeholder="pcs atau m" required /></label>
        <label>Langkah stok<input name="quantity_step" placeholder="1 atau 0.001" required /></label>
        <label>Satuan jual<input name="unit_label" placeholder="pcs, m, roll 100 m" required /></label>
        <label>Faktor ke satuan dasar<input name="factor_base" placeholder="1 atau 100" required /></label>
        <label>Langkah jual<input name="sale_step" placeholder="1 atau 0.1" required /></label>
        <label>Harga per satuan jual (Rp)<input name="sell_price" required /></label>
        <label>Barcode
          <input value={barcode} onChange={e => setBarcode(e.target.value)} placeholder="Scan di atas atau ketik manual" maxLength={100} />
        </label>
        <label className="check"><input type="checkbox" name="track_segments" /> Lacak roll/potongan fisik</label>
        {error && <div className="error" role="alert">{error}</div>}
        <button disabled={busy}>{busy ? 'Menyimpan…' : 'Simpan produk'}</button>
      </form>
    </section>
  )
}

/**
 * Kelola barcode produk yang sudah ada.
 * Satu produk boleh memiliki banyak barcode (mis. kemasan berbeda),
 * dan tiap barcode dapat dipetakan ke satuan jual tertentu.
 */
export function BarcodeManager() {
  const [query, setQuery] = useState('')
  const [products, setProducts] = useState<Product[]>([])
  const [selected, setSelected] = useState<Product | null>(null)
  const [barcodes, setBarcodes] = useState<BarcodeRow[]>([])
  const [unitId, setUnitId] = useState('')
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [busy, setBusy] = useState(false)

  const loadBarcodes = useCallback(async (productId: string) => {
    if (!supabase) return
    const { data } = await supabase.rpc('list_product_barcodes_v1', { p_input: { product_id: productId } })
    setBarcodes((data as BarcodeRow[]) ?? [])
  }, [])

  useEffect(() => {
    let alive = true
    async function load() {
      if (!supabase) return
      const { data } = await supabase.rpc('search_products_v1', { p_input: { query, limit: 25 } })
      if (alive) setProducts((data as Product[]) ?? [])
    }
    const t = setTimeout(load, 250)
    return () => { alive = false; clearTimeout(t) }
  }, [query])

  useEffect(() => {
    if (!selected) return
    setUnitId(selected.units.find(u => u.is_default)?.id ?? selected.units[0]?.id ?? '')
    void loadBarcodes(selected.id)
  }, [selected, loadBarcodes])

  const onScan = useCallback(async (code: string) => {
    if (!supabase || !selected) return
    setBusy(true); setError(''); setSuccess('')
    try {
      const { data, error: err } = await supabase.rpc('add_product_barcode_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          product_id: selected.id,
          product_unit_id: unitId || undefined,
          code,
        },
      })
      if (err) throw new Error(err.message)
      const res = data as { ok?: boolean; already?: boolean }
      if (res?.ok) {
        setSuccess(res.already ? `Barcode ${code} sudah terdaftar pada produk ini.` : `Barcode ${code} tersimpan.`)
        await loadBarcodes(selected.id)
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal menyimpan barcode')
    } finally {
      setBusy(false)
    }
  }, [selected, unitId, loadBarcodes])

  async function removeBarcode(code: string) {
    if (!supabase || !selected) return
    setBusy(true); setError(''); setSuccess('')
    try {
      const { error: err } = await supabase.rpc('remove_product_barcode_v1', {
        p_input: { operation_id: crypto.randomUUID(), code },
      })
      if (err) throw new Error(err.message)
      setSuccess(`Barcode ${code} dihapus.`)
      await loadBarcodes(selected.id)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal menghapus barcode')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section>
      <div className="section-head"><div>
        <div className="eyebrow">KATALOG</div>
        <h2>Daftar Barcode</h2>
        <p>Pilih produk, lalu scan barcode fisiknya. Satu produk boleh punya banyak barcode.</p>
      </div></div>

      {!selected ? (
        <>
          <label className="search-label">Cari produk
            <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Nama atau SKU…" maxLength={120} />
          </label>
          <div className="product-grid">
            {products.map(p => (
              <article key={p.id} className="product-card" onClick={() => setSelected(p)}>
                <div className="product-card-top"><span className="sku">{p.sku}</span></div>
                <h4>{p.name}</h4>
              </article>
            ))}
          </div>
          {products.length === 0 && <div className="empty">Tidak ada produk cocok.</div>}
        </>
      ) : (
        <>
          <div className="notice">
            Produk: <strong>{selected.name}</strong> ({selected.sku})
            <button
              className="ghost small"
              style={{ marginLeft: 10 }}
              onClick={() => { setSelected(null); setBarcodes([]); setError(''); setSuccess('') }}
            >Ganti</button>
          </div>

          {selected.units.length > 1 && (
            <label className="search-label">Satuan untuk barcode ini
              <select value={unitId} onChange={e => setUnitId(e.target.value)}>
                {selected.units.map(u => <option key={u.id} value={u.id}>{u.label}</option>)}
              </select>
            </label>
          )}

          <BarcodeScanner onScan={c => { void onScan(c) }} title="Scan barcode produk ini" />
          {busy && <p>Menyimpan…</p>}
          {success && <div className="success">{success}</div>}
          {error && <div className="error" role="alert">{error}</div>}

          <h3>Barcode Terdaftar ({barcodes.length})</h3>
          {barcodes.length === 0 && <div className="empty">Belum ada barcode untuk produk ini.</div>}
          <div className="invoice-list">
            {barcodes.map(b => (
              <article key={b.id} className="invoice-card">
                <div className="invoice-header">
                  <code>{b.code}</code>
                  <span>{b.unit_label || 'satuan default'}</span>
                </div>
                <div className="invoice-footer">
                  <span />
                  <button className="ghost small" onClick={() => { void removeBarcode(b.code) }} disabled={busy}>Hapus</button>
                </div>
              </article>
            ))}
          </div>
        </>
      )}
    </section>
  )
}
