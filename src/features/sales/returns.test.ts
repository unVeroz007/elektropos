import Decimal from 'decimal.js'
import { describe, expect, it } from 'vitest'
import { buildReturnInput, EMPTY_RETURN_LINE, estimateLineRefund, returnLineIssue, type ReturnLineForm } from './returns'
import type { InvoiceItem } from './types'

const item = (patch: Partial<InvoiceItem> = {}): InvoiceItem => ({
  id: 'i1', line_no: 1, kind: 'PRODUCT', product_id: 'p', product_unit_id: 'u', description: 'Lampu', unit_label: 'pcs',
  qty_sell: '3', factor: '1', qty_base: '3', unit_price: '18000', discount_mode: null, discount_value: null,
  line_discount: '0', base_net: '54000', invoice_discount_alloc: '1', net_total: '53999', returned_qty: '0',
  returnable_qty: '3', cost_allocations: [], ...patch,
})
const pcs = { base_unit: 'pcs', quantity_step: '1', track_segments: false }
const form = (patch: Partial<ReturnLineForm>): ReturnLineForm => ({ ...EMPTY_RETURN_LINE, selected: true, ...patch })

describe('uang kembali retur (BR-08)', () => {
  it('retur 1 dari 3 tiga kali menjumlah tepat ke nilai bersih baris', () => {
    const first = estimateLineRefund(item(), new Decimal(1))
    const second = estimateLineRefund(item({ returned_qty: '1' }), new Decimal(1))
    const third = estimateLineRefund(item({ returned_qty: '2' }), new Decimal(1))
    expect([first, second, third].map(v => v.toFixed(0))).toEqual(['18000', '17999', '18000'])
    expect(first.plus(second).plus(third).toFixed(0)).toBe('53999')
  })
})

describe('validasi retur', () => {
  it('barang pcs tidak bisa dikembalikan pecahan (bukti audit T07)', () => {
    expect(returnLineIssue(form({ qtyText: '0,5' }), item(), pcs)).toContain('pecahan')
  })
  it('tidak melebihi sisa yang bisa dikembalikan', () => {
    expect(returnLineIssue(form({ qtyText: '2' }), item({ returned_qty: '2', returnable_qty: '1' }), pcs)).toContain('Paling banyak')
  })
  it('alokasi asal barang harus berjumlah sama dengan qty retur', () => {
    const allocations = [
      { id: 'a', lot_id: 'l1', lot_posted_at: '', origin_position_id: 'x', origin_label: 'LOT-A', qty_base: '6', reversed_qty: '0' },
      { id: 'b', lot_id: 'l2', lot_posted_at: '', origin_position_id: 'y', origin_label: 'LOT-B', qty_base: '4', reversed_qty: '0' },
    ]
    const cable = item({ unit_label: 'm', qty_sell: '10', qty_base: '10', returnable_qty: '10', cost_allocations: allocations })
    const meter = { base_unit: 'm', quantity_step: '0.1', track_segments: true }
    expect(returnLineIssue(form({ qtyText: '10', manualAllocation: true, allocationTexts: { a: '6', b: '3' } }), cable, meter))
      .toContain('harus 10 m')
    expect(returnLineIssue(form({ qtyText: '10', manualAllocation: true, allocationTexts: { a: '7', b: '3' } }), cable, meter))
      .toContain('melebihi')
    expect(returnLineIssue(form({ qtyText: '10', manualAllocation: true, allocationTexts: { a: '6', b: '4' } }), cable, meter)).toBeNull()
  })
})

describe('payload retur', () => {
  const state = (patch = {}) => ({ forms: { i1: form({ qtyText: '1' }) }, reason: 'Rusak', refundMethod: 'CASH' as const, refundReference: '', ...patch })
  it('alasan dan cara uang kembali wajib', () => {
    expect(buildReturnInput('inv', [item()], { p: pcs }, state({ reason: ' ' }))).toEqual({ issue: 'Isi alasan retur.' })
    expect(buildReturnInput('inv', [item()], { p: pcs }, state({ refundMethod: '' }))).toEqual({ issue: 'Pilih cara uang dikembalikan.' })
  })
  it('nota Rp0 bisa diretur tanpa cara uang kembali', () => {
    const zero = item({ base_net: '0', net_total: '0' })
    const result = buildReturnInput('inv', [zero], { p: pcs }, state({ refundMethod: '' }))
    expect(result).toEqual({ input: { invoice_id: 'inv', reason: 'Rusak', items: [{ invoice_item_id: 'i1', qty_base: '1', disposition: 'SALEABLE' }] } })
  })
  it('qty dikirim dalam satuan dasar', () => {
    const roll = item({ unit_label: 'roll', factor: '100', qty_sell: '2', qty_base: '200', returnable_qty: '200' })
    const result = buildReturnInput('inv', [roll], { p: { base_unit: 'm', quantity_step: '0.1', track_segments: true } }, state())
    expect('input' in result && result.input.items[0].qty_base).toBe('100')
  })
})
