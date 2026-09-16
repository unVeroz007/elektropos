#!/usr/bin/env node
/**
 * Backup ElektroPOS — dump database + manifest foto.
 *
 * Lingkungan:
 *   BACKUP_DB_URL     koneksi database sumber (wajib)
 *   BACKUP_DIR        direktori tujuan (default: ./backups)
 *   BACKUP_STORAGE_DIR direktori Storage untuk dicatat manifestnya (opsional)
 *
 * Keluaran:
 *   <BACKUP_DIR>/<timestamp>/database.dump      (format custom pg_dump)
 *   <BACKUP_DIR>/<timestamp>/manifest.json      (metadata + hash)
 *
 * Catatan: runner ini hanya menghasilkan berkas backup. Verifikasi pemulihan
 * dilakukan oleh restore.mjs pada lingkungan uji terpisah. Runner tidak
 * mengirim berkas ke layanan eksternal dan tidak menyimpan kredensial.
 */
import { execFileSync } from 'child_process'
import { createHash } from 'crypto'
import { mkdirSync, readFileSync, statSync, writeFileSync, readdirSync, existsSync } from 'fs'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const __dirname = resolve(fileURLToPath(import.meta.url), '..')
const root = join(__dirname, '..')

const DB_URL = process.env.BACKUP_DB_URL
const OUT_ROOT = process.env.BACKUP_DIR || join(root, 'backups')
const STORAGE_DIR = process.env.BACKUP_STORAGE_DIR

if (!DB_URL) {
  console.error('BACKUP_DB_URL belum diset. Contoh:')
  console.error('  $env:BACKUP_DB_URL="postgresql://postgres:postgres@127.0.0.1:54500/postgres"')
  process.exit(1)
}

function sha256File(path) {
  const buf = readFileSync(path)
  return createHash('sha256').update(buf).digest('hex')
}

function listStorage(dir) {
  if (!dir || !existsSync(dir)) return []
  const files = []
  const walk = (current, prefix) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = join(current, entry.name)
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name
      if (entry.isDirectory()) walk(full, rel)
      else files.push({ key: rel, bytes: statSync(full).size, sha256: sha256File(full) })
    }
  }
  walk(dir, '')
  return files
}

function main() {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const outDir = join(OUT_ROOT, stamp)
  mkdirSync(outDir, { recursive: true })

  const dumpPath = join(outDir, 'database.dump')
  console.log(`[backup] dump database → ${dumpPath}`)
  execFileSync('pg_dump', ['--format=custom', '--no-owner', '--no-privileges', '--file', dumpPath, DB_URL], {
    stdio: ['pipe', 'pipe', 'pipe'],
  })

  const dumpBytes = statSync(dumpPath).size
  if (dumpBytes === 0) throw new Error('dump database kosong')

  console.log('[backup] catat manifest Storage')
  const storage = listStorage(STORAGE_DIR)

  const manifest = {
    schema_version: 1,
    project: 'elektropos',
    created_at: new Date().toISOString(),
    timezone: 'Asia/Jakarta',
    database: {
      file: 'database.dump',
      bytes: dumpBytes,
      sha256: sha256File(dumpPath),
      format: 'pg_dump-custom',
    },
    storage: {
      root: STORAGE_DIR || null,
      file_count: storage.length,
      files: storage,
    },
    runner: { node: process.version, platform: process.platform },
  }
  writeFileSync(join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2))

  console.log('')
  console.log('[backup] selesai')
  console.log(`  direktori : ${outDir}`)
  console.log(`  database  : ${(dumpBytes / 1024).toFixed(1)} KiB`)
  console.log(`  foto      : ${storage.length} berkas`)
  console.log('')
  console.log('PENTING: backup belum terbukti dapat dipulihkan sampai restore.mjs dijalankan.')
}

main()
