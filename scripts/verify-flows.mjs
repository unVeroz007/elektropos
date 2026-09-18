#!/usr/bin/env node
/**
 * Verifikasi alur end-to-end lewat API HTTP nyata (PostgREST + Auth + Storage) pada Supabase lokal.
 *
 * Berbeda dengan uji SQL, skrip ini memakai token login sungguhan sehingga membuktikan izin,
 * RLS Storage, dan kontrak JSON yang dipakai aplikasi. Setiap langkah memeriksa NILAI (uang,
 * stok, kembalian), bukan hanya `ok`. Data yang dibuat bertanda "VERIFY" dan tetap tersimpan
 * (lingkungan demo). Prasyarat: `npm run setup:demo`.
 */
const API = process.env.VITE_SUPABASE_URL || 'http://127.0.0.1:55000'
const KEY = process.env.VITE_SUPABASE_PUBLISHABLE_KEY
if (!KEY) {
  console.error('VITE_SUPABASE_PUBLISHABLE_KEY belum diset (.env).')
  process.exit(1)
}

let passed = 0
let failed = 0
function check(label, condition, detail = '') {
  if (condition) { passed++; console.log(`  PASS  ${label}`) } else { failed++; console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ''}`) }
}
const section = title => console.log(`\n[${title}]`)
const uid = () => crypto.randomUUID()
const n = value => Number(value ?? NaN)
const todayWib = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jakarta' }).format(new Date())

async function login(email, password) {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }),
  })
  if (!res.ok) throw new Error(`login ${email} gagal (${res.status}). Jalankan npm run setup:demo.`)
  return (await res.json()).access_token
}

/** Panggil RPC; kembalikan {ok, data, code} dengan code = KODE dari pesan server. */
async function rpc(token, name, input) {
  const headers = { apikey: KEY, 'Content-Type': 'application/json' }
  if (token) headers.Authorization = `Bearer ${token}`
  const res = await fetch(`${API}/rest/v1/rpc/${name}`, {
    method: 'POST', headers, body: JSON.stringify(input === undefined ? {} : { p_input: input }),
  })
  const text = await res.text()
  let data
  try { data = JSON.parse(text) } catch { data = text }
  const message = res.ok ? '' : String(data?.message ?? text)
  return { ok: res.ok, status: res.status, data, message, code: /^([A-Z_]{3,}):/.exec(message)?.[1] ?? null }
}

/** Harus berhasil; berhenti bila gagal karena langkah berikutnya bergantung. */
async function must(token, name, input) {
  const result = await rpc(token, name, input)
  if (!result.ok) throw new Error(`${name} gagal: ${result.message}`)
  return result.data
}

async function productBySku(token, sku) {
  const rows = await must(token, 'search_products_v1', { query: sku, limit: 5 })
  const product = rows.find(p => p.sku === sku)
  if (!product) throw new Error(`Produk ${sku} tidak ada. Jalankan npm run setup:demo.`)
  return product
}

async function main() {
  console.log('ElektroPOS — verifikasi alur API (nilai uang & stok diperiksa)')
  const owner = await login('owner@elektropos.local', 'Owner123!')
  const staff = await login('staff@elektropos.local', 'Staff123!')
  const admin = await login('admin@elektropos.local', 'Admin123!')

  section('Akses')
  const anon = await rpc(null, 'get_current_profile_v1')
  check('anon ditolak', anon.status === 401 || anon.status === 403, `status ${anon.status}`)
  check('profil staff', (await must(staff, 'get_current_profile_v1')).role === 'STAFF')

  section('Kasir: penjualan tunai (BR-04, BR-07)')
  const drawer = await must(owner, 'get_cash_session_v1', { cashbox_code: 'SHOP_DRAWER' })
  check('laci toko terbuka', drawer.open === true)
  const lamp = await productBySku(staff, 'DEMO-LAMPU-12W')
  const lampUnit = lamp.units.find(u => u.is_default) ?? lamp.units[0]
  const stockBefore = n(lamp.stock_shop)
  const saleInput = {
    client_reference_id: uid(),
    items: [{ product_unit_id: lampUnit.id, qty: '2', expected_unit_version: lampUnit.version }],
    payment: { method: 'CASH', tendered: '50000' },
  }
  const preview = await must(staff, 'preview_sale_v1', saleInput)
  check('pratinjau total = 2 × harga', n(preview.total) === 2 * n(lampUnit.sell_price), `total ${preview.total}`)
  const saleOp = uid()
  const sale = await must(staff, 'finalize_sale_v1', { operation_id: saleOp, ...saleInput })
  check('total nota = pratinjau', sale.total === preview.total, `${sale.total} vs ${preview.total}`)
  check('kembalian = uang diterima − total', n(sale.change) === 50000 - n(sale.total), `kembalian ${sale.change}`)
  const lampAfter = await productBySku(staff, 'DEMO-LAMPU-12W')
  check('stok toko berkurang 2', n(lampAfter.stock_shop) === stockBefore - 2, `${stockBefore} → ${lampAfter.stock_shop}`)
  const drawerAfter = await must(owner, 'get_cash_session_v1', { cashbox_code: 'SHOP_DRAWER' })
  check('saldo laci bertambah sebesar total (bukan uang diterima)', n(drawerAfter.expected) === n(drawer.expected) + n(sale.total))

  section('Idempotensi & peran')
  const replay = await rpc(staff, 'finalize_sale_v1', { operation_id: saleOp, ...saleInput })
  check('kirim ulang operation_id sama → nota sama', replay.ok && replay.data.entity_id === sale.entity_id)
  const conflict = await rpc(staff, 'finalize_sale_v1', { operation_id: saleOp, ...saleInput, items: [{ ...saleInput.items[0], qty: '3' }] })
  check('isi beda dengan operation_id sama ditolak', conflict.code === 'IDEMPOTENCY_CONFLICT', conflict.message)
  const operation = await must(staff, 'get_operation_v1', { command: 'finalize_sale_v1', operation_id: saleOp })
  check('status operasi dapat dicek (T01)', operation.found === true && operation.result.entity_id === sale.entity_id)
  const staffDiscount = await rpc(staff, 'finalize_sale_v1', {
    operation_id: uid(), client_reference_id: uid(), discount_mode: 'percent', discount_value: '100',
    items: saleInput.items, payment: { method: 'CASH', tendered: '50000' },
  })
  check('karyawan tidak bisa memberi diskon (K02)', staffDiscount.code === 'FORBIDDEN', staffDiscount.message)
  const adminSale = await rpc(admin, 'finalize_sale_v1', { operation_id: uid(), ...saleInput, client_reference_id: uid() })
  check('akun teknis tidak bisa menjual (K01)', adminSale.code === 'FORBIDDEN', adminSale.message)
  const unconfirmed = await rpc(staff, 'finalize_sale_v1', {
    operation_id: uid(), client_reference_id: uid(), items: saleInput.items, payment: { method: 'QRIS' },
  })
  check('QRIS tanpa konfirmasi ditolak (T02)', !unconfirmed.ok, unconfirmed.message)

  section('Kabel: potongan & roll (BR-03)')
  const cable = await productBySku(owner, 'DEMO-KABEL-15')
  const meter = cable.units.find(u => u.label === 'm')
  const rollUnit = cable.units.find(u => u.label === 'roll 100m')
  const positions = await must(staff, 'list_sellable_positions_v1', { product_id: cable.id })
  const piece = positions.positions.find(p => !p.sealed)
  const sealed = positions.positions.find(p => p.sealed)
  check('ada potongan terbuka dan roll bersegel', Boolean(piece && sealed))
  // Pratinjau sengaja tidak memeriksa stok; aturan potongan ditegakkan saat finalisasi (tanpa efek bila ditolak).
  const tooLong = await rpc(staff, 'finalize_sale_v1', {
    operation_id: uid(), client_reference_id: uid(), payment: { method: 'QRIS', confirmed: true },
    items: [{ product_unit_id: meter.id, qty: String(n(piece.qty_base) + 1), expected_unit_version: meter.version, position_id: piece.position_id }],
  })
  check('potongan tidak bisa melebihi panjangnya', tooLong.code === 'SEGMENT_TOO_SHORT', tooLong.message)
  const wholeFromPiece = await rpc(staff, 'finalize_sale_v1', {
    operation_id: uid(), client_reference_id: uid(), payment: { method: 'QRIS', confirmed: true },
    items: [{ product_unit_id: rollUnit.id, qty: '1', expected_unit_version: rollUnit.version, position_id: piece.position_id }],
  })
  check('roll utuh tidak bisa dari potongan', wholeFromPiece.code === 'SEGMENT_NOT_SEALED', wholeFromPiece.message)
  const cutSale = await must(staff, 'finalize_sale_v1', {
    operation_id: uid(), client_reference_id: uid(),
    items: [{ product_unit_id: meter.id, qty: '2.5', expected_unit_version: meter.version, position_id: piece.position_id }],
    payment: { method: 'QRIS', confirmed: true },
  })
  check('jual 2,5 m dari potongan terpilih', n(cutSale.total) === Math.round(2.5 * n(meter.sell_price)), cutSale.total)
  const positionsAfter = await must(staff, 'list_sellable_positions_v1', { product_id: cable.id })
  const pieceAfter = positionsAfter.positions.find(p => p.position_id === piece.position_id)
  const sealedAfter = positionsAfter.positions.find(p => p.position_id === sealed.position_id)
  check('potongan terpilih berkurang 2,5 m', n(pieceAfter.qty_base) === n(piece.qty_base) - 2.5)
  check('roll bersegel tidak disentuh', sealedAfter?.sealed === true && n(sealedAfter.qty_base) === n(sealed.qty_base))

  section('Struk, riwayat, retur')
  const invoice = await must(staff, 'get_invoice_v1', { invoice_id: sale.entity_id })
  const cashPayment = invoice.payments.find(p => p.direction === 'IN')
  check('struk memuat uang diterima & kembalian', n(cashPayment?.tendered) === 50000 && n(cashPayment?.change) === n(sale.change))
  check('struk memuat petugas', invoice.cashier_name === 'Budi Staff', invoice.cashier_name)
  const history = await must(staff, 'list_invoices_v1', { start_date: todayWib(), end_date: todayWib(), query: sale.document_number, limit: 5 })
  check('riwayat hari ini (WIB) menemukan nota', history.some(r => r.id === sale.entity_id))
  const staffReturn = await rpc(staff, 'return_sale_v1', { operation_id: uid(), invoice_id: sale.entity_id, reason: 'x', refund_method: 'CASH', items: [] })
  check('karyawan tidak bisa retur', staffReturn.code === 'FORBIDDEN', staffReturn.message)
  const item = invoice.items[0]
  const beforeReturn = await productBySku(owner, 'DEMO-LAMPU-12W')
  const ret = await must(owner, 'return_sale_v1', {
    operation_id: uid(), invoice_id: sale.entity_id, reason: 'VERIFY lampu mati', refund_method: 'CASH',
    items: [{ invoice_item_id: item.id, qty_base: '1', disposition: 'SALEABLE' }],
  })
  check('uang kembali retur 1 dari 2 = setengah nilai bersih', n(ret.refund_total) === n(item.net_total) / 2, ret.refund_total)
  const afterReturn = await productBySku(owner, 'DEMO-LAMPU-12W')
  check('stok layak jual kembali +1', n(afterReturn.stock_shop) === n(beforeReturn.stock_shop) + 1)
  const pcsFraction = await rpc(owner, 'return_sale_v1', {
    operation_id: uid(), invoice_id: sale.entity_id, reason: 'x', refund_method: 'CASH',
    items: [{ invoice_item_id: item.id, qty_base: '0.5', disposition: 'SALEABLE' }],
  })
  check('retur 0,5 pcs ditolak (T07)', !pcsFraction.ok, pcsFraction.message)

  section('Servis: alur lengkap sampai serah terima')
  const ticket = await must(staff, 'create_service_ticket_v1', {
    operation_id: uid(), customer_name: 'VERIFY Pelanggan', customer_phone: '081200001111',
    equipment_type: 'TV', complaint: 'Tidak menyala', initial_condition: 'Casing baik', service_location: 'STORE',
  })
  const list = await must(staff, 'list_service_tickets_v1', { query: ticket.number, limit: 5 })
  check('daftar tiket terbaca & memuat tiket baru (K12)', list.items.some(t => t.id === ticket.entity_id))
  const ticketId = ticket.entity_id
  const version = async () => (await must(owner, 'get_service_ticket_v1', { ticket_id: ticketId })).version
  await must(owner, 'transition_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), target_status: 'INSPECTING' })
  const noApproval = await rpc(owner, 'transition_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), target_status: 'WORKING' })
  check('mulai kerja tanpa persetujuan ditolak (T06)', !noApproval.ok, noApproval.message)
  const estimate = await must(owner, 'record_estimate_v1', {
    operation_id: uid(), ticket_id: ticketId, expected_version: await version(), description: 'Ganti kapasitor', min_amount: '60000', max_amount: '100000',
  })
  await must(owner, 'approve_estimate_v1', {
    operation_id: uid(), estimate_id: estimate.estimate_id, expected_version: estimate.estimate_version, agreed_limit: '100000', method: 'PHONE',
  })
  await must(owner, 'transition_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), target_status: 'WORKING' })
  const fakeTest = await rpc(owner, 'transition_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), target_status: 'READY', test_result: 'OK' })
  check('hasil uji "OK" ditolak', !fakeTest.ok, fakeTest.message)
  await must(owner, 'transition_service_v1', {
    operation_id: uid(), ticket_id: ticketId, expected_version: await version(), target_status: 'READY', test_result: 'Dinyalakan 30 menit normal',
  })
  const earlyHandover = await rpc(staff, 'handover_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), receiver_name: 'Pelanggan' })
  check('serah terima sebelum tagihan ditolak (K07)', earlyHandover.code === 'INVOICE_REQUIRED', earlyHandover.message)
  const overLimit = await rpc(owner, 'finalize_service_invoice_v1', {
    operation_id: uid(), ticket_id: ticketId, expected_version: await version(), approved_estimate_revision: 1,
    charge_lines: [{ kind: 'LABOR', description: 'Jasa', quantity: '1', unit_price: '5000000' }],
  })
  check('tagihan melebihi batas persetujuan ditolak (K08)', overLimit.code === 'APPROVAL_REQUIRED', overLimit.message)
  const serviceInvoice = await must(owner, 'finalize_service_invoice_v1', {
    operation_id: uid(), ticket_id: ticketId, expected_version: await version(), approved_estimate_revision: 1,
    charge_lines: [{ kind: 'LABOR', description: 'Ganti kapasitor', quantity: '1', unit_price: '80000' }],
  })
  check('tagihan final 80.000', n(serviceInvoice.total) === 80000)
  const partial = await rpc(staff, 'record_service_payment_v1', {
    operation_id: uid(), ticket_id: ticketId, amount: '50000', method: 'CASH', tendered: '50000',
  })
  check('cicilan setelah tagihan final ditolak', partial.code === 'PAYMENT_AMOUNT_MISMATCH', partial.message)
  const paid = await must(staff, 'record_service_payment_v1', {
    operation_id: uid(), ticket_id: ticketId, amount: '80000', method: 'CASH', tendered: '100000',
  })
  check('pelunasan tunai: kembalian dihitung server', n(paid.change) === 20000 && paid.payment.status === 'PAID')
  const handover = await must(staff, 'handover_service_v1', { operation_id: uid(), ticket_id: ticketId, expected_version: await version(), receiver_name: 'VERIFY Pelanggan' })
  check('serah terima setelah lunas', handover.custody_location === 'CUSTOMER' && Boolean(handover.closed_at))

  section('Foto tiket lewat Storage nyata (K13)')
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
  const photoTicket = await must(staff, 'create_service_ticket_v1', {
    operation_id: uid(), customer_name: 'VERIFY Foto', customer_phone: '081200002222',
    equipment_type: 'Radio', complaint: 'Uji foto', initial_condition: 'Baik', service_location: 'STORE',
  })
  const slot = await must(staff, 'prepare_attachment_v1', { operation_id: uid(), ticket_id: photoTicket.entity_id, mime: 'image/png', byte_size: png.length })
  const earlyFinalize = await rpc(staff, 'finalize_attachment_v1', { operation_id: uid(), attachment_id: slot.entity_id })
  check('finalisasi tanpa berkas ditolak', earlyFinalize.code === 'ATTACHMENT_INVALID', earlyFinalize.message)
  const upload = await fetch(`${API}/storage/v1/object/ticket-photos/${slot.object_key}`, {
    method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${staff}`, 'Content-Type': 'image/png' }, body: png,
  })
  check('unggah foto berhasil (dulu 403)', upload.ok, `${upload.status} ${await upload.clone().text().catch(() => '')}`)
  const finalized = await rpc(staff, 'finalize_attachment_v1', { operation_id: uid(), attachment_id: slot.entity_id })
  check('finalisasi foto', finalized.ok, finalized.message)
  const signed = await fetch(`${API}/storage/v1/object/sign/ticket-photos/${slot.object_key}`, {
    method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${admin}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: 60 }),
  })
  check('akun teknis dapat membuat tautan foto', signed.ok, String(signed.status))
  const stray = await fetch(`${API}/storage/v1/object/ticket-photos/${uid()}/${uid()}.png`, {
    method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${staff}`, 'Content-Type': 'image/png' }, body: png,
  })
  check('unggah ke alamat acak tanpa slot ditolak', !stray.ok, String(stray.status))

  section('Laporan & beranda (D2, K03)')
  const staffReport = await must(staff, 'get_report_v1', { start_date: todayWib(), end_date: todayWib() })
  check('karyawan melihat omzet tanpa modal', staffReport.sales && !('cost' in staffReport) && !('gross_profit' in staffReport))
  const ownerReport = await must(owner, 'get_report_v1', { start_date: todayWib(), end_date: todayWib() })
  check('pemilik melihat modal & laba kotor', Boolean(ownerReport.cost && ownerReport.gross_profit))
  check('neto = nota − retur', n(ownerReport.sales.net) === n(ownerReport.sales.invoice_total) - n(ownerReport.sales.credit_total))
  const dashboard = await must(staff, 'get_dashboard_v1', {})
  check('beranda memakai tanggal WIB', dashboard.server_date === todayWib(), dashboard.server_date)
  const csv = await must(staff, 'export_csv_v1', { dataset: 'invoices', start_date: todayWib(), end_date: todayWib(), limit: 2 })
  check('ekspor CSV terpaginasi (S03)', csv.count <= 2 && typeof csv.csv_header === 'string' && (csv.has_more ? Boolean(csv.next_cursor) : true))

  console.log(`\nHasil: ${passed} PASS, ${failed} FAIL`)
  process.exit(failed ? 1 : 0)
}

main().catch(err => {
  console.error(`\nVerifikasi berhenti: ${err.message}`)
  process.exit(1)
})
