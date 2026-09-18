import Decimal from 'decimal.js'
import { describe, expect, it } from 'vitest'
import {
  checkInvoice, closeOnsiteBlockers, draftInvoiceTotal, handoverBlockers, isoToShopLocal, lineTotal,
  netUsedParts, partQtyError, paymentFormError, refundLimit, settlementAmount, shopLocalToIso, testResultError,
} from './logic'
import { changedFields } from './detail/DetailsForm'
import type { PartEvent, PaymentState, TicketDetail } from './types'

const payment = (patch: Partial<PaymentState> = {}): PaymentState => ({
  status: 'UNPRICED', invoice_id: null, invoice_number: null, invoice_total: null, credit_total: null,
  invoice_net: null, received_total: '0', refunded_total: '0', correction_net: '0', net_received: '0',
  outstanding: null, refund_due: null, ...patch,
})

const ticket = (patch: Partial<TicketDetail> = {}): TicketDetail => ({
  id: 't1', number: 'SRV-1', version: 3, work_status: 'READY', service_location: 'STORE', custody_location: 'SHOP',
  equipment_type: 'TV', equipment_brand: null, equipment_model: null, equipment_serial: null, complaint: 'Mati',
  initial_condition: 'Lecet', accessories: null, address: null, scheduled_at: null, terminal_reason: null,
  test_result: 'Nyala normal', created_at: '2026-09-18T01:00:00Z', closed_at: null, mechanic_name: null,
  customer: null, parent_ticket: null, child_tickets: [], not_picked_up: true, allowed_transitions: [],
  approval: { latest_revision: 1, latest_status: 'APPROVED', active: true, approved_revision: 1, approved_limit: '100000' },
  status_events: [], custody_events: [], estimates: [], part_events: [], payments: [], invoice: null,
  payment: payment(), ...patch,
})

describe('tagihan servis (BR-09)', () => {
  it('baris dibulatkan half-up ke Rupiah seperti server', () => {
    expect(lineTotal('1.5', '33333').toFixed(0)).toBe('50000')
    expect(lineTotal('0.5', '1').toFixed(0)).toBe('1')
  })
  it('baris belum lengkap tidak dijumlahkan dan dilaporkan', () => {
    const result = draftInvoiceTotal([
      { quantity: '1', unitPrice: '50.000' },
      { quantity: '2', unitPrice: '' },
      { quantity: '1,5', unitPrice: '10000' },
    ])
    expect(result.total.toFixed(0)).toBe('65000')
    expect(result.invalid).toBe(1)
  })
  it('menolak total di atas batas persetujuan (bukti audit: 5 juta vs 100 ribu)', () => {
    const check = checkInvoice({ total: new Decimal('5000000'), approvedRevision: 1, approvedLimit: '100000', status: 'READY', waiverReason: '' })
    expect(check.ok).toBe(false)
  })
  it('menerima total tepat di batas', () => {
    expect(checkInvoice({ total: new Decimal('100000'), approvedRevision: 1, approvedLimit: '100000', status: 'READY', waiverReason: '' }))
      .toEqual({ ok: true, mode: 'APPROVED' })
  })
  it('tagihan nol tanpa persetujuan hanya untuk batal/tidak bisa diperbaiki dengan alasan', () => {
    const base = { total: new Decimal(0), approvedRevision: null, approvedLimit: null, waiverReason: 'Pelanggan batal' }
    expect(checkInvoice({ ...base, status: 'CANCELLED' })).toEqual({ ok: true, mode: 'WAIVER' })
    expect(checkInvoice({ ...base, status: 'READY' }).ok).toBe(false)
    expect(checkInvoice({ ...base, status: 'UNREPAIRABLE', waiverReason: ' ' }).ok).toBe(false)
    expect(checkInvoice({ ...base, total: new Decimal(1), status: 'CANCELLED' }).ok).toBe(false)
  })
})

describe('hasil uji & part', () => {
  it('menolak hasil uji palsu', () => {
    expect(testResultError('OK')).not.toBeNull()
    expect(testResultError('ok!')).not.toBeNull()
    expect(testResultError('12')).not.toBeNull()
    expect(testResultError('Dinyalakan 30 menit, gambar normal')).toBeNull()
  })
  it('qty part tidak boleh melebihi stok dan harus kelipatan langkah', () => {
    const position = { qty_base: '5.000', quantity_step: '1', base_unit: 'pcs' }
    expect(partQtyError('', position)).not.toBeNull()
    expect(partQtyError('6', position)).toContain('hanya')
    expect(partQtyError('0,5', position)).toContain('kelipatan')
    expect(partQtyError('2', position)).toBeNull()
  })
  it('part yang sudah dikembalikan penuh tidak ikut tagihan', () => {
    const base = { product_id: 'p', product_name: 'Kapasitor', sku: 'K', base_unit: 'pcs', charge_unit_price: '5000',
      reverses_event_id: null, reason: null, actor_name: null, occurred_at: '', invoiced: false, source_location: null, source_label: null }
    const parts = [
      { ...base, id: 'a', kind: 'USE', qty: '2', net_qty: '0' },
      { ...base, id: 'b', kind: 'USE', qty: '2', net_qty: '1' },
      { ...base, id: 'c', kind: 'REVERSE', qty: '2', net_qty: null },
    ] as PartEvent[]
    expect(netUsedParts(parts).map(p => p.id)).toEqual(['b'])
  })
})

describe('pembayaran servis (BR-07/BR-10)', () => {
  it('pelunasan hanya setelah tagihan final dan sebesar sisa tepat', () => {
    expect(settlementAmount(payment({ outstanding: '50000' }))).toBeNull()
    expect(settlementAmount(payment({ invoice_id: 'i', outstanding: '50000' }))).toBe('50000')
    expect(settlementAmount(payment({ invoice_id: 'i', outstanding: '0' }))).toBeNull()
  })
  it('batas refund: refund_due setelah final, DP hanya untuk tiket batal', () => {
    expect(refundLimit(ticket({ payment: payment({ invoice_id: 'i', refund_due: '20000' }) }))).toBe('20000')
    expect(refundLimit(ticket({ work_status: 'CANCELLED', payment: payment({ net_received: '100000' }) }))).toBe('100000')
    expect(refundLimit(ticket({ work_status: 'WORKING', payment: payment({ net_received: '100000' }) }))).toBeNull()
  })
  it('tunai wajib uang diterima ≥ jumlah; non-tunai wajib konfirmasi eksplisit', () => {
    expect(paymentFormError({ amount: '50000', method: 'CASH', tendered: '', confirmed: false })).not.toBeNull()
    expect(paymentFormError({ amount: '50000', method: 'CASH', tendered: '40.000', confirmed: false })).toContain('kurang')
    expect(paymentFormError({ amount: '50000', method: 'CASH', tendered: '50.000', confirmed: false })).toBeNull()
    expect(paymentFormError({ amount: '50000', method: 'TRANSFER', tendered: '', confirmed: false })).toContain('konfirmasi')
    expect(paymentFormError({ amount: '50000', method: 'QRIS', tendered: '', confirmed: true })).toBeNull()
  })
})

describe('serah terima & tutup kunjungan (BR-11, bukti audit K07)', () => {
  it('tiket READY tanpa tagihan tidak boleh diserahkan', () => {
    expect(handoverBlockers(ticket())).toContain('Tagihan belum final.')
  })
  it('sisa bayar atau refund tertunda menahan serah terima', () => {
    const owing = ticket({ payment: payment({ invoice_id: 'i', outstanding: '30000', refund_due: '0' }) })
    expect(handoverBlockers(owing).join(' ')).toContain('sisa bayar')
    const refund = ticket({ payment: payment({ invoice_id: 'i', outstanding: '0', refund_due: '5000' }) })
    expect(handoverBlockers(refund).join(' ')).toContain('dikembalikan')
  })
  it('lunas dan alat di toko: boleh diserahkan', () => {
    expect(handoverBlockers(ticket({ payment: payment({ invoice_id: 'i', outstanding: '0', refund_due: '0' }) }))).toEqual([])
  })
  it('kunjungan hanya ditutup bila alat ada di pelanggan', () => {
    const paid = payment({ invoice_id: 'i', outstanding: '0', refund_due: '0' })
    expect(closeOnsiteBlockers(ticket({ service_location: 'ONSITE', custody_location: 'CUSTOMER', payment: paid }))).toEqual([])
    expect(closeOnsiteBlockers(ticket({ service_location: 'ONSITE', custody_location: 'SHOP', payment: paid }))).not.toEqual([])
  })
})

describe('jadwal jam toko', () => {
  it('input datetime-local dianggap WIB, bukan zona perangkat', () => {
    expect(shopLocalToIso('2026-09-20T00:30')).toBe('2026-09-20T00:30:00+07:00')
    expect(shopLocalToIso('2026-09-20')).toBeNull()
    expect(isoToShopLocal('2026-09-19T17:30:00Z')).toBe('2026-09-20T00:30')
  })
})

describe('ubah data tiket', () => {
  const before = {
    equipment_type: 'TV', equipment_brand: '', equipment_model: '', equipment_serial: '',
    complaint: 'Mati', initial_condition: 'Lecet', accessories: '', address: 'Jl. A',
  }
  it('hanya mengirim kolom yang berubah (dirapikan)', () => {
    expect(changedFields(before, { ...before, equipment_brand: ' Sharp ', complaint: 'Mati ' }, false))
      .toEqual({ equipment_brand: 'Sharp' })
  })
  it('alamat hanya dikirim untuk kunjungan', () => {
    const after = { ...before, address: 'Jl. B' }
    expect(changedFields(before, after, false)).toEqual({})
    expect(changedFields(before, after, true)).toEqual({ address: 'Jl. B' })
  })
})
