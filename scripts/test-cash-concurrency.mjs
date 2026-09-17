#!/usr/bin/env node
/**
 * Uji konkurensi kas (temuan K10): tutup kas vs mutasi kas yang berjalan bersamaan.
 *
 * Memakai database uji terisolasi yang sama dengan scripts/test-db.mjs (dibangun ulang
 * lewat runner itu dengan TEST_KEEP_DB=yes). Database aplikasi tidak disentuh.
 *
 *   TEST_DB_NAME=elektropos_test_cash node scripts/test-cash-concurrency.mjs
 *
 * Skenario:
 *  A. Mutasi kas (transaksi terbuka 3 detik) lalu tutup kas di koneksi lain:
 *     penutupan menunggu, expected_snapshot memuat mutasi (40.000).
 *  B. Tutup kas (transaksi terbuka 3 detik) lalu INSERT mutasi mentah tanpa lock
 *     (meniru penulis lama yang memakai cash_session_id dari klien):
 *     trigger menolak dengan CASH_SESSION_CLOSED; snapshot = saldo akhir.
 */
import { execFileSync, spawn } from 'child_process'
import { join, resolve } from 'path'
import { fileURLToPath } from 'url'

const root = join(resolve(fileURLToPath(import.meta.url), '..'), '..')
const ADMIN_URL = process.env.TEST_ADMIN_URL || 'postgresql://postgres:postgres@127.0.0.1:54500/postgres'
const DB_NAME = process.env.TEST_DB_NAME || 'elektropos_test'
if (!/^elektropos_test[a-z0-9_]*$/.test(DB_NAME)) {
  console.error(`TEST_DB_NAME harus diawali "elektropos_test". Ditolak: ${DB_NAME}`)
  process.exit(2)
}
const url = new URL(ADMIN_URL)
url.pathname = `/${DB_NAME}`
const OWNER = '11111111-1111-4111-8111-111111111111'
const STAFF = '22222222-2222-4222-8222-222222222222'

const sql = text => execFileSync('psql', [url.toString(), '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-c', text],
  { encoding: 'utf8' }).trim()

// Jalankan skrip SQL di koneksi terpisah; resolve dengan {code, out}.
const session = (script, delayMs = 0) => new Promise(done => {
  setTimeout(() => {
    const p = spawn('psql', [url.toString(), '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'])
    let out = ''
    p.stdout.on('data', d => { out += d })
    p.stderr.on('data', d => { out += d })
    p.on('close', code => done({ code, out: out.trim() }))
    p.stdin.end(script)
  }, delayMs)
})

const claim = id => `select set_config('request.jwt.claim.sub', '${id}', false);`
const opId = () => `'${crypto.randomUUID()}'`
let failed = 0
const check = (ok, label, detail) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${ok ? '' : `\n        ${detail}`}`)
  if (!ok) failed++
}

console.log('[setup] bangun ulang database uji (tanpa menjalankan berkas uji)')
execFileSync(process.execPath, [join(root, 'scripts', 'test-db.mjs'), '__tanpa_uji__'],
  { env: { ...process.env, TEST_DB_NAME: DB_NAME, TEST_KEEP_DB: 'yes' }, stdio: 'ignore' })

try {
  // --- Skenario A ---
  sql(`${claim(OWNER)} select public.open_cash_session_v1(jsonb_build_object('operation_id', ${opId()},
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '0'))`)
  const [id, version] = sql(`select id || '|' || version from private.cash_sessions where status = 'OPEN'`).split('|')
  const writer = session(`begin; ${claim(OWNER)}
    select public.record_cash_adjustment_v1(jsonb_build_object('operation_id', ${opId()}, 'cashbox_code', 'SHOP_DRAWER',
      'direction', 'IN', 'amount', '40000', 'reason', 'uji konkurensi'));
    select pg_sleep(3); commit;`)
  const closer = session(`begin; ${claim(STAFF)}
    select public.close_cash_session_v1(jsonb_build_object('operation_id', ${opId()}, 'session_id', '${id}',
      'expected_version', ${version}, 'counted_amount', '40000'))->>'expected'; commit;`, 1000)
  const [w, c] = await Promise.all([writer, closer])
  const a = sql(`select expected_snapshot || '|' || private.cash_session_expected(id) from private.cash_sessions where id = '${id}'`)
  check(w.code === 0 && c.code === 0 && a === '40000|40000',
    'A: tutup kas menunggu mutasi berjalan; snapshot 40.000 = saldo akhir', `writer=${w.out} closer=${c.out} snapshot|now=${a}`)

  // --- Skenario B ---
  sql(`${claim(OWNER)} select public.open_cash_session_v1(jsonb_build_object('operation_id', ${opId()},
    'cashbox_code', 'SHOP_DRAWER', 'opening_amount', '40000'))`)
  const [id2, version2] = sql(`select id || '|' || version from private.cash_sessions where status = 'OPEN'`).split('|')
  const closer2 = session(`begin; ${claim(STAFF)}
    select public.close_cash_session_v1(jsonb_build_object('operation_id', ${opId()}, 'session_id', '${id2}',
      'expected_version', ${version2}, 'counted_amount', '40000'));
    select pg_sleep(3); commit;`)
  const late = session(`insert into private.cash_movements(session_id, direction, kind, amount, reason, actor_id, operation_id)
    values ('${id2}', 'IN', 'CUSTOMER_PAYMENT', 40000, 'bayar servis telat', '${OWNER}', gen_random_uuid());`, 1000)
  const [c2, l2] = await Promise.all([closer2, late])
  const b = sql(`select expected_snapshot || '|' || private.cash_session_expected(id) from private.cash_sessions where id = '${id2}'`)
  check(c2.code === 0 && l2.code !== 0 && l2.out.includes('CASH_SESSION_CLOSED') && b === '40000|40000',
    'B: mutasi setelah tutup ditolak CASH_SESSION_CLOSED; snapshot = saldo akhir', `closer=${c2.out} late=${l2.out} snapshot|now=${b}`)
} finally {
  const admin = new URL(ADMIN_URL)
  execFileSync('psql', [admin.toString(), '-X', '-q', '-c', `drop database if exists ${DB_NAME} with (force)`])
}

console.log(failed ? 'HASIL: FAIL' : 'HASIL: PASS')
process.exit(failed ? 1 : 0)
