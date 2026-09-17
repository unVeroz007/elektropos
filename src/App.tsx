import { useEffect, useState, lazy, Suspense } from 'react'
import { Link, Navigate, Route, Routes } from 'react-router-dom'
import type { User } from '@supabase/supabase-js'
import { configured, supabase } from './lib/supabase'

const Cashier = lazy(() => import('./features/cashier').then(m => ({ default: m.Cashier })))
const Receipt = lazy(() => import('./features/cashier').then(m => ({ default: m.Receipt })))
const History = lazy(() => import('./features/history').then(m => ({ default: m.History })))
const CashSession = lazy(() => import('./features/cashsession').then(m => ({ default: m.CashSession })))
const ReturnSale = lazy(() => import('./features/return').then(m => ({ default: m.ReturnSale })))
const ServiceTickets = lazy(() => import('./features/service').then(m => ({ default: m.ServiceTickets })))
const Dashboard = lazy(() => import('./features/dashboard').then(m => ({ default: m.Dashboard })))
const Reports = lazy(() => import('./features/dashboard').then(m => ({ default: m.Reports })))
const Customers = lazy(() => import('./features/admin').then(m => ({ default: m.Customers })))
const Settings = lazy(() => import('./features/admin').then(m => ({ default: m.Settings })))
const Health = lazy(() => import('./features/admin').then(m => ({ default: m.Health })))
const StockIntake = lazy(() => import('./features/intake').then(m => ({ default: m.StockIntake })))
const NewProduct = lazy(() => import('./features/catalog').then(m => ({ default: m.NewProduct })))
const BarcodeManager = lazy(() => import('./features/catalog').then(m => ({ default: m.BarcodeManager })))

type Profile = { id: string; display_name: string; role: 'OWNER' | 'STAFF' | 'MAINTAINER'; active: boolean }
type Product = { id: string; sku: string; name: string; specification: string; base_unit: string; shelf: string | null; units: { id: string; label: string; sell_price: string; factor_base: string }[]; stock_shop: string; stock_field: string }

function Login({ onLogin }: { onLogin: () => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setBusy(true); setError('')
    const result = await supabase.auth.signInWithPassword({ email, password })
    setBusy(false)
    if (result.error) setError('Email atau sandi tidak sesuai, atau layanan belum tersedia.')
    else { setPassword(''); onLogin() }
  }
  return <main className="login-wrap"><section className="login-card">
    <div className="eyebrow">TOKO LISTRIK & SERVIS ELEKTRONIK</div>
    <h1>ElektroPOS</h1><p>Masuk dengan akun pribadi untuk melihat data toko yang Anda izinkan.</p>
    {!configured && <div className="notice">Koneksi uji belum disetel. Salin .env.example ke .env dan isi URL serta kunci publik Supabase lokal.</div>}
    <form onSubmit={submit}><label>Email<input type="email" autoComplete="username" value={email} onChange={e => setEmail(e.target.value)} required /></label>
      <label>Sandi<input type="password" autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} required /></label>
      {error && <div role="alert" className="error">{error}</div>}
      <button disabled={busy || !configured}>{busy ? 'Memeriksa akun…' : 'Masuk'}</button></form>
    <small>Akun disiapkan pengelola. Tidak ada pendaftaran umum.</small>
  </section></main>
}

function Catalog({ profile }: { profile: Profile }) {
  const [query, setQuery] = useState('')
  const [products, setProducts] = useState<Product[]>([])
  const [busy, setBusy] = useState(true)
  const [error, setError] = useState('')
  useEffect(() => {
    let alive = true
    async function load() {
      if (!supabase) return
      setBusy(true)
      const { data, error } = await supabase.rpc('search_products_v1', { p_input: { query, limit: 25 } })
      if (alive) { setProducts((data as Product[]) ?? []); setError(error ? 'Katalog belum dapat dibaca. Periksa koneksi atau izin akun.' : ''); setBusy(false) }
    }
    const timer = setTimeout(load, 250)
    return () => { alive = false; clearTimeout(timer) }
  }, [query])
  return <section><div className="section-head"><div><div className="eyebrow">DATA UJI / DATA TOKO BERIZIN</div><h2>Katalog & stok</h2><p>Harga jual dan stok dibaca langsung dari database.</p></div>{profile.role === 'OWNER' && <Link className="button-link" to="/produk/baru">Tambah produk</Link>}</div>
    <label className="search-label">Cari nama, SKU, atau barcode<input placeholder="Contoh: kabel NYA, 001234…" value={query} onChange={e => setQuery(e.target.value)} maxLength={120} /></label>
    {busy && <p>Memuat katalog…</p>}{error && <div role="alert" className="error">{error}</div>}
    {!busy && !error && products.length === 0 && <div className="empty">Belum ada produk yang cocok. Produk uji dibuat melalui fixture terpisah.</div>}
    <div className="products">{products.map(product => <article className="product" key={product.id}><div className="product-top"><span className="sku">{product.sku}</span><span>{product.shelf || 'Rak belum diisi'}</span></div><h3>{product.name}</h3><p>{product.specification || 'Spesifikasi belum diisi'}</p><div className="unit-list">{product.units.map(unit => <span key={unit.id}>{unit.label} · Rp{Number(unit.sell_price).toLocaleString('id-ID')} / {unit.label} · {unit.factor_base} {product.base_unit}</span>)}</div><div className="stock-row"><span>Toko <strong>{product.stock_shop} {product.base_unit}</strong></span><span>Dibawa ayah <strong>{product.stock_field} {product.base_unit}</strong></span></div></article>)}</div>
  </section>
}

export default function App() {
  const [user, setUser] = useState<User | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  useEffect(() => {
    if (!supabase) { setLoading(false); return }
    let alive = true
    async function refresh() {
      if (!supabase) return
      const { data: session } = await supabase.auth.getUser()
      if (!alive) return
      setUser(session.user)
      if (session.user) {
        const { data, error } = await supabase.rpc('get_current_profile_v1')
        if (!alive) return
        setProfile(error ? null : data as Profile)
        setError(error ? 'Akun tidak aktif atau profil tidak dapat dibaca.' : '')
      } else { setProfile(null); setError('') }
      setLoading(false)
    }
    refresh()
    const { data: listener } = supabase.auth.onAuthStateChange(() => { setTimeout(refresh, 0) })
    return () => { alive = false; listener.subscription.unsubscribe() }
  }, [])
  async function logout() { await supabase?.auth.signOut({ scope: 'local' }); setUser(null); setProfile(null) }
  if (loading) return <div className="loading">Menghubungkan ElektroPOS…</div>
  if (!user || !profile) return <>{error && <div className="floating-error">{error}</div>}<Login onLogin={() => { setLoading(true); supabase?.auth.getUser().then(() => { /* perubahan sesi diproses listener */ }) }} /></>

  const isOwner = profile.role === 'OWNER'
  const isStaff = profile.role === 'STAFF'
  const isMaintainer = profile.role === 'MAINTAINER'
  const home = isStaff ? '/kasir' : '/beranda'

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-icon">E</span>
          <div><strong>ElektroPOS</strong><small>Operasional toko</small></div>
        </div>

        <nav>
          <div className="nav-group">
            <Link to="/beranda">Beranda</Link>
            <Link to="/kasir">Kasir</Link>
            <Link to="/riwayat">Riwayat Nota</Link>
          </div>

          <div className="nav-group">
            <span className="nav-label">Servis</span>
            <Link to="/servis">Tiket Servis</Link>
            <Link to="/pelanggan">Pelanggan</Link>
          </div>

          <div className="nav-group">
            <span className="nav-label">Persediaan</span>
            <Link to="/katalog">Katalog</Link>
            {isOwner && <Link to="/barang-masuk">Barang Masuk</Link>}
            {isOwner && <Link to="/barcode">Daftar Barcode</Link>}
          </div>

          {isOwner && (
            <div className="nav-group">
              <span className="nav-label">Uang &amp; Laporan</span>
              <Link to="/kas">Kas Laci</Link>
              <Link to="/laporan">Laporan</Link>
            </div>
          )}

          {(isOwner || isMaintainer) && (
            <div className="nav-group">
              <span className="nav-label">Pengaturan</span>
              {isOwner && <Link to="/pengaturan">Identitas Toko</Link>}
              <Link to="/kesehatan">Kesehatan Sistem</Link>
            </div>
          )}
        </nav>

        <div className="sidebar-foot">Data sesuai izin akun Anda</div>
      </aside>

      <div className="main">
        <header>
          <div className="who">
            <span className="online-dot" />
            Masuk sebagai <strong>{profile.display_name}</strong>
            <span className="role">{profile.role === 'OWNER' ? 'Pemilik' : profile.role === 'STAFF' ? 'Karyawan' : 'Teknis'}</span>
          </div>
          <button className="ghost" onClick={logout}>Keluar</button>
        </header>
        <main>
          <Suspense fallback={<div className="loading">Memuat halaman…</div>}>
            <Routes>
              <Route path="/beranda" element={<Dashboard />} />
              <Route path="/kasir" element={<Cashier profile={profile} />} />
              <Route path="/struk/:invoiceId" element={<Receipt />} />
              <Route path="/servis" element={<ServiceTickets />} />
              <Route path="/pelanggan" element={<Customers />} />
              <Route path="/riwayat" element={<History />} />
              <Route path="/laporan" element={isOwner || isMaintainer ? <Reports /> : <Navigate to="/kasir" />} />
              <Route path="/kesehatan" element={isOwner || isMaintainer ? <Health /> : <Navigate to="/kasir" />} />
              <Route path="/pengaturan" element={isOwner ? <Settings /> : <Navigate to="/kasir" />} />
              <Route path="/barang-masuk" element={isOwner ? <StockIntake profile={profile} /> : <Navigate to="/kasir" />} />
              <Route path="/barcode" element={isOwner ? <BarcodeManager /> : <Navigate to="/kasir" />} />
              <Route path="/retur/:invoiceId" element={<ReturnSale profile={profile} />} />
              <Route path="/kas" element={isOwner ? <CashSession /> : <Navigate to="/kasir" />} />
              <Route path="/katalog" element={<Catalog profile={profile} />} />
              <Route path="/produk/baru" element={isOwner ? <NewProduct /> : <Navigate to="/kasir" />} />
              <Route path="*" element={<Navigate to={home} />} />
            </Routes>
          </Suspense>
        </main>
      </div>
    </div>
  )
}
