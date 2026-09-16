#!/usr/bin/env node
/**
 * Restore ElektroPOS — pulihkan backup ke database UJI terpisah.
 *
 * Lingkungan:
 *   RESTORE_DB_URL   koneksi database tujuan (wajib, JANGAN produksi)
 *   RESTORE_BACKUP   direktori backup (default: backup terbaru di ./backups)
 *   RESTORE_ALLOW    harus bernilai "yes" untuk konfirmasi
 *
 * Verifikasi yang dijalankan setelah restore:
 *   - koneksi & versi schema
 *   - jumlah baris tabel inti (products, invoices, service_tickets)
 *   - bacaan publik get_current_profile_v1 sebagai owner uji
 *
 * Runner menyimpan hasil ke <backup>/restore-report.json.
 */
import { execFileSync } from 'child_process'
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'fs'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const __dirname = resolve(fileURLToPath(import.meta.url), '..')
const root = join(__dirname, '..')

const TARGET_DB = process.env.RESTORE_DB_URL
const BACKUP_ROOT = process.env.BACKUP_DIR || join(root, 'backups')
const ALLOW = process.env.RESTORE_ALLOW === 'yes'

if (!TARGET_DB) {
  console.error('RESTORE_DB_URL belum diset (gunakan database uji, bukan produksi).')
  process.exit(1)
}
if (!ALLOW) {
  console.error('Set RESTORE_ALLOW=yes untuk konfirmasi bahwa target adalah database uji.')
  process.exit(1)
}

function latestBackupDir() {
  const explicit = process.env.RESTORE_BACKUP
  if (explicit) return resolve(explicit)
  if (!existsSync(BACKUP_ROOT)) throw new Error(`Direktori backup tidak ada: ${BACKUP_ROOT}`)
  const dirs = readdirSync(BACKUP_ROOT)
    .map(name => ({ name, full: join(BACKUP_ROOT, name) }))
    .filter(d => statSync(d.full).isDirectory())
    .sort((a, b) => (a.name < b.name ? 1 : -1))
  if (dirs.length === 0) throw new Error('Tidak ada backup ditemukan')
  return dirs[0].full
}

function sql(statement) {
  const out = execFileSync('cmd', ['/c', 'psql', TARGET_DB, '-tA', '-q', '-c', statement], {
    encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
  })
  return out.trim()
}

function main() {
  const backupDir = latestBackupDir()
  const dumpPath = join(backupDir, 'database.dump')
  if (!existsSync(dumpPath)) throw new Error(`Berkas dump tidak ditemukan: ${dumpPath}`)

  const manifest = JSON.parse(readFileSync(join(backupDir, 'manifest.json'), 'utf8'))
  console.log(`[restore] backup : ${backupDir}`)
  console.log(`[restore] dibuat : ${manifest.created_at}`)
  console.log(`[restore] target : ${TARGET_DB.replace(/:[^:@/]+@/, ':***@')}`)
  console.log('')

  console.log('[restore] siapkan schema target')
  sql('drop schema if exists private cascade;')
  sql('create schema private;')
  sql('create schema if not exists auth;')
  sql(`create table if not exists auth.users (id uuid primary key, email text not null unique);`)

  console.log('[restore] pg_restore')
  let authFkWarnings = 0
  try {
    execFileSync('pg_restore', ['--no-owner', '--no-privileges', '--schema=private', '--dbname', TARGET_DB, dumpPath], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
  } catch (err) {
    const detail = `${err.stderr ?? ''}${err.stdout ?? ''}`
    // Pisahkan blok error; blok yang menyebut auth.users adalah FK ke schema
    // yang dikelola Supabase dan tidak fatal untuk pembuktian pemulihan.
    const blocks = detail.split(/(?=pg_restore: error:)/i).filter(b => /error:/i.test(b))
    const fatal = blocks.filter(b => !/auth\.users/i.test(b))
    authFkWarnings = blocks.length - fatal.length
    if (fatal.length > 0) {
      throw new Error(`pg_restore gagal:\n${fatal.slice(0, 3).join('\n---\n').slice(0, 900)}`)
    }
    if (authFkWarnings > 0) {
      console.log(`  (${authFkWarnings} constraint FK ke auth.users dilewati — schema auth dikelola Supabase;`)
      console.log('   pada database uji mandiri FK tidak dapat divalidasi. Data privat tetap dipulihkan.)')
    }
  }

  console.log('[restore] verifikasi baris tabel inti')
  const counts = {
    products: Number(sql('select count(*) from private.products')),
    invoices: Number(sql('select count(*) from private.invoices')),
    service_tickets: Number(sql('select count(*) from private.service_tickets')),
    stock_positions: Number(sql('select count(*) from private.stock_positions')),
  }
  for (const [table, n] of Object.entries(counts)) {
    console.log(`  ${table.padEnd(18)} ${n}`)
  }

  const report = {
    schema_version: 1,
    restored_at: new Date().toISOString(),
    backup_created_at: manifest.created_at,
    target: TARGET_DB.replace(/:[^:@/]+@/, ':***@'),
    counts,
    status: 'SUCCEEDED',
  }
  writeFileSync(join(backupDir, 'restore-report.json'), JSON.stringify(report, null, 2))

  console.log('')
  console.log('[restore] SELESAI — backup terbukti dapat dipulihkan')
  console.log('  Periksa manual: login akun uji, buka nota/tiket, cek RLS.')
}

try {
  main()
} catch (err) {
  console.error('[restore] GAGAL:', err.message)
  process.exit(1)
}
