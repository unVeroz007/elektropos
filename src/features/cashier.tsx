import { useState, useEffect, useRef, useCallback } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { configured, supabase } from '../lib/supabase'
import { parseQuantity, rupiahHalfUp, toBaseQuantity } from '../lib/numbers'
import { saveDraft, loadDrafts, deleteDraft, getDeviceId, type Draft } from '../lib/drafts'
import Decimal from 'decimal.js'
import { BarcodeScanner } from './scanner'
import { useOnlineStatus } from '../lib/online'

type Profile = { id: string; display_name: string; role: 'OWNER' | 'STAFF' | 'MAINTAINER'; active: boolean }
type Product = {
  id: string
  sku: string
  name: string
  specification: string
  base_unit: string
  shelf: string | null
  quantity_step: string
  units: { id: string; label: string; sell_price: string; factor_base: string; sale_step: string; is_default: boolean }[]
  stock_shop: string
  stock_field: string
}
type CartItem = {
  product_unit_id: string
  qty: string
  discount_mode?: 'percent' | 'amount'
  discount_value?: string
  expected_unit_version?: number
}
type ProductUnit = {
  id: string
  label: string
  sell_price: string
  factor_base: string
  sale_step: string
  version?: number
}
type ProductWithUnit = {
  product: Product
  unit: ProductUnit
}

export function Cashier({ profile }: { profile: Profile }) {
  const navigate = useNavigate()

  const [cart, setCart] = useState<CartItem[]>([])
  const [query, setQuery] = useState('')
  const [customer, setCustomer] = useState('')
  const [discountMode, setDiscountMode] = useState('')
  const [discountValue, setDiscountValue] = useState('')
  const [paymentMethod, setPaymentMethod] = useState('CASH')
  const [tendered, setTendered] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const [products, setProducts] = useState<Product[]>([])
  const [searching, setSearching] = useState(false)
  const searchRef = useRef<HTMLInputElement>(null)
  const [drafts, setDrafts] = useState<Draft[]>([])
  const [currentDraftId, setCurrentDraftId] = useState<number | null>(null)
  const [unknownCode, setUnknownCode] = useState('')
  const [linkQuery, setLinkQuery] = useState('')
  const [linkProducts, setLinkProducts] = useState<Product[]>([])
  const [linking, setLinking] = useState(false)
  const isOnline = useOnlineStatus()

  const loadProducts = useCallback(async () => {
    if (!supabase) return
    setSearching(true)
    try {
      const { data } = await supabase.rpc('search_products_v1', { p_input: { query, limit: 50 } })
      setProducts((data as Product[]) ?? [])
    } catch {
      setError('Gagal memuat katalog')
    } finally {
      setSearching(false)
    }
  }, [query])

  useEffect(() => {
    if (configured && supabase) {
      loadProducts()
    }
  }, [loadProducts])

  useEffect(() => {
    if (profile?.id) {
      loadDrafts(profile.id, getDeviceId()).then(d => setDrafts(d)).catch(() => {})
    }
  }, [profile?.id])

  // Cari produk untuk menautkan barcode baru (hanya saat panel terbuka)
  useEffect(() => {
    if (!unknownCode || !supabase) return
    let alive = true
    async function search() {
      const { data } = await supabase!.rpc('search_products_v1', { p_input: { query: linkQuery, limit: 20 } })
      if (alive) setLinkProducts((data as Product[]) ?? [])
    }
    const t = setTimeout(search, 250)
    return () => { alive = false; clearTimeout(t) }
  }, [unknownCode, linkQuery])

  async function linkBarcode(product: Product, unitId: string) {
    if (!supabase || !unknownCode) return
    const code = unknownCode
    setLinking(true); setError('')
    try {
      const { error: err } = await supabase.rpc('add_product_barcode_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          product_id: product.id,
          product_unit_id: unitId || undefined,
          code,
        },
      })
      if (err) throw new Error(err.message)
      setUnknownCode('')
      await handleScan(code)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal mendaftarkan barcode')
    } finally {
      setLinking(false)
    }
  }


  function findProductUnit(unitId: string): ProductWithUnit | null {
    for (const p of products) {
      const u = p.units.find(x => x.id === unitId)
      if (u) return { product: p, unit: u }
    }
    return null
  }

  function calculateSubtotal(): Decimal {
    let sub = new Decimal(0)
    for (const item of cart) {
      const found = findProductUnit(item.product_unit_id)
      if (found) {
        try {
          const q = parseQuantity(item.qty)
          const p = new Decimal(found.unit.sell_price)
          sub = sub.add(q.mul(p))
        } catch {
          // transient input, skip
        }
      }
    }
    return sub
  }

  function calculateDiscount(): Decimal {
    const sub = calculateSubtotal()
    if (!discountMode) return new Decimal(0)
    if (discountMode === 'percent') {
      return sub.mul(new Decimal(discountValue || '0')).div(100)
    } else {
      return new Decimal(discountValue || '0')
    }
  }

  function totalAmount(): Decimal {
    const total = calculateSubtotal().sub(calculateDiscount())
    return total.lessThan(0) ? new Decimal(0) : total
  }

  function changeAmount(): Decimal {
    if (!tendered || paymentMethod !== 'CASH') return new Decimal(0)
    return new Decimal(tendered).sub(totalAmount())
  }

  function validateCart(): string | null {
    if (cart.length === 0) return 'Keranjang kosong'
    for (const item of cart) {
      const found = findProductUnit(item.product_unit_id)
      if (!found) return 'Produk tidak ditemukan: ' + item.product_unit_id
      const qty = parseQuantity(item.qty)
      const step = parseQuantity(found.unit.sale_step)
      if (qty.div(step).toFixed(0) !== qty.div(step).toString()) {
        return 'Qty tidak sesuai langkah jual ' + found.unit.label
      }
      const baseQty = toBaseQuantity(item.qty, found.unit.factor_base, found.product.quantity_step)
      if (!baseQty) return 'Konversi tidak tepat'
      const stock = Number(found.product.stock_shop)
      if (Number(baseQty) > stock) return 'Stok tidak cukup untuk ' + found.product.name
    }
    if (paymentMethod === 'CASH' && tendered) {
      if (new Decimal(tendered).lessThan(totalAmount())) return 'Uang kurang dari total'
    }
    return null
  }

  async function saveDraftAction() {
    if (!profile?.id) return
    try {
      const id = await saveDraft(profile.id, getDeviceId(), {
        label: `Draft ${new Date().toLocaleString('id-ID')}`,
        cart,
        payment_method: paymentMethod,
        customer_id: customer || undefined,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        status: 'draft'
      })
      setCurrentDraftId(id)
      loadDrafts(profile.id, getDeviceId()).then(d => setDrafts(d))
      setError('')
    } catch {
      setError('Gagal menyimpan draf')
    }
  }

  function loadDraft(d: Draft) {
    if (d.id) setCurrentDraftId(d.id)
    setCart(d.cart || [])
    setPaymentMethod(d.payment_method || 'CASH')
    setCustomer(d.customer_id || '')
    setError('')
  }

  async function deleteDraftAction(id: number) {
    try {
      await deleteDraft(id)
      if (currentDraftId === id) setCurrentDraftId(null)
      if (profile?.id) loadDrafts(profile.id, getDeviceId()).then(d => setDrafts(d))
    } catch {
      // ignore
    }
  }

  async function finalize() {
    if (!isOnline) {
      setError('Internet sedang terputus. Pembayaran tidak dapat dilakukan tanpa koneksi.')
      return
    }
    const err = validateCart()
    if (err) { setError(err); return }

    setBusy(true); setError('')
    try {
      const items = cart.map(c => {
        const found = findProductUnit(c.product_unit_id)
        // Utamakan versi saat barang ditambahkan (hasil scan); fallback ke katalog
        const version = c.expected_unit_version ?? (found?.unit as { version?: number } | undefined)?.version
        return {
          product_unit_id: c.product_unit_id,
          qty: c.qty,
          discount_mode: c.discount_mode,
          discount_value: c.discount_value || undefined,
          ...(typeof version === 'number' ? { expected_unit_version: version } : {}),
        }
      })
      const payload: Record<string, unknown> = {
        operation_id: crypto.randomUUID(),
        items
      }
      if (customer) payload.customer_id = customer
      if (discountMode && discountMode !== '') {
        payload.discount_mode = discountMode
        payload.discount_value = discountValue
      }
      payload.payment = { method: paymentMethod, tendered: tendered || '0', confirmed: true }

      const { data, error } = await supabase?.rpc('finalize_sale_v1', { p_input: payload }) ?? { data: null, error: { message: 'Supabase tidak terkonfigurasi' } }
      if (error || !data) {
        const msg = error?.message || 'Finalisasi gagal'
        if (msg.includes('PRICE_CHANGED')) {
          setError('Harga berubah sejak barang ditambahkan. Katalog dimuat ulang — periksa kembali lalu bayar lagi.')
          void loadProducts()
        } else {
          setError(msg)
        }
        return
      }
      const res = data as { ok?: boolean; entity_id?: string; document_number?: string }
      if (res?.ok && res.entity_id) {
        setCart([])
        setCustomer('')
        setDiscountMode('')
        setDiscountValue('')
        setTendered('')
        navigate('/struk/' + res.entity_id)
      } else {
        setError('Finalisasi gagal: ' + JSON.stringify(data))
      }
    } catch (e: unknown) {
      const err = e as Error
      setError(err.message || 'Gagal')
    } finally {
      setBusy(false)
    }
  }

  const subtotal = calculateSubtotal()
  const discount = calculateDiscount()
  const total = totalAmount()
  const change = changeAmount()

  function addToCart(unitId: string, qty: string) {
    const existing = cart.find(c => c.product_unit_id === unitId)
    if (existing) {
      setCart(prev => prev.map(c => c.product_unit_id === unitId ? { ...c, qty } : c))
    } else {
      setCart(prev => [...prev, { product_unit_id: unitId, qty }])
    }
  }

  function removeFromCart(unitId: string) {
    setCart(prev => prev.filter(c => c.product_unit_id !== unitId))
  }

  function updateQuantity(unitId: string, qty: string) {
    setCart(prev => prev.map(c => c.product_unit_id === unitId ? { ...c, qty } : c))
  }

  async function handleScan(code: string) {
    if (!supabase) return
    setError('')
    try {
      const { data, error: err } = await supabase.rpc('find_by_barcode_v1', {
        p_input: { code },
      })
      if (err) throw new Error(err.message)
      const found = data as {
        found: boolean
        code: string
        product_id?: string
        name?: string
        unit_id?: string
        unit_label?: string
        unit_version?: number
      }
      if (!found?.found) {
        setUnknownCode(code)
        setLinkQuery('')
        return
      }
      setUnknownCode('')
      const unitId = found.unit_id as string
      const version = found.unit_version
      // Dua scan barang sama menambah qty, bukan menimpa
      setCart(prev => {
        const existing = prev.find(c => c.product_unit_id === unitId)
        if (existing) {
          return prev.map(c => c.product_unit_id === unitId
            ? { ...c, qty: new Decimal(c.qty).add(1).toString() }
            : c)
        }
        return [...prev, { product_unit_id: unitId, qty: '1', expected_unit_version: version }]
      })
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal memproses barcode')
    }
  }

  return (
    <section className="cashier-page">
      <div className="section-head">
        <div>
          <div className="eyebrow">KASIR</div>
          <h2>Penjualan</h2>
          <p>Cari produk (scan barcode), tambah keranjang, bayar.</p>
        </div>
        <div className="section-actions">
          <button className="ghost" onClick={saveDraftAction} disabled={cart.length === 0}>Simpan Draft</button>
          <button className="ghost" onClick={() => { setCart([]); setError(''); setCurrentDraftId(null) }}>Reset</button>
        </div>
      </div>

      {!isOnline && (
        <div className="offline-banner">
          ⚡ Internet terputus — data lokal tersimpan, pembayaran tidak bisa dilakukan sampai koneksi pulih.
        </div>
      )}

      {drafts.length > 0 && (
        <div className="drafts-panel">
          <h3>Draf Tersimpan ({drafts.length})</h3>
          <div className="draft-list">
            {drafts.slice(0, 5).map(d => (
              <article key={d.id} className="draft-card" onClick={() => loadDraft(d)}>
                <div className="draft-card-header">
                  <strong>{d.label}</strong>
                  <button className="ghost small" onClick={e => { e.stopPropagation(); if (d.id) deleteDraftAction(d.id) }}>×</button>
                </div>
                <small>{(d.cart?.length || 0)} barang · Rp{rupiahHalfUp(
                  d.cart?.reduce((s, c) => {
                    try {
                      const unit = products?.flatMap(p => p.units).find(u => u.id === c.product_unit_id)
                      if (!unit) return s
                      return s + parseQuantity(c.qty).mul(unit.sell_price).toNumber()
                    } catch { return s }
                  }, 0)?.toString() || '0'
                )}</small>
                <small>{new Date(d.updated_at).toLocaleString('id-ID')}</small>
              </article>
            ))}
          </div>
        </div>
      )}

      <div className="cashier-layout">
        <div className="cashier-left">
          <label className="search-label">
            Cari nama / SKU / barcode
            <input
              ref={searchRef}
              value={query}
              onChange={e => setQuery(e.target.value)}
              placeholder="Contoh: kabel NYA, 001234…"
              maxLength={120}
              autoFocus
            />
          </label>

          <BarcodeScanner
            onScan={handleScan}
            title="Scan barang"
            description="Kamera laptop/HP atau scanner fisik."
          />

          {unknownCode && (
            <div className="unknown-barcode">
              <div className="unknown-barcode-head">
                <strong>Barcode <code>{unknownCode}</code> belum terdaftar</strong>
                <button className="ghost small" onClick={() => setUnknownCode('')}>Tutup</button>
              </div>
              {profile.role === 'OWNER' ? (
                <>
                  <p>Pilih produk yang cocok, lalu barcode ini langsung tersimpan dan masuk keranjang.</p>
                  <label className="search-label">Cari produk
                    <input value={linkQuery} onChange={e => setLinkQuery(e.target.value)} placeholder="Nama atau SKU produk…" maxLength={120} autoFocus />
                  </label>
                  <div className="link-product-list">
                    {linkProducts.map(p => (
                      <article key={p.id} className="link-product">
                        <div>
                          <strong>{p.name}</strong>
                          <small> {p.sku}</small>
                        </div>
                        <div className="link-product-actions">
                          {p.units.map(u => (
                            <button key={u.id} className="ghost small" disabled={linking}
                              onClick={() => { void linkBarcode(p, u.id) }}>
                              Daftar sebagai {u.label}
                            </button>
                          ))}
                        </div>
                      </article>
                    ))}
                    {linkProducts.length === 0 && <div className="empty">Ketik nama produk untuk mencari.</div>}
                  </div>
                </>
              ) : (
                <p>Minta <strong>owner</strong> mendaftarkan barcode ini lewat menu <strong>Daftar Barcode</strong>, atau gunakan pencarian nama produk.</p>
              )}
            </div>
          )}

          {error && <div className="error" role="alert">{error}</div>}

          <div className="product-grid">
            {products.map(product => product.units.map(unit => (
              <article
                key={unit.id}
                className="product-card"
                onClick={() => { addToCart(unit.id, '1'); searchRef.current?.focus() }}
              >
                <div className="product-card-top">
                  <span className="sku">{product.sku}</span>
                  <span>{product.shelf || 'Rak -'}</span>
                </div>
                <h4>{product.name}</h4>
                <p>{product.specification || 'Spesifikasi -'}</p>
                <div className="unit-info">
                  <span>{unit.label}</span>
                  <span>• Rp{Number(unit.sell_price).toLocaleString('id-ID')}</span>
                  <span>• {unit.factor_base} {product.base_unit}</span>
                </div>
                <div className="stock-row">
                  <span>Toko: <strong>{product.stock_shop} {product.base_unit}</strong></span>
                  {unit.is_default && <span className="default-badge">default</span>}
                </div>
              </article>
            )))}
          </div>

          {products.length === 0 && !searching && <p className="empty">Ketik nama/SKU/barcode untuk mencari produk.</p>}
          {searching && <p>Memuat…</p>}

          <div className="cart-section">
            <h3>Keranjang ({cart.length})</h3>
            {cart.length === 0 && <p className="empty">Keranjang kosong. Scan/klik produk di atas.</p>}

            <div className="cart-list">
              {cart.map(item => {
                const found = findProductUnit(item.product_unit_id)
                const price = found ? Number(found.unit.sell_price) : 0
                const qtyNum = parseQuantity(item.qty)
                const gross = rupiahHalfUp(qtyNum.mul(price).toFixed(0))
                return (
                  <div key={item.product_unit_id} className="cart-item">
                    <div>
                      <strong>{found ? `${found.product.name} (${found.unit.label})` : item.product_unit_id}</strong>
                      <small> Rp{price.toLocaleString('id-ID')}</small>
                    </div>
                    <div className="cart-item-top">
                      <span>Rp{gross}</span>
                      <span>{item.qty}</span>
                    </div>
                    <div className="cart-item-bottom">
                      <input
                        type="number"
                        step="0.1"
                        value={item.qty}
                        onChange={e => updateQuantity(item.product_unit_id, e.target.value)}
                      />
                      <button onClick={() => removeFromCart(item.product_unit_id)}>Hapus</button>
                    </div>
                  </div>
                )
              })}
            </div>

            <div className="cart-summary">
              <div className="cart-row">
                <span>Subtotal</span>
                <span>Rp{rupiahHalfUp(subtotal.toFixed(0))}</span>
              </div>
              {discountMode && (
                <div className="cart-row">
                  <span>Diskon {discountMode === 'percent' ? discountValue + '%' : 'Rp' + discountValue}</span>
                  <span className="neg">-{rupiahHalfUp(discount.toFixed(0))}</span>
                </div>
              )}
              <div className="cart-row total">
                <span>Total</span>
                <strong>Rp{rupiahHalfUp(total.toFixed(0))}</strong>
              </div>
            </div>
          </div>
        </div>

        <div className="cashier-right">
          <h3>Bayar</h3>

          <div className="form-group">
            <label>Metode pembayaran
              <select value={paymentMethod} onChange={e => setPaymentMethod(e.target.value)}>
                <option value="CASH">Tunai</option>
                <option value="TRANSFER">Transfer</option>
                <option value="QRIS">QRIS</option>
              </select>
            </label>

            {paymentMethod === 'CASH' && (
              <label>Uang diterima (Rupiah)
                <input
                  type="number"
                  value={tendered}
                  onChange={e => setTendered(e.target.value)}
                  placeholder="0"
                />
              </label>
            )}

            {paymentMethod === 'CASH' && tendered && (
              <div className="change-display">
                Kembalian: <strong>Rp{rupiahHalfUp(change.toFixed(0))}</strong>
              </div>
            )}
          </div>

          {profile.role === 'OWNER' && (
            <div className="discount-section">
              <h4>Diskon (owner)</h4>
              <div className="form-group">
                <label>
                  <select value={discountMode} onChange={e => setDiscountMode(e.target.value)}>
                    <option value="">Tidak ada</option>
                    <option value="percent">Persen (%)</option>
                    <option value="amount">Nominal (Rupiah)</option>
                  </select>
                </label>
                {discountMode && (
                  <input
                    type="number"
                    value={discountValue}
                    onChange={e => setDiscountValue(e.target.value)}
                    placeholder={discountMode === 'percent' ? '0-100' : 'Nominal Rupiah'}
                  />
                )}
              </div>
            </div>
          )}

          <div className="form-group">
            <label>ID Pelanggan (opsional)
              <input value={customer} onChange={e => setCustomer(e.target.value)} placeholder="Contoh: UUID" />
            </label>
          </div>

          {error && <div className="error" role="alert">{error}</div>}

          <button
            onClick={finalize}
            disabled={cart.length === 0 || busy}
            className="primary"
          >
            {busy ? 'Finalisasi…' : `Bayar ${paymentMethod} Rp${rupiahHalfUp(total.toFixed(0))}`}
          </button>

          <div className="note">
            <small>
              Scan barcode keyboard HID → Enter. Scanner harus mode keyboard emulation.
            </small>
          </div>
        </div>
      </div>
    </section>
  )
}

export function Receipt() {
  const { invoiceId } = useParams<{ invoiceId: string }>()
  const navigate = useNavigate()

  const [invoice, setInvoice] = useState<null | {
    id: string
    number: string
    posted_at: string
    subtotal_net_lines: string
    discount_total: string
    total: string
    items: { id: string; description: string; qty_sell: string; unit_price: string; net_total: string }[]
  }>(null)
  const [error, setError] = useState('')
  const [shop, setShop] = useState<{ name: string; address: string; phone: string; receipt_width: number } | null>(null)

  const loadInvoice = useCallback(async () => {
    if (!supabase || !invoiceId) return
    try {
      const { data, error } = await supabase.rpc('get_invoice_v1', { p_input: { invoice_id: invoiceId } })
      if (error || !data) throw error || new Error('Gagal memuat struk')
      setInvoice(data as never)
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal memuat struk')
    }
  }, [invoiceId])

  const loadShop = useCallback(async () => {
    if (!supabase) return
    const { data } = await supabase.rpc('get_shop_settings_v1')
    if (data) setShop(data as never)
  }, [])

  useEffect(() => { void loadShop() }, [loadShop])

  useEffect(() => {
    if (!invoiceId) return
    if (!configured || !supabase) {
      setError('Supabase belum dikonfigurasi')
      return
    }
    loadInvoice()
  }, [invoiceId, loadInvoice])

  if (!invoiceId) return <div className="empty">ID struk tidak ditemukan</div>
  if (error) return <div className="error">{error}</div>
  if (!invoice) return <p>Memuat struk…</p>

  const date = new Date(invoice.posted_at).toLocaleString('id-ID')
  const subtotal = Number(invoice.subtotal_net_lines)
  const disc = Number(invoice.discount_total)
  const total = Number(invoice.total)
  const items = invoice.items || []

  return (
    <section className={`receipt-view receipt-w${shop?.receipt_width === 80 ? '80' : '58'}`}>
      <header className="receipt-header">
        <h2>{shop?.name || 'Nama toko belum diisi'}</h2>
        {shop?.address && <p>{shop.address}</p>}
        {shop?.phone && <p>{shop.phone}</p>}
        <p><strong>No. {invoice.number}</strong></p>
        <p>{date}</p>
      </header>

      <div className="receipt-body">
        <table>
          <thead>
            <tr>
              <th>Barang</th>
              <th>Qty</th>
              <th>Harga</th>
              <th>Net</th>
            </tr>
          </thead>
          <tbody>
            {items.map((i: { id: string; description: string; qty_sell: string; unit_price: string; net_total: string }) => (
              <tr key={i.id}>
                <td>{i.description}</td>
                <td>{i.qty_sell}</td>
                <td>Rp{Number(i.unit_price).toLocaleString('id-ID')}</td>
                <td>Rp{Number(i.net_total).toLocaleString('id-ID')}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="receipt-summary">
          <div>Subtotal: Rp{subtotal.toLocaleString('id-ID')}</div>
          <div>Diskon: Rp{disc.toLocaleString('id-ID')}</div>
          <div className="total">Total: <strong>Rp{total.toLocaleString('id-ID')}</strong></div>
        </div>
      </div>

      <footer className="receipt-footer">
        <button onClick={() => window.print()}>Cetak</button>
        <button className="ghost" onClick={() => navigate('/kasir')}>Kembali</button>
      </footer>
    </section>
  )
}
