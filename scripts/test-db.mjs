#!/usr/bin/env node
/**
 * Uji penerimaan database ElektroPOS pada DATABASE UJI TERISOLASI.
 *
 * Runner ini TIDAK PERNAH menyentuh database aplikasi (`postgres`) dan tidak
 * menjalankan `supabase db reset`. Ia membuat database baru di cluster yang sama,
 * menerapkan bootstrap + seluruh migrasi + fixture, lalu menjalankan setiap berkas
 * supabase/tests/*.sql. Database uji dihapus lalu dibuat ulang setiap kali jalan.
 *
 * Lingkungan:
 *   TEST_ADMIN_URL  koneksi admin cluster (default Supabase lokal, db `postgres`)
 *   TEST_DB_NAME    nama database uji (default `elektropos_test`; wajib diawali `elektropos_test`)
 *   TEST_KEEP_DB    `yes` agar database uji tidak dihapus setelah selesai
 *
 * Argumen opsional: pola nama berkas uji, mis. `node scripts/test-db.mjs sales`
 */
import { execFileSync } from 'child_process'
import { readdirSync } from 'fs'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const root = join(resolve(fileURLToPath(import.meta.url), '..'), '..')
const ADMIN_URL = process.env.TEST_ADMIN_URL || 'postgresql://postgres:postgres@127.0.0.1:54500/postgres'
const DB_NAME = process.env.TEST_DB_NAME || 'elektropos_test'
const KEEP = process.env.TEST_KEEP_DB === 'yes'
const filter = process.argv[2] ?? ''

if (!/^elektropos_test[a-z0-9_]*$/.test(DB_NAME)) {
  console.error(`TEST_DB_NAME harus diawali "elektropos_test" (huruf kecil/angka/_). Ditolak: ${DB_NAME}`)
  process.exit(2)
}

const adminUrl = new URL(ADMIN_URL)
const testUrl = new URL(ADMIN_URL)
testUrl.pathname = `/${DB_NAME}`

function psql(url, args) {
  try {
    return execFileSync('psql', [url.toString(), '-X', '-q', '-v', 'ON_ERROR_STOP=1', ...args], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    })
  } catch (err) {
    const detail = `${err.stderr ?? ''}${err.stdout ?? ''}`.trim()
    throw new Error(detail || err.message)
  }
}

const sqlFiles = dir => readdirSync(dir).filter(f => f.endsWith('.sql')).sort()

function recreateDatabase() {
  psql(adminUrl, ['-c', `drop database if exists ${DB_NAME} with (force)`])
  psql(adminUrl, ['-c', `create database ${DB_NAME}`])
  psql(testUrl, ['-f', join(root, 'supabase', 'local-test', 'bootstrap.sql')])
  for (const file of sqlFiles(join(root, 'supabase', 'migrations'))) {
    try {
      psql(testUrl, ['-f', join(root, 'supabase', 'migrations', file)])
    } catch (err) {
      throw new Error(`Migrasi ${file} gagal:\n${err.message}`)
    }
  }
  psql(testUrl, ['-f', join(root, 'supabase', 'seed.sql')])
}

console.log('ElektroPOS — uji database terisolasi')
console.log(`Database uji : ${DB_NAME} (database aplikasi tidak disentuh)`)
console.log('')

let failed = 0
try {
  console.log('[setup] buat database uji + bootstrap + migrasi + fixture')
  recreateDatabase()
  console.log('  OK')
} catch (err) {
  console.error('  FAIL')
  console.error(err.message.split('\n').slice(0, 12).join('\n'))
  process.exit(1)
}

const tests = sqlFiles(join(root, 'supabase', 'tests')).filter(f => f.includes(filter))
console.log('')
for (const file of tests) {
  try {
    psql(testUrl, ['-f', join(root, 'supabase', 'tests', file)])
    console.log(`  PASS  ${file}`)
  } catch (err) {
    failed++
    console.error(`  FAIL  ${file}`)
    console.error(err.message.split('\n').filter(l => l.trim()).slice(0, 8).map(l => `        ${l}`).join('\n'))
  }
}

if (!KEEP) psql(adminUrl, ['-c', `drop database if exists ${DB_NAME} with (force)`])

console.log('')
console.log(`${tests.length - failed}/${tests.length} berkas uji lulus`)
console.log(failed ? 'HASIL: FAIL' : 'HASIL: PASS')
process.exit(failed ? 1 : 0)
