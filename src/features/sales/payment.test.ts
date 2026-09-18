import { describe, expect, it } from 'vitest'
import { buildFinalizeInput, buildPreviewInput, payBlocker, type PayContext, type PaymentForm } from './payment'
import type { SalePreview } from './types'

const preview = (patch: Partial<SalePreview> = {}): SalePreview => ({
  ok: true, subtotal: '37500', discount: '0', total: '37500', requires_owner_reason: false,
  tendered: null, change: null, items: [], ...patch,
})
const form = (patch: Partial<PaymentForm> = {}): PaymentForm => ({
  method: 'CASH', tenderedText: '', tendered: null, confirmedTotal: null, reference: '', freeReason: '', ...patch,
})
const ctx = (patch: Partial<PayContext> = {}): PayContext => ({
  canSell: true, canDiscount: false, online: true, lineCount: 1, hasIssues: false, priceReview: false,
  drawerClosed: false, preview: { status: 'ready', data: preview() }, form: form(), ...patch,
})
const base = { client_reference_id: 'c1', items: [{ product_unit_id: 'u', qty: '1', expected_unit_version: 1 }] }

describe('tombol Bayar (BR-07)', () => {
  it('offline memblokir pembayaran (FR-RES-01)', () => {
    expect(payBlocker(ctx({ online: false }))).toContain('Internet')
  })
  it('menunggu total server; tidak memakai hitungan klien', () => {
    expect(payBlocker(ctx({ preview: { status: 'loading', last: preview() } }))).toContain('Menunggu')
  })
  it('tunai: laci tertutup, uang kosong, dan uang kurang memblokir', () => {
    expect(payBlocker(ctx({ drawerClosed: true, form: form({ tenderedText: '50000', tendered: '50000' }) }))).toContain('Laci')
    expect(payBlocker(ctx())).toContain('uang yang diterima')
    expect(payBlocker(ctx({ form: form({ tenderedText: '30.000', tendered: '30000' }) }))).toContain('kurang Rp7.500')
    expect(payBlocker(ctx({ form: form({ tenderedText: '50.000', tendered: '50000' }) }))).toBeNull()
  })
  it('transfer/QRIS wajib konfirmasi eksplisit untuk total yang sedang tampil (bukti audit T02)', () => {
    expect(payBlocker(ctx({ form: form({ method: 'QRIS' }) }))).toContain('Centang')
    expect(payBlocker(ctx({ form: form({ method: 'QRIS', confirmedTotal: '30000' }) }))).toContain('Centang')
    expect(payBlocker(ctx({ form: form({ method: 'QRIS', confirmedTotal: '37500' }) }))).toBeNull()
  })
  it('nota Rp0 hanya pemilik dengan alasan', () => {
    const free = { status: 'ready' as const, data: preview({ total: '0', requires_owner_reason: true }) }
    expect(payBlocker(ctx({ preview: free }))).toContain('pemilik')
    expect(payBlocker(ctx({ preview: free, canDiscount: true }))).toContain('alasan')
    expect(payBlocker(ctx({ preview: free, canDiscount: true, form: form({ freeReason: 'Hadiah' }) }))).toBeNull()
  })
})

describe('payload pembayaran', () => {
  it('tunai mengirim uang diterima; kembalian dihitung server', () => {
    expect(buildFinalizeInput(base, preview(), form({ tendered: '50000' })).payment).toEqual({ method: 'CASH', tendered: '50000' })
  })
  it('transfer mengirim konfirmasi dan referensi bila ada', () => {
    expect(buildFinalizeInput(base, preview(), form({ method: 'TRANSFER', reference: ' BCA 123 ' })).payment)
      .toEqual({ method: 'TRANSFER', confirmed: true, reference: 'BCA 123' })
  })
  it('nota Rp0 mengirim alasan tanpa pembayaran', () => {
    const input = buildFinalizeInput(base, preview({ requires_owner_reason: true }), form({ freeReason: ' Hadiah ' }))
    expect(input.payment).toBeNull()
    expect(input.reason).toBe('Hadiah')
  })
  it('pratinjau hanya menyertakan tunai yang sah', () => {
    expect(buildPreviewInput(base, form({ tendered: null }))).toEqual(base)
    expect(buildPreviewInput(null, form())).toBeNull()
  })
})
