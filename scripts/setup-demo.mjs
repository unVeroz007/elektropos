#!/usr/bin/env node
/**
 * Setup demo ElektroPOS pada Supabase lokal.
 * - Membuat akun uji owner/staff/maintainer
 * - Menyiapkan profil peran, identitas toko, katalog contoh
 * - Membuka sesi kas dan mengisi stok awal
 *
 * Prasyarat: `npx supabase start` sudah berjalan.
 * Jalankan: npm run setup:demo
 */
import { execFileSync } from 'child_process'
import { existsSync } from 'fs'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const __dirname = resolve(fileURLToPath(import.meta.url), '..')
const root = join(__dirname, '..')

const API = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:55000'
const DB_URL = process.env.DEMO_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54500/postgres'
const PUBLISHABLE = process.env.VITE_SUPABASE_PUBLISHABLE_KEY
const SECRET = process.env.SUPABASE_SECRET_KEY

if (!PUBLISHABLE) {
  console.error('VITE_SUPABASE_PUBLISHABLE_KEY belum diset.')
  console.error('Jalankan `npx supabase status` lalu salin Publishable key ke .env')
  process.exit(1)
}
if (!SECRET) {
  console.error('SUPABASE_SECRET_KEY belum diset (kunci Secret/Service lokal).')
  console.error('Jalankan `npx supabase status` lalu set SUPABASE_SECRET_KEY untuk setup demo.')
  console.error('Kunci ini HANYA untuk lingkungan lokal; jangan commit ke repository.')
  process.exit(1)
}

const ACCOUNTS = [
  { email: 'owner@elektropos.local', password: 'Owner123!', role: 'OWNER' },
  { email: 'staff@elektropos.local', password: 'Staff123!', role: 'STAFF' },
  { email: 'admin@elektropos.local', password: 'Admin123!', role: 'MAINTAINER' },
]

function psqlFile(path) {
  execFileSync('cmd', ['/c', 'psql', DB_URL, '-v', 'ON_ERROR_STOP=1', '-q', '-f', path], {
    stdio: ['pipe', 'pipe', 'pipe'],
  })
}

async function ensureUser(account) {
  const res = await fetch(`${API}/auth/v1/admin/users`, {
    method: 'POST',
    headers: {
      apikey: SECRET,
      Authorization: `Bearer ${SECRET}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email: account.email, password: account.password, email_confirm: true }),
  })
  if (res.ok) return 'dibuat'
  const body = await res.text()
  if (res.status === 422 || body.includes('already been registered') || body.includes('duplicate')) {
    return 'sudah ada'
  }
  throw new Error(`Gagal membuat akun ${account.email}: ${res.status} ${body}`)
}

async function rpc(action, token, params, label) {
  const res = await fetch(`${API}/rest/v1/rpc/${action}`, {
    method: 'POST',
    headers: {
      apikey: PUBLISHABLE,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(params),
  })
  const body = await res.text()
  if (!res.ok) throw new Error(`${label}: ${res.status} ${body}`)
  return JSON.parse(body)
}

async function login(email, password) {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  if (!res.ok) throw new Error(`Login ${email} gagal: ${res.status}`)
  return (await res.json()).access_token
}

function uid() { return crypto.randomUUID() }

async function main() {
  console.log('ElektroPOS — setup demo')
  console.log(`API : ${API}`)
  console.log(`DB  : ${DB_URL}`)
  console.log('')

  console.log('[1/5] Reset database + migrasi')
  execFileSync('cmd', ['/c', 'npx supabase db reset'], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] })
  console.log('       OK')

  console.log('[2/5] Buat akun uji')
  for (const acc of ACCOUNTS) {
    const status = await ensureUser(acc)
    console.log(`       ${acc.email.padEnd(28)} ${acc.role.padEnd(11)} ${status}`)
  }

  console.log('[3/5] Profil peran + katalog contoh')
  if (!existsSync(join(root, 'supabase', 'seeds', 'demo.sql'))) {
    throw new Error('supabase/seeds/demo.sql tidak ditemukan')
  }
  // demo.sql berisi DO block; jalankan via psql
  psqlFile(join(root, 'supabase', 'seeds', 'demo.sql'))
  console.log('       OK')

  console.log('[4/5] Buka sesi kas + stok awal')
  const token = await login('owner@elektropos.local', 'Owner123!')

  try {
    await rpc('open_cash_session_v1', token, {
      p_input: { operation_id: uid(), cashbox_code: 'SHOP_DRAWER', opening_amount: '300000' },
    }, 'Buka kas')
  } catch (e) {
    if (!String(e.message).includes('Kas masih terbuka')) throw e
  }

  const products = await rpc('search_products_v1', token, { p_input: { query: 'DEMO-', limit: 50 } }, 'Cari produk')
  let stocked = 0
  for (const p of products) {
    const baseUnit = p.units.find(u => u.is_default !== false) || p.units[0]
    if (!baseUnit) continue
    const isSegment = p.track_segments === true
    const qty = isSegment ? '50' : '20'
    const cost = isSegment ? '250000' : '120000'
    try {
      await rpc('post_opening_stock_v1', token, {
        p_input: {
          operation_id: uid(),
          reason: 'Stok awal demo',
          items: [{
            product_unit_id: baseUnit.id,
            qty,
            acquisition_cost: cost,
            ...(isSegment ? {
              positions: [{ qty_base: '50', segment_capacity: '100', sealed: false, label: `DEMO-${p.sku}` }],
            } : {}),
          }],
        },
      }, `Stok ${p.sku}`)
      stocked++
    } catch (e) {
      console.log(`       Lewati ${p.sku}: ${String(e.message).split('\n')[0]}`)
    }
  }
  console.log(`       ${stocked} produk diberi stok`)

  console.log('[5/5] Selesai')
  console.log('')
  console.log('=== Akun demo ===')
  for (const acc of ACCOUNTS) {
    console.log(`  ${acc.role.padEnd(11)} ${acc.email.padEnd(28)} ${acc.password}`)
  }
  console.log('')
  console.log('Jalankan aplikasi: npm run dev  →  ' + (process.env.APP_URL || 'http://localhost:5173'))
}

main().catch(err => {
  console.error('')
  console.error('Setup demo gagal:', err.message)
  process.exit(1)
})
