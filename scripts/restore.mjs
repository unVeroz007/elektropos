#!/usr/bin/env node
/**
 * Restore ElektroPOS dari folder backup buatan backup.mjs ke database KOSONG.
 *
 * Pengaman:
 *   - Target yang sama dengan database sumber (host/port/nama dari BACKUP_DB_URL dan manifest)
 *     atau bernama `postgres` DITOLAK, kecuali RESTORE_ALLOW_APP_DB=yes DAN nama database diketik
 *     ulang (prompt interaktif atau RESTORE_CONFIRM_DB=<nama>). Dipakai hanya untuk pemulihan PC baru.
 *   - Target yang sudah memiliki schema `private` selalu ditolak: restore tidak pernah menimpa/drop data.
 *   - Hash semua berkas diverifikasi sebelum target disentuh.
 *
 * Lingkungan:
 *   RESTORE_DB_URL        database target (wajib), mis. .../elektropos_test_restore
 *   RESTORE_BACKUP        folder backup; default backup SUCCEEDED terbaru di BACKUP_DIR
 *   BACKUP_DIR            default ./backups
 *   BACKUP_DB_URL         database sumber/aplikasi (untuk pengaman perbandingan)
 *   RESTORE_ALLOW_APP_DB  'yes' untuk mengizinkan target database aplikasi (butuh konfirmasi nama)
 *   RESTORE_CONFIRM_DB    konfirmasi nama database untuk mode non-interaktif
 *   RESTORE_PHOTOS        'verify' (default: cocokkan hash berkas foto + baris storage.objects)
 *                         'api' (unggah foto ke Storage API target; hanya untuk target aplikasi)
 *   SUPABASE_URL / VITE_SUPABASE_URL, SUPABASE_SECRET_KEY  untuk RESTORE_PHOTOS=api
 *   RESTORE_RECORD_URL    opsional: database aplikasi yang dicatat restore_verified_at bila SUCCEEDED
 *
 * Status SUCCEEDED hanya bila: jumlah baris semua tabel manifest cocok, jumlah RPC public *_v1 cocok (>0),
 * foto cocok, invariant stok cocok, dan RPC baca dapat dipanggil sebagai OWNER aktif.
 */
import { createInterface } from 'readline'
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'fs'
import { dirname, join, resolve } from 'path'
import { fileURLToPath } from 'url'
import {
  COUNT_TABLES_SQL, RPC_COUNT_SQL, dbIdentity, psql, psqlJson, redact, registerSecret, run, safeObjectPath,
  sameDb, sha256File, sqlLiteral, storageObjectUrl,
} from './ops-common.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const TARGET = process.env.RESTORE_DB_URL
const BACKUP_ROOT = resolve(process.env.BACKUP_DIR || join(root, 'backups'))
const PHOTO_MODE = (process.env.RESTORE_PHOTOS || 'verify').toLowerCase()
const API_URL = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL || ''
const SECRET = process.env.SUPABASE_SECRET_KEY || ''
registerSecret(SECRET)
for (const u of [TARGET, process.env.BACKUP_DB_URL, process.env.RESTORE_RECORD_URL]) {
  if (u) registerSecret(new URL(u).password)
}
const log = msg => console.log(redact(msg))

function pickBackupDir() {
  if (process.env.RESTORE_BACKUP) return resolve(process.env.RESTORE_BACKUP)
  if (!existsSync(BACKUP_ROOT)) throw new Error(`Folder backup tidak ada: ${BACKUP_ROOT}`)
  const dirs = readdirSync(BACKUP_ROOT).filter(n => /^\d{8}T\d{6}Z$/.test(n)).sort().reverse()
  for (const n of dirs) {
    try {
      if (JSON.parse(readFileSync(join(BACKUP_ROOT, n, 'backup-status.json'), 'utf8')).status === 'SUCCEEDED') {
        return join(BACKUP_ROOT, n)
      }
    } catch {
      // folder tanpa status sah dilewati
    }
  }
  throw new Error('Tidak ada backup berstatus SUCCEEDED')
}

async function askConfirmation(expected) {
  if (process.env.RESTORE_CONFIRM_DB !== undefined) return process.env.RESTORE_CONFIRM_DB === expected
  if (!process.stdin.isTTY) return false
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  const answer = await new Promise(res => rl.question(`Ketik nama database target (${expected}) untuk melanjutkan: `, res))
  rl.close()
  return answer.trim() === expected
}

/** Daftar TOC pg_restore yang disaring; baris: "id; oid oid TYPE SCHEMA NAME OWNER". */
function tocList(dumpPath, keep) {
  const lines = run('pg_restore', ['--list', dumpPath]).replace(/\r/g, '').split('\n')
  return lines.filter(line => {
    if (!line || line.startsWith(';')) return true
    const m = line.match(/^\d+; \d+ \d+ ((?:[A-Z]+ )+)(\S+) (\S+) ?(\S*)/)
    if (!m) return true
    return keep({ type: m[1].trim(), schema: m[2], name: m[3], owner: m[4] })
  }).join('\n')
}

function restoreFiltered(dumpPath, keep, workFile) {
  writeFileSync(workFile, tocList(dumpPath, keep))
  run('pg_restore', ['--no-owner', '--exit-on-error', '--single-transaction', '--use-list', workFile, '--dbname', TARGET, dumpPath])
}

async function main() {
  if (!TARGET) {
    console.error('RESTORE_DB_URL belum diset (gunakan database uji kosong, mis. elektropos_test_restore).')
    process.exit(2)
  }
  const backupDir = pickBackupDir()
  const manifest = JSON.parse(readFileSync(join(backupDir, 'manifest.json'), 'utf8'))
  const target = dbIdentity(TARGET)
  const sources = [manifest.source, process.env.BACKUP_DB_URL && dbIdentity(process.env.BACKUP_DB_URL)].filter(Boolean)
  log(`[restore] backup  : ${backupDir} (dibuat ${manifest.created_at})`)
  log(`[restore] target  : ${target.host}:${target.port}/${target.database}`)

  // Pengaman target.
  const isSource = sources.some(s => sameDb(s, target))
  if (isSource || target.database === 'postgres') {
    const reason = isSource ? 'target sama dengan database aplikasi sumber' : 'target adalah database `postgres` (database aplikasi Supabase)'
    if (process.env.RESTORE_ALLOW_APP_DB !== 'yes' || !(await askConfirmation(target.database))) {
      console.error(`[restore] DITOLAK: ${reason}.`)
      console.error('  Untuk uji pemulihan pakai database terpisah, mis. .../elektropos_test_restore.')
      console.error('  Pemulihan PC baru: RESTORE_ALLOW_APP_DB=yes dan ketik ulang nama database (lihat docs/08).')
      process.exit(2)
    }
    log(`[restore] PERINGATAN: ${reason}; diizinkan eksplisit.`)
  }
  if (psql(TARGET, "select count(*) from pg_namespace where nspname = 'private'") !== '0') {
    console.error('[restore] DITOLAK: target sudah memiliki schema private. Restore hanya ke database kosong.')
    process.exit(2)
  }
  const roles = psql(TARGET, "select count(*) from pg_roles where rolname in ('anon','authenticated')")
  if (roles !== '2') throw new Error('Cluster target tidak memiliki role anon/authenticated (bukan cluster Supabase)')
  if (PHOTO_MODE === 'api' && !(isSource || target.database === 'postgres')) {
    throw new Error('RESTORE_PHOTOS=api hanya untuk target database aplikasi yang dilayani Storage API')
  }

  // 1. Verifikasi integritas berkas sebelum menyentuh target.
  for (const f of Object.values(manifest.files)) {
    if ((await sha256File(join(backupDir, f.file))) !== f.sha256) throw new Error(`Hash ${f.file} tidak cocok manifest`)
  }
  for (const p of manifest.photos.files) {
    if ((await sha256File(join(backupDir, 'photos', ...safeObjectPath(p.key)))) !== p.sha256) {
      throw new Error(`Hash foto ${p.key} tidak cocok manifest`)
    }
  }
  log('[restore] hash berkas cocok dengan manifest')

  const started = new Date()
  const work = join(backupDir, '.restore-toc.list')
  const me = psql(TARGET, 'select current_user')
  const present = psql(TARGET, "select coalesce(string_agg(nspname, ','), '') from pg_namespace where nspname in ('auth','storage','supabase_migrations')").split(',')
  const missing = ['auth', 'storage', 'supabase_migrations'].filter(s => !present.includes(s))

  // 2. Schema platform yang belum ada (database kosong biasa). Policy menunggu fungsi aplikasi.
  if (missing.length && manifest.files.platform_schema) {
    log(`[restore] buat schema platform: ${missing.join(', ')}`)
    restoreFiltered(join(backupDir, manifest.files.platform_schema.file),
      e => (missing.includes(e.schema) || (e.type === 'SCHEMA' && missing.includes(e.name))) && e.type !== 'POLICY' && e.type !== 'DEFAULT ACL', work)
  }
  // 3. Data identitas/Storage lebih dulu karena tabel aplikasi ber-FK ke auth.users.
  if (manifest.files.platform_data) {
    log('[restore] data auth/storage/riwayat migrasi')
    restoreFiltered(join(backupDir, manifest.files.platform_data.file),
      e => !(PHOTO_MODE === 'api' && e.schema === 'storage' && e.name === 'objects'), work)
  }
  // 4. Aplikasi: schema private/public/storage_access, fungsi, grants, data.
  log('[restore] aplikasi (private, public, storage_access)')
  restoreFiltered(join(backupDir, manifest.files.app.file),
    e => !(e.type === 'SCHEMA' && e.name === 'public') && !(e.type === 'COMMENT' && e.schema === '-' && e.name === 'SCHEMA')
      && !(e.type === 'DEFAULT ACL' && e.owner && e.owner !== me), work)
  // 5. Policy Storage (memanggil storage_access.*).
  if (manifest.files.platform_schema) {
    log('[restore] policy Storage')
    restoreFiltered(join(backupDir, manifest.files.platform_schema.file), e => e.type === 'POLICY' && e.schema === 'storage', work)
  }
  // 6. Foto ke Storage API (mode pemulihan aplikasi).
  if (PHOTO_MODE === 'api' && manifest.photos.count > 0) {
    if (!API_URL || !SECRET) throw new Error('RESTORE_PHOTOS=api memerlukan SUPABASE_URL dan SUPABASE_SECRET_KEY')
    for (const p of manifest.photos.files) {
      const body = readFileSync(join(backupDir, 'photos', ...safeObjectPath(p.key)))
      const res = await fetch(storageObjectUrl(API_URL, manifest.photos.bucket, p.key), {
        method: 'POST',
        headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}`, 'Content-Type': p.mimetype || 'application/octet-stream' },
        body,
      })
      if (!res.ok) throw new Error(`Unggah foto ${p.key} gagal: HTTP ${res.status}`)
    }
    log(`[restore] ${manifest.photos.count} foto diunggah ke Storage API`)
  }

  // 7. Verifikasi.
  const checks = []
  const check = (name, ok, detail) => checks.push({ name, ok: Boolean(ok), detail })
  const counts = psqlJson(TARGET, COUNT_TABLES_SQL)
  for (const [table, expected] of Object.entries(manifest.row_counts)) {
    check(`baris ${table}`, counts[table] === expected, `${counts[table] ?? 'tidak ada'} / manifest ${expected}`)
  }
  const rpc = Number(psql(TARGET, RPC_COUNT_SQL))
  check('RPC public *_v1', rpc > 0 && rpc === manifest.public_rpc_v1_count, `${rpc} / manifest ${manifest.public_rpc_v1_count}`)
  const photoRows = counts['storage.objects'] === undefined ? 0
    : Number(psql(TARGET, `select count(*) from storage.objects where bucket_id = ${sqlLiteral(manifest.photos.bucket)}`))
  check('foto', photoRows === manifest.photos.count, `${photoRows} baris objek / ${manifest.photos.count} berkas`)
  const ledger = psql(TARGET, `select
    (select count(*) from private.stock_positions p where p.qty_base <> (select coalesce(sum(m.qty_delta),0) from private.stock_movements m where m.position_id = p.id))
    + (select count(*) from private.inventory_lots l where l.remaining_cost <> (select coalesce(sum(m.cost_delta),0) from private.stock_movements m where m.lot_id = l.id))`)
  check('invariant stok/modal', ledger === '0', `${ledger} selisih`)
  const owner = psql(TARGET, "select id from private.app_profiles where role = 'OWNER' and active order by created_at limit 1")
  if (!owner) {
    check('RPC sebagai OWNER', false, 'tidak ada akun OWNER aktif pada backup')
  } else {
    try {
      const out = psql(TARGET, `begin;
        select set_config('request.jwt.claim.sub', ${sqlLiteral(owner)}, true);
        set local role authenticated;
        select (public.get_current_profile_v1()->>'role') || '|' || (public.get_dashboard_v1('{}') ? 'refreshed_at')::text;
        rollback;`)
      check('RPC sebagai OWNER', out.split('\n').includes('OWNER|true'), 'get_current_profile_v1 + get_dashboard_v1')
    } catch (err) {
      check('RPC sebagai OWNER', false, redact(err.message).slice(0, 300))
    }
  }

  const ok = checks.every(c => c.ok)
  const report = {
    schema_version: 2,
    status: ok ? 'SUCCEEDED' : 'FAILED',
    backup_label: manifest.label,
    backup_created_at: manifest.created_at,
    target,
    started_at: started.toISOString(),
    completed_at: new Date().toISOString(),
    duration_seconds: Math.round((Date.now() - started.getTime()) / 1000),
    photos_mode: PHOTO_MODE,
    checks,
  }
  writeFileSync(join(backupDir, `restore-report-${target.database}.json`), JSON.stringify(report, null, 2))
  for (const c of checks) log(`  ${c.ok ? 'OK  ' : 'GAGAL'} ${c.name}: ${c.detail}`)
  if (ok && process.env.RESTORE_RECORD_URL) {
    const manifestHash = await sha256File(join(backupDir, 'manifest.json'))
    psql(process.env.RESTORE_RECORD_URL, `update private.backup_runs set restore_verified_at = now() where content_hash = ${sqlLiteral(manifestHash)}`)
  }
  log('')
  log(`[restore] ${report.status} dalam ${report.duration_seconds} detik`)
  if (ok) {
    log('Lanjutkan pemeriksaan manual OPS-04: login owner/staff, buka nota/tiket/foto, staff tidak melihat modal.')
  }
  process.exit(ok ? 0 : 1)
}

main().catch(err => {
  console.error(`[restore] FAILED: ${redact(err.message).slice(0, 1500)}`)
  process.exit(1)
})
