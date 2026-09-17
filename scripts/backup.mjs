#!/usr/bin/env node
/**
 * Backup ElektroPOS (D4: Supabase lokal di PC toko).
 *
 * Isi satu backup (<BACKUP_DIR>/<label>/):
 *   app.dump              pg_dump custom schema private + public + storage_access (fungsi, grants, data)
 *   platform-schema.dump  DDL auth/storage/supabase_migrations (untuk restore ke database kosong)
 *   platform-data.dump    data auth.users/identities, storage.buckets/objects, riwayat migrasi
 *   photos/<object_key>   isi foto bucket ticket-photos (diunduh via Storage API)
 *   manifest.json         hash, ukuran, jumlah baris tabel inti, jumlah RPC, daftar foto
 *   backup-status.json    status akhir (SUCCEEDED/FAILED), status salinan cermin
 * Semua dump dan hitungan baris diambil dari SATU snapshot transaksi (pg_export_snapshot).
 *
 * Lingkungan:
 *   BACKUP_DB_URL        koneksi database aplikasi (wajib)
 *   BACKUP_DIR           folder backup (default ./backups)
 *   BACKUP_MIRROR_DIR    folder kedua di luar PC/disk eksternal (disarankan); gagal salin = backup FAILED
 *   BACKUP_RETENTION     jumlah backup SUCCEEDED yang disimpan (default 14, minimum 2)
 *   SUPABASE_URL / VITE_SUPABASE_URL  URL API Supabase (untuk unduh foto)
 *   SUPABASE_SECRET_KEY  kunci rahasia (hanya dibaca dari env/.env, tidak pernah ditulis/dicetak)
 *   BACKUP_PHOTOS        'api' (default) atau 'skip' (hanya sah bila tidak ada foto)
 *   BACKUP_RECORD_RUN    'yes' (default) mencatat ke private.backup_runs; 'no' untuk sumber read-only
 *
 * Jalankan: npm run backup   (node --env-file=.env scripts/backup.mjs)
 */
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, appendFileSync } from 'fs'
import { dirname, join, resolve } from 'path'
import { fileURLToPath } from 'url'
import {
  COUNT_TABLES_SQL, RPC_COUNT_SQL, dbIdentity, listFilesRecursive, openPsqlSession, psql, redact, registerSecret,
  run, safeObjectPath, sha256Buffer, sha256File, sqlLiteral, storageObjectUrl,
} from './ops-common.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const DB_URL = process.env.BACKUP_DB_URL
const OUT_ROOT = resolve(process.env.BACKUP_DIR || join(root, 'backups'))
const MIRROR_ROOT = process.env.BACKUP_MIRROR_DIR ? resolve(process.env.BACKUP_MIRROR_DIR) : null
const RETENTION = Math.max(2, Number.parseInt(process.env.BACKUP_RETENTION || '14', 10) || 14)
const API_URL = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL || ''
const SECRET = process.env.SUPABASE_SECRET_KEY || ''
const PHOTO_MODE = (process.env.BACKUP_PHOTOS || 'api').toLowerCase()
const RECORD = (process.env.BACKUP_RECORD_RUN || 'yes').toLowerCase() !== 'no'
const BUCKET = 'ticket-photos'
const LABEL_RE = /^\d{8}T\d{6}Z$/

registerSecret(SECRET)
if (DB_URL) registerSecret(new URL(DB_URL).password)

const log = msg => console.log(redact(msg))

function localLog(entry) {
  try {
    mkdirSync(OUT_ROOT, { recursive: true })
    appendFileSync(join(OUT_ROOT, 'backup-log.jsonl'), `${JSON.stringify(entry)}\n`)
  } catch {
    // Log lokal hanya pelengkap; kegagalan menulisnya tidak boleh menutupi status backup.
  }
}

async function downloadPhotos(objects, outDir) {
  const files = []
  for (const obj of objects) {
    const parts = safeObjectPath(obj.name)
    const res = await fetch(storageObjectUrl(API_URL, BUCKET, obj.name), {
      headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}` },
    })
    if (!res.ok) throw new Error(`Unduh foto ${obj.name} gagal: HTTP ${res.status}`)
    const buf = Buffer.from(await res.arrayBuffer())
    if (obj.size !== null && Number(obj.size) !== buf.length) {
      throw new Error(`Ukuran foto ${obj.name} berbeda dari metadata (${buf.length} != ${obj.size})`)
    }
    const target = join(outDir, 'photos', ...parts)
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, buf)
    files.push({ key: obj.name, bytes: buf.length, sha256: sha256Buffer(buf), mimetype: obj.mimetype })
  }
  return files
}

async function verifyDir(dir, manifest) {
  for (const f of Object.values(manifest.files)) {
    const p = join(dir, f.file)
    if (!existsSync(p) || statSync(p).size !== f.bytes || (await sha256File(p)) !== f.sha256) {
      throw new Error(`Berkas ${f.file} tidak cocok dengan manifest di ${dir}`)
    }
  }
  for (const photo of manifest.photos.files) {
    const p = join(dir, 'photos', ...safeObjectPath(photo.key))
    if (!existsSync(p) || (await sha256File(p)) !== photo.sha256) {
      throw new Error(`Foto ${photo.key} tidak cocok dengan manifest di ${dir}`)
    }
  }
}

function applyRetention(base) {
  if (!base || !existsSync(base)) return []
  const dirs = readdirSync(base).filter(n => LABEL_RE.test(n)).sort().reverse()
  const statusOf = n => {
    try {
      return JSON.parse(readFileSync(join(base, n, 'backup-status.json'), 'utf8')).status
    } catch {
      return null
    }
  }
  const succeeded = dirs.filter(n => statusOf(n) === 'SUCCEEDED')
  if (succeeded.length <= RETENTION) return []
  // Hapus hanya yang lebih tua dari backup sukses ke-N; backup terbaru yang sukses selalu tersisa.
  const oldestKept = succeeded[RETENTION - 1]
  const removed = dirs.filter(n => n < oldestKept)
  for (const n of removed) rmSync(join(base, n), { recursive: true, force: true })
  return removed
}

async function main() {
  if (!DB_URL) {
    console.error('BACKUP_DB_URL belum diset. Contoh (PowerShell):')
    console.error('  $env:BACKUP_DB_URL="postgresql://postgres:postgres@127.0.0.1:54500/postgres"')
    process.exit(2)
  }
  if (!['api', 'skip'].includes(PHOTO_MODE)) throw new Error('BACKUP_PHOTOS harus api atau skip')

  const started = new Date()
  const label = started.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')
  const outDir = join(OUT_ROOT, label)
  if (existsSync(outDir)) throw new Error(`Folder backup sudah ada: ${outDir}`)
  mkdirSync(outDir, { recursive: true })
  const source = dbIdentity(DB_URL)
  log(`[backup] ${label} sumber ${source.host}:${source.port}/${source.database}`)

  let runId = null
  let session = null
  const status = { schema_version: 1, label, status: 'FAILED', started_at: started.toISOString() }
  try {
    // 1. Snapshot bersama untuk semua dump dan hitungan baris.
    session = openPsqlSession(DB_URL)
    await session.query('begin isolation level repeatable read read only;')
    const snapshot = await session.query('select pg_export_snapshot();')
    const rowCounts = JSON.parse(await session.query(`${COUNT_TABLES_SQL};`))
    const rpcCount = Number(await session.query(`${RPC_COUNT_SQL};`))
    const schemas = (await session.query(`select string_agg(nspname, ',') from pg_namespace
      where nspname in ('private','public','storage_access','auth','storage','supabase_migrations');`)).split(',')
    const latestMigration = schemas.includes('supabase_migrations')
      ? await session.query('select max(version) from supabase_migrations.schema_migrations;')
      : null
    const objects = rowCounts['storage.objects'] === undefined ? [] : JSON.parse(await session.query(
      `select coalesce(json_agg(json_build_object('name', name, 'size', (metadata->>'size')::bigint,
         'mimetype', metadata->>'mimetype') order by name), '[]') from storage.objects where bucket_id = ${sqlLiteral(BUCKET)};`))
    if (!schemas.includes('private') || rpcCount === 0) throw new Error('Database sumber bukan database aplikasi ElektroPOS')

    // 2. Catat RUNNING di luar snapshot agar baris ini tidak ikut dump.
    if (RECORD) {
      runId = psql(DB_URL, `insert into private.backup_runs(status, backup_label) values ('RUNNING', ${sqlLiteral(label)}) returning id`)
    }

    // 3. Dump dengan snapshot yang sama.
    const dump = (file, args) => {
      run('pg_dump', ['--format=custom', '--no-owner', `--snapshot=${snapshot}`, '--file', join(outDir, file), ...args, DB_URL])
      return file
    }
    const files = {}
    const appSchemas = ['private', 'public', 'storage_access'].filter(s => schemas.includes(s))
    files.app = dump('app.dump', appSchemas.flatMap(s => ['-n', s]))
    const platformSchemas = ['auth', 'storage', 'supabase_migrations'].filter(s => schemas.includes(s))
    if (platformSchemas.length) files.platform_schema = dump('platform-schema.dump', ['--schema-only', ...platformSchemas.flatMap(s => ['-n', s])])
    const dataTables = ['auth.users', 'auth.identities', 'storage.buckets', 'storage.objects', 'supabase_migrations.schema_migrations']
      .filter(t => rowCounts[t] !== undefined)
    if (dataTables.length) files.platform_data = dump('platform-data.dump', ['--data-only', ...dataTables.flatMap(t => ['-t', t])])
    await session.query('commit;')
    await session.close()
    session = null

    // 4. Foto.
    let photoFiles = []
    if (objects.length > 0) {
      if (PHOTO_MODE === 'skip') throw new Error(`Ada ${objects.length} foto tetapi BACKUP_PHOTOS=skip; backup tidak lengkap`)
      if (!API_URL || !SECRET) throw new Error('Foto memerlukan SUPABASE_URL dan SUPABASE_SECRET_KEY')
      photoFiles = await downloadPhotos(objects, outDir)
    }

    // 5. Manifest (tanpa rahasia) lalu verifikasi dump dapat dibaca.
    const manifest = {
      schema_version: 2,
      project: 'elektropos',
      label,
      created_at: started.toISOString(),
      timezone: 'Asia/Jakarta',
      source,
      snapshot: 'repeatable read (pg_export_snapshot)',
      tools: { pg_dump: run('pg_dump', ['--version']).trim(), node: process.version, platform: process.platform },
      files: {},
      row_counts: rowCounts,
      public_rpc_v1_count: rpcCount,
      latest_migration: latestMigration || null,
      photos: {
        bucket: BUCKET,
        mode: objects.length ? 'api' : 'none',
        count: photoFiles.length,
        bytes: photoFiles.reduce((a, f) => a + f.bytes, 0),
        files: photoFiles,
      },
    }
    for (const [key, file] of Object.entries(files)) {
      const p = join(outDir, file)
      run('pg_restore', ['--list', p])
      manifest.files[key] = { file, bytes: statSync(p).size, sha256: await sha256File(p) }
    }
    writeFileSync(join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2))
    const manifestHash = await sha256File(join(outDir, 'manifest.json'))
    await verifyDir(outDir, manifest)

    // 6. Salinan cermin (disk eksternal/folder sinkron) diverifikasi hash.
    let mirrorStatus = 'NOT_CONFIGURED'
    if (MIRROR_ROOT) {
      const mirrorDir = join(MIRROR_ROOT, label)
      cpSync(outDir, mirrorDir, { recursive: true, errorOnExist: true, force: false })
      await verifyDir(mirrorDir, manifest)
      if ((await sha256File(join(mirrorDir, 'manifest.json'))) !== manifestHash) throw new Error('manifest cermin berbeda')
      mirrorStatus = 'OK'
    }

    Object.assign(status, {
      status: 'SUCCEEDED',
      completed_at: new Date().toISOString(),
      manifest_sha256: manifestHash,
      mirror_status: mirrorStatus,
      photo_count: photoFiles.length,
      total_bytes: listFilesRecursive(outDir).reduce((a, f) => a + f.bytes, 0),
    })
    writeFileSync(join(outDir, 'backup-status.json'), JSON.stringify(status, null, 2))
    if (MIRROR_ROOT) writeFileSync(join(MIRROR_ROOT, label, 'backup-status.json'), JSON.stringify(status, null, 2))

    if (RECORD) {
      psql(DB_URL, `update private.backup_runs set status = 'SUCCEEDED', completed_at = now(),
        row_counts = ${sqlLiteral(JSON.stringify(rowCounts))}::jsonb, content_hash = ${sqlLiteral(manifestHash)},
        db_manifest = ${sqlLiteral(`${label}/manifest.json`)}, object_manifest = ${sqlLiteral(`${photoFiles.length} foto`)},
        photo_count = ${photoFiles.length}, total_bytes = ${status.total_bytes}, mirror_status = ${sqlLiteral(mirrorStatus)}
        where id = ${sqlLiteral(runId)}`)
    }

    const removed = [...applyRetention(OUT_ROOT), ...applyRetention(MIRROR_ROOT)]
    log('')
    log('[backup] SUCCEEDED')
    log(`  folder     : ${outDir}`)
    log(`  cermin     : ${mirrorStatus}${MIRROR_ROOT ? ` (${join(MIRROR_ROOT, label)})` : ' — backup BELUM keluar dari PC ini'}`)
    log(`  RPC _v1    : ${rpcCount}`)
    log(`  foto       : ${photoFiles.length}`)
    log(`  total      : ${(status.total_bytes / 1024).toFixed(1)} KiB`)
    log(`  retensi    : simpan ${RETENTION} backup sukses; dihapus ${removed.length} folder lama`)
    log('Backup belum terbukti dapat dipulihkan sampai restore.mjs diuji pada database terpisah.')
    localLog({ label, status: 'SUCCEEDED', at: status.completed_at, mirror: mirrorStatus, photos: photoFiles.length })
  } catch (err) {
    const message = redact(err.message).slice(0, 1000)
    if (session) await session.close().catch(() => {})
    status.status = 'FAILED'
    status.completed_at = new Date().toISOString()
    status.error = message
    try {
      writeFileSync(join(outDir, 'backup-status.json'), JSON.stringify(status, null, 2))
    } catch {
      // folder mungkin tidak dapat ditulis; log lokal & exit code tetap melaporkan gagal
    }
    if (RECORD && runId) {
      try {
        psql(DB_URL, `update private.backup_runs set status = 'FAILED', completed_at = now(),
          redacted_error = ${sqlLiteral(message)} where id = ${sqlLiteral(runId)}`)
      } catch {
        // database tidak dapat dihubungi: status tercatat di log lokal
      }
    }
    localLog({ label, status: 'FAILED', at: status.completed_at, error: message })
    console.error(`[backup] FAILED: ${message}`)
    process.exit(1)
  }
}

main()
