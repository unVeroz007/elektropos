/**
 * Utilitas bersama backup.mjs dan restore.mjs (Node >= 20, Windows/Linux).
 * Tidak pernah mencetak password database atau kunci rahasia.
 */
import { execFileSync, spawn } from 'child_process'
import { createHash } from 'crypto'
import { createReadStream, existsSync, readdirSync, statSync } from 'fs'
import { join } from 'path'

const secrets = new Set()

/** Daftarkan nilai rahasia agar disensor dari semua pesan. */
export function registerSecret(value) {
  if (value && value.length >= 12) secrets.add(value)
}

export function redact(text) {
  let out = String(text ?? '')
  out = out.replace(/(postgres(?:ql)?:\/\/[^:\s/@]+:)[^@\s]+@/gi, '$1***@')
  for (const s of secrets) out = out.split(s).join('***')
  return out.replace(/sb_secret_[A-Za-z0-9_-]+/g, 'sb_secret_***')
}

/** Identitas database untuk perbandingan sumber/target (tanpa kredensial). */
export function dbIdentity(url) {
  const u = new URL(url)
  let host = (u.hostname || 'localhost').toLowerCase()
  if (['localhost', '::1', '[::1]', '127.0.0.1', '0.0.0.0'].includes(host)) host = 'localhost'
  return {
    host,
    port: Number(u.port || 5432),
    database: decodeURIComponent(u.pathname.replace(/^\//, '')) || 'postgres',
  }
}

export const sameDb = (a, b) => a.host === b.host && a.port === b.port && a.database === b.database

export function withDatabase(url, database) {
  const u = new URL(url)
  u.pathname = `/${database}`
  return u.toString()
}

export function run(cmd, args, options = {}) {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024, ...options })
  } catch (err) {
    const detail = `${err.stderr ?? ''}${err.stdout ?? ''}`.trim() || err.message
    throw new Error(`${cmd} gagal: ${redact(detail).slice(0, 1500)}`)
  }
}

/** Satu query psql, hasil teks tanpa header (baris dipisah \n). */
export function psql(url, sql) {
  return run('psql', [url, '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-c', sql]).replace(/\r/g, '').trim()
}

export function psqlJson(url, sql) {
  const out = psql(url, sql)
  return out ? JSON.parse(out) : null
}

export const sqlLiteral = value => `'${String(value).replace(/'/g, "''")}'`

/**
 * Sesi psql yang tetap terbuka (untuk snapshot transaksi bersama pg_dump --snapshot).
 * Setiap query diakhiri penanda agar keluaran dapat dipisahkan.
 */
export function openPsqlSession(url) {
  const child = spawn('psql', [url, '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1'], { stdio: ['pipe', 'pipe', 'pipe'] })
  let out = ''
  let err = ''
  let seq = 0
  let pending = null
  let exited = null
  const settle = () => {
    if (!pending) return
    const idx = out.indexOf(pending.marker)
    if (idx >= 0) {
      const text = out.slice(0, idx).replace(/\r/g, '').trim()
      out = out.slice(idx + pending.marker.length).replace(/^\r?\n/, '')
      const p = pending
      pending = null
      p.resolve(text)
    } else if (exited !== null) {
      const p = pending
      pending = null
      p.reject(new Error(`psql berhenti (kode ${exited}): ${redact(err).slice(0, 800)}`))
    }
  }
  child.stdout.on('data', d => { out += d; settle() })
  child.stderr.on('data', d => { err += d })
  child.on('exit', code => { exited = code; settle() })
  child.on('error', e => { exited = -1; err += e.message; settle() })
  return {
    query(sql) {
      if (pending) throw new Error('query psql bersamaan tidak didukung')
      if (exited !== null) return Promise.reject(new Error(`psql sudah berhenti: ${redact(err).slice(0, 800)}`))
      const marker = `__ELEKTROPOS_${++seq}_${process.pid}__`
      return new Promise((resolve, reject) => {
        pending = { marker, resolve, reject }
        child.stdin.write(`${sql}\n\\echo ${marker}\n`)
      })
    },
    async close() {
      if (exited === null) {
        child.stdin.end('\\q\n')
        await new Promise(resolve => (exited !== null ? resolve() : child.on('exit', resolve)))
      }
    },
  }
}

export function sha256File(path) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    createReadStream(path).on('data', d => hash.update(d)).on('error', reject).on('end', () => resolve(hash.digest('hex')))
  })
}

export const sha256Buffer = buf => createHash('sha256').update(buf).digest('hex')

export function listFilesRecursive(dir, prefix = '') {
  if (!existsSync(dir)) return []
  const files = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    const full = join(dir, entry.name)
    if (entry.isDirectory()) files.push(...listFilesRecursive(full, rel))
    else files.push({ rel, full, bytes: statSync(full).size })
  }
  return files
}

/** Kunci objek Storage menjadi path lokal aman (tolak '..' dan path absolut). */
export function safeObjectPath(key) {
  const parts = String(key).split('/')
  if (!key || parts.some(p => p === '' || p === '.' || p === '..' || /[\\:*?"<>|]/.test(p))) {
    throw new Error(`Kunci objek tidak aman untuk disimpan: ${key}`)
  }
  return parts
}

export const storageObjectUrl = (base, bucket, key) =>
  `${base.replace(/\/$/, '')}/storage/v1/object/${encodeURIComponent(bucket)}/${key.split('/').map(encodeURIComponent).join('/')}`

/** Nama tabel yang dicatat jumlah barisnya pada manifest dan diverifikasi saat restore. */
export const COUNT_TABLES_SQL = `
  select coalesce(json_object_agg(t.fq, t.n order by t.fq), '{}'::json)
  from (
    select format('%s.%s', table_schema, table_name) fq,
      (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint n
    from information_schema.tables
    where table_type = 'BASE TABLE' and (
      table_schema = 'private'
      or (table_schema, table_name) in (('auth', 'users'), ('auth', 'identities'), ('storage', 'buckets'),
                                        ('storage', 'objects'), ('supabase_migrations', 'schema_migrations')))
  ) t`

export const RPC_COUNT_SQL = `
  select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like '%\\_v1'`
