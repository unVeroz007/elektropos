import { execFileSync } from 'child_process'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const __dirname = resolve(fileURLToPath(import.meta.url), '..')
const root = join(__dirname, '..')
// Default hanya untuk Supabase lokal. Set TEST_DB_URL untuk target lain.
const DB_URL = process.env.TEST_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:54500/postgres'

function psqlFile(path) {
  try {
    execFileSync('cmd', ['/c', 'psql', DB_URL, '-v', 'ON_ERROR_STOP=1', '-q', '-f', path], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    })
  } catch (err) {
    const detail = `${err.stderr ?? ''}${err.stdout ?? ''}`.trim()
    throw new Error(`Failed to run ${path}:\n${detail}`)
  }
}

const pass = (label) => console.log(`  PASS  ${label}`)
const fail = (label, detail) => {
  console.error(`  FAIL  ${label}`)
  if (detail) console.error(detail.split('\n').filter(l => l.trim()).slice(0, 5).join('\n'))
  process.exitCode = 1
}

console.log('ElektroPOS — uji database P0-P3')
console.log(`Database : ${DB_URL}`)
console.log('')

// Setup: reset via supabase CLI (handles migrations + seed properly)
console.log('[setup] supabase db reset')
try {
  execFileSync('cmd', ['/c', 'npx supabase db reset'], {
    encoding: 'utf8', cwd: root, stdio: ['pipe', 'pipe', 'pipe'],
  })
  console.log('  OK')
} catch (err) {
  console.error('  FAIL:', (err.stderr || err.stdout || err.message || '').slice(0, 500))
  process.exit(1)
}

console.log('')
console.log('[P0] AT-01/02 — autentikasi & akses')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p0_auth_access.sql'))
  pass('AT-01 owner aktif, akun nonaktif ditolak, anon ditolak')
  pass('AT-02 staff/maintainer ditolak write bisnis & baca modal')
} catch (err) { fail('P0', err.message) }

console.log('')
console.log('[P1] AT-15/16 — stok awal, idempotensi, transfer')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p1_stock.sql'))
  pass('AT-15 stok awal + idempotensi, AT-16 transfer + kerusakan')
} catch (err) { fail('P1', err.message) }

console.log('')
console.log('[P2] AT-07/09/10/13/24/25 — kasir, diskon, retur, kas')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p2_cashier.sql'))
  pass('AT-09/10 sale tunai + idempoten, AT-07 diskon, AT-13 retur, AT-24/25 kas')
} catch (err) { fail('P2', err.message) }

console.log('')
console.log('[P1+P2] AT-05/06/11/14 — presisi, roll, FIFO, stok habis')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p1_p2_extra.sql'))
  pass('AT-05 presisi 0.1m x10, AT-06 roll sealed, AT-11 stok habis, AT-14 invariant')
} catch (err) { fail('P1+P2 extra', err.message) }

console.log('')
console.log('[P3] AT-17/18/19/20/22/23 — servis, estimasi, part, handover')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p3_service.sql'))
  pass('AT-17 tiket, AT-18 transisi, AT-19 part, AT-20 DP, AT-22 handover, AT-23 kembali')
} catch (err) { fail('P3', err.message) }

console.log('')
console.log('[P4] AT-03/04/21/26/27 — barcode, satuan, laporan, CSV, lampiran')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p4_extra.sql'))
  pass('AT-03 barcode/SKU arsip, AT-04 satuan, AT-26 laporan peran, AT-27 CSV+attach')
} catch (err) { fail('P4', err.message) }

console.log('')
console.log('[P4] AT-21 — DP berlebih dan refund servis')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p4_at21.sql'))
  pass('AT-21 DP 100rb, tagihan 80rb, refund_due 20rb, refund ditolak berlebih')
} catch (err) { fail('AT-21', err.message) }

console.log('')
console.log('[P4] AT-29 — pengaturan toko, kesehatan, backup manifest')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p4_setup_health.sql'))
  pass('AT-29 settings checklist, validasi lebar struk, health per peran')
} catch (err) { fail('AT-29', err.message) }

console.log('')
console.log('[P4] AT-03 — daftar barcode fisik ke produk')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p4_barcode.sql'))
  pass('AT-03 barcode fisik, duplikat ditolak, staff ditolak, unit lintas produk ditolak')
} catch (err) { fail('AT-03 barcode', err.message) }

console.log('')
console.log('[P2] AT-08 — harga berubah (PRICE_CHANGED)')
try {
  psqlFile(join(root, 'supabase', 'tests', 'p2_price_changed.sql'))
  pass('AT-08 versi satuan lama ditolak, versi terbaru diterima')
} catch (err) { fail('AT-08', err.message) }

console.log('')
if (process.exitCode) {
  console.error('HASIL: FAIL')
} else {
  console.log('HASIL: PASS')
}
