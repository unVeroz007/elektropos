#!/usr/bin/env node
/**
 * Setup demo ElektroPOS pada Supabase lokal — idempoten dan TIDAK menghapus data.
 *
 * - Membuat akun uji owner/staff/maintainer (Auth admin API, kunci rahasia lokal).
 * - Profil peran, identitas toko "(DEMO)", katalog contoh (supabase/seeds/demo.sql).
 * - Membuka laci toko bila tertutup dan mengisi stok awal hanya untuk barang contoh yang stoknya kosong.
 *
 * Pengaman (keputusan D4: produksi awal memakai Supabase lokal): skrip menolak berjalan bila
 * identitas toko sudah diisi dengan nama bukan demo, kecuali DEMO_ALLOW_REAL=yes.
 * Menghapus seluruh data untuk mulai ulang: `DEMO_RESET=yes npm run setup:demo` (hanya lingkungan uji).
 */
import { execFileSync } from 'child_process'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const root = join(resolve(fileURLToPath(import.meta.url), '..'), '..')
const API = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:55000'
const DB_URL = process.env.DEMO_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54500/postgres'
const PUBLISHABLE = process.env.VITE_SUPABASE_PUBLISHABLE_KEY
const SECRET = process.env.SUPABASE_SECRET_KEY

const ACCOUNTS = [
  { email: 'owner@elektropos.local', password: 'Owner123!', role: 'OWNER' },
  { email: 'staff@elektropos.local', password: 'Staff123!', role: 'STAFF' },
  { email: 'admin@elektropos.local', password: 'Admin123!', role: 'MAINTAINER' },
]
const DEMO_MARKER = '(DEMO)'

function fail(message) {
  console.error(`\nSetup demo dihentikan: ${message}`)
  process.exit(1)
}

if (!PUBLISHABLE) fail('VITE_SUPABASE_PUBLISHABLE_KEY belum diset di .env (lihat `npx supabase status`).')
if (!SECRET) fail('SUPABASE_SECRET_KEY belum diset di .env. Kunci ini hanya untuk lingkungan lokal; jangan di-commit.')

function psql(args) {
  try {
    return execFileSync('psql', [DB_URL, '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', ...args], {
      encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
    }).trim()
  } catch (err) {
    throw new Error(`${err.stderr ?? ''}${err.stdout ?? ''}`.trim() || err.message)
  }
}

async function api(path, init) {
  const res = await fetch(`${API}${path}`, init)
  const text = await res.text()
  let body
  try { body = JSON.parse(text) } catch { body = text }
  return { ok: res.ok, status: res.status, body, text }
}

async function ensureUser(account) {
  const res = await api('/auth/v1/admin/users', {
    method: 'POST',
    headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: account.email, password: account.password, email_confirm: true }),
  })
  if (res.ok) return 'dibuat'
  if (res.status === 422 || /already been registered|already exists|duplicate/i.test(res.text)) return 'sudah ada'
  throw new Error(`Gagal membuat akun ${account.email}: ${res.status}`)
}

async function login(email, password) {
  const res = await api('/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: { apikey: PUBLISHABLE, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  if (!res.ok) throw new Error(`Login ${email} gagal (${res.status})`)
  return res.body.access_token
}

async function rpc(token, name, input) {
  const res = await api(`/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(input === undefined ? {} : { p_input: input }),
  })
  if (!res.ok) throw new Error(`${name}: ${res.body?.message ?? res.text}`)
  return res.body
}

const opId = () => crypto.randomUUID()

/** Stok awal per barang contoh. Kabel: 1 roll bersegel 100 m + 1 potongan 50 m (BR-03). */
function openingItem(product, unit) {
  if (product.track_segments) {
    return {
      product_unit_id: unit.id, qty: '150', acquisition_cost: '975000',
      rolls: { count: '1', capacity: '100', label_prefix: `${product.sku}-R` },
      positions: [{ label: `${product.sku}-P1`, qty_base: '50', segment_capacity: '100', sealed: false }],
    }
  }
  return { product_unit_id: unit.id, qty: '20', acquisition_cost: String(20 * Math.round(Number(unit.sell_price) * 0.7)) }
}

async function main() {
  console.log('ElektroPOS — setup demo')
  console.log(`API : ${API}`)
  console.log('')

  const shop = psql(['-c', "select coalesce(name, '') || '|' || case when configured_at is null then 'no' else 'yes' end from private.shop_settings where id"])
  const [name, configured] = shop.split('|')
  if (process.env.DEMO_RESET === 'yes') {
    console.log('[0] DEMO_RESET=yes → supabase db reset (semua data dihapus)')
    execFileSync('npx', ['supabase', 'db', 'reset', '--local'], { cwd: root, stdio: 'inherit', shell: true })
  } else if (configured === 'yes' && !name.includes(DEMO_MARKER) && process.env.DEMO_ALLOW_REAL !== 'yes') {
    fail(`database ini berisi identitas toko "${name}". Data contoh tidak ditambahkan ke data toko nyata.\n`
      + 'Jika ini memang lingkungan uji, jalankan ulang dengan DEMO_ALLOW_REAL=yes.')
  }

  console.log('[1/4] Akun uji')
  for (const acc of ACCOUNTS) console.log(`      ${acc.email.padEnd(26)} ${acc.role.padEnd(10)} ${await ensureUser(acc)}`)

  console.log('[2/4] Profil peran, identitas toko, katalog contoh')
  psql(['-f', join(root, 'supabase', 'seeds', 'demo.sql')])
  console.log('      OK')

  const owner = await login(ACCOUNTS[0].email, ACCOUNTS[0].password)

  console.log('[3/4] Laci kas toko')
  const drawer = await rpc(owner, 'get_cash_session_v1', { cashbox_code: 'SHOP_DRAWER' })
  if (drawer.open) {
    console.log('      sudah terbuka')
  } else {
    const amount = drawer.last_counted_amount ?? '300000'
    await rpc(owner, 'open_cash_session_v1', { operation_id: opId(), cashbox_code: 'SHOP_DRAWER', opening_amount: amount })
    console.log(`      dibuka dengan ${amount}`)
  }

  console.log('[4/4] Stok awal barang contoh yang masih kosong')
  const products = await rpc(owner, 'search_products_v1', { query: 'DEMO-', limit: 50 })
  let stocked = 0
  for (const product of products.filter(p => p.sku.startsWith('DEMO-'))) {
    if (Number(product.stock_shop) > 0 || Number(product.stock_field) > 0) continue
    const unit = product.units.find(u => Number(u.factor_base) === 1) ?? product.units[0]
    if (!unit) continue
    await rpc(owner, 'post_opening_stock_v1', { operation_id: opId(), reason: 'Stok awal demo', items: [openingItem(product, unit)] })
    stocked++
  }
  console.log(`      ${stocked} barang diberi stok`)

  // Kabel contoh harus punya satu roll bersegel agar alur "jual roll utuh" dapat dicoba.
  for (const product of products.filter(p => p.sku.startsWith('DEMO-') && p.track_segments)) {
    const { positions } = await rpc(owner, 'list_sellable_positions_v1', { product_id: product.id })
    if (positions.some(p => p.sealed)) continue
    const meter = product.units.find(u => Number(u.factor_base) === 1)
    if (!meter) continue
    await rpc(owner, 'post_opening_stock_v1', {
      operation_id: opId(), reason: 'Roll bersegel demo',
      items: [{ product_unit_id: meter.id, qty: '100', acquisition_cost: '650000', rolls: { count: '1', capacity: '100' } }],
    })
    console.log(`      roll bersegel 100 m ditambahkan untuk ${product.sku}`)
  }

  console.log('')
  console.log('=== Akun demo (khusus lingkungan uji) ===')
  for (const acc of ACCOUNTS) console.log(`  ${acc.role.padEnd(10)} ${acc.email.padEnd(26)} ${acc.password}`)
  console.log(`\nJalankan aplikasi: npm run dev → ${process.env.APP_URL || 'http://localhost:5173'}`)
}

main().catch(err => fail(err.message))
