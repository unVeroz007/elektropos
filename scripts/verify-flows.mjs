#!/usr/bin/env node
/**
 * Verifikasi alur UI end-to-end melalui API (simulasi klik pengguna).
 * Menjalankan: katalog, kasir, servis, laporan, pengaturan, barcode fisik.
 * Membutuhkan `npm run setup:demo` sudah dijalankan.
 */
const API = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:55000'
const KEY = process.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!KEY) {
  console.error('VITE_SUPABASE_PUBLISHABLE_KEY belum diset. Jalankan `npx supabase status`.')
  process.exit(1)
}

async function login(email, password) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  if (!r.ok) throw new Error(`login ${email} gagal`)
  return (await r.json()).access_token
}

async function rpc(path, token, body) {
  const r = await fetch(`${API}/rest/v1/rpc/${path}`, {
    method: 'POST',
    headers: { apikey: KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await r.text()
  let json
  try { json = JSON.parse(text) } catch { json = text }
  return { ok: r.ok, status: r.status, data: json, raw: text }
}

const uid = () => crypto.randomUUID()
let pass = 0, fail = 0
function check(label, condition, detail) {
  if (condition) { console.log(`  PASS  ${label}`); pass++ }
  else { console.log(`  FAIL  ${label}${detail ? ' — ' + detail : ''}`); fail++ }
}

async function main() {
  console.log('ElektroPOS — verifikasi alur UI via API\n')
  const owner = await login('owner@elektropos.local', 'Owner123!')
  const staff = await login('staff@elektropos.local', 'Staff123!')

  // Beranda
  const dash = await rpc('get_dashboard_v1', owner, { p_input: {} })
  check('Beranda memuat ringkasan', dash.ok && dash.data?.server_date, dash.raw.slice(0, 80))

  // Katalog: cari semua produk demo
  const cat = await rpc('search_products_v1', owner, { p_input: { query: 'DEMO-', limit: 50 } })
  check('Katalog menampilkan produk demo', cat.ok && Array.isArray(cat.data) && cat.data.length >= 4,
    `dapat ${Array.isArray(cat.data) ? cat.data.length : '?'}`)

  // Scanner: cari lewat barcode
  const byScan = await rpc('search_products_v1', staff, { p_input: { query: '8991001001001', limit: 3 } })
  check('Scan barcode menemukan produk', byScan.ok && byScan.data?.[0]?.sku === 'DEMO-LAMPU-12W',
    byScan.data?.[0]?.sku)

  // Daftar barcode fisik baru
  const lampu = cat.data.find(p => p.sku === 'DEMO-LAMPU-12W')
  const addBc = await rpc('add_product_barcode_v1', owner, {
    p_input: { operation_id: uid(), product_id: lampu.id, product_unit_id: lampu.units[0].id, code: '7770001112223' },
  })
  check('Daftarkan barcode fisik', addBc.ok && addBc.data?.ok === true, addBc.raw.slice(0, 100))
  const scanNew = await rpc('search_products_v1', owner, { p_input: { query: '7770001112223', limit: 3 } })
  check('Scan barcode baru menemukan produk', scanNew.data?.[0]?.sku === 'DEMO-LAMPU-12W', scanNew.data?.[0]?.sku)

  // Barcode presisi: find_by_barcode mengembalikan satuan tepat
  const byBar = await rpc('find_by_barcode_v1', owner, { p_input: { code: '7770001112223' } })
  check('find_by_barcode menemukan + satuan + versi',
    byBar.data?.found === true && byBar.data?.unit_id && byBar.data?.unit_version,
    JSON.stringify(byBar.data).slice(0, 100))

  const byBarUnknown = await rpc('find_by_barcode_v1', owner, { p_input: { code: '0000000000000' } })
  check('Barcode asing -> found=false', byBarUnknown.data?.found === false)

  const listBc = await rpc('list_product_barcodes_v1', owner, { p_input: { product_id: lampu.id } })
  check('Daftar barcode produk', Array.isArray(listBc.data) && listBc.data.length >= 2, `${listBc.data?.length}`)

  // Kasir: jual 2 lampu tunai
  const session = await rpc('get_cash_session_v1', owner, { p_input: { cashbox_code: 'SHOP_DRAWER' } })
  check('Sesi kas terbuka', session.ok && session.data?.open === true, session.raw.slice(0, 80))

  const sale = await rpc('finalize_sale_v1', staff, {
    p_input: {
      operation_id: uid(),
      items: [{ product_unit_id: lampu.units[0].id, qty: '2', expected_unit_version: lampu.units[0].version }],
      payment: { method: 'CASH', tendered: '50000' },
    },
  })
  check('Kasir: finalisasi penjualan tunai', sale.ok && sale.data?.ok === true, sale.raw.slice(0, 120))

  // Struk: baca invoice
  if (sale.data?.entity_id) {
    const inv = await rpc('get_invoice_v1', owner, { p_input: { invoice_id: sale.data.entity_id } })
    check('Struk dapat dibaca', inv.ok && inv.data?.number && inv.data?.items?.length > 0)
  }

  // Riwayat
  const hist = await rpc('list_invoices_v1', owner, {
    p_input: { start_date: new Date().toISOString().slice(0, 10), end_date: new Date().toISOString().slice(0, 10) },
  })
  check('Riwayat menampilkan transaksi', hist.ok && Array.isArray(hist.data) && hist.data.length >= 1)

  // Laporan
  const rep = await rpc('get_report_v1', owner, {
    p_input: { start_date: new Date().toISOString().slice(0, 10), end_date: new Date().toISOString().slice(0, 10) },
  })
  check('Laporan memuat penjualan neto', rep.ok && rep.data?.sales_net, rep.raw.slice(0, 80))

  // Staff tidak boleh lihat COGS
  const repStaff = await rpc('get_report_v1', staff, {
    p_input: { start_date: new Date().toISOString().slice(0, 10), end_date: new Date().toISOString().slice(0, 10) },
  })
  check('Staff tidak menerima COGS', repStaff.data?.cogs === undefined || repStaff.data?.cogs === null)

  // Servis: buat tiket + transisi
  const ticket = await rpc('create_service_ticket_v1', staff, {
    p_input: { operation_id: uid(), customer_name: 'Uji Demo', customer_phone: '081200000000',
      equipment_type: 'Radio', complaint: 'Mati total', service_location: 'STORE' },
  })
  check('Servis: buat tiket', ticket.ok && ticket.data?.ok === true, ticket.raw.slice(0, 120))

  if (ticket.data?.entity_id) {
    const tid = ticket.data.entity_id
    const detail = await rpc('get_service_ticket_v1', owner, { p_input: { ticket_id: tid } })
    check('Servis: detail tiket', detail.ok && detail.data?.work_status === 'NEW', detail.raw.slice(0, 100))

    const trans = await rpc('transition_service_v1', owner, {
      p_input: { operation_id: uid(), ticket_id: tid, expected_version: detail.data.version, target_status: 'INSPECTING' },
    })
    check('Servis: transisi status', trans.ok && trans.data?.ok === true, trans.raw.slice(0, 120))
  }

  // Pelanggan
  const cust = await rpc('upsert_customer_v1', staff, {
    p_input: { operation_id: uid(), name: 'Pelanggan Demo', phone: '081234567899' },
  })
  check('Pelanggan: simpan baru', cust.ok && cust.data?.ok === true, cust.raw.slice(0, 120))
  const custSearch = await rpc('search_customers_v1', owner, { p_input: { query: 'Pelanggan Demo' } })
  check('Pelanggan: pencarian', custSearch.ok && Array.isArray(custSearch.data) && custSearch.data.length >= 1)

  // Pengaturan
  const settings = await rpc('get_shop_settings_v1', owner, {})
  check('Pengaturan toko terbaca', settings.ok && settings.data?.name, settings.raw.slice(0, 80))

  // Kesehatan
  const health = await rpc('get_health_v1', owner, {})
  check('Kesehatan sistem', health.ok && health.data?.db_size_bytes, health.raw.slice(0, 80))

  // Keamanan: anon ditolak
  const anonRes = await fetch(`${API}/rest/v1/rpc/get_current_profile_v1`, {
    method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: '{}',
  })
  check('Keamanan: anon ditolak', anonRes.status === 401 || anonRes.status === 403, `status ${anonRes.status}`)

  console.log(`\nHasil: ${pass} PASS, ${fail} FAIL`)
  if (fail > 0) process.exit(1)
}

main().catch(e => { console.error('Verifikasi gagal:', e.message); process.exit(1) })
