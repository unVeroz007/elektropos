import { describe, expect, it } from 'vitest'
import { buildPostCount, countLineIssue, EMPTY_COUNT_LINE, hasConflict, type CountItem, type StockCount } from './countModel'

const item = (patch: Partial<CountItem> = {}): CountItem => ({
  line_no: 1, position_id: 'pos-1', product_id: 'p', sku: 'LMP', name: 'Lampu', base_unit: 'pcs', quantity_step: '1',
  track_segments: false, label: null, location: 'SHOP', condition: 'SALEABLE', system_qty: '10', expected_version: 2,
  current_qty: '10', current_version: 2, changed_since_start: false, counted_qty: null, difference: null,
  cost_delta: null, reason: null, ...patch,
})
const count = (items: CountItem[]): StockCount => ({
  id: 'c1', status: 'DRAFT', version: 1, note: null, created_at: '', posted_at: null, document_number: null, items,
})

describe('hitung stok (FR-INV-03, bukti audit: counted -5 dulu tidak divalidasi)', () => {
  it('hasil hitung wajib, tidak negatif, dan kelipatan langkah', () => {
    expect(countLineIssue(item(), EMPTY_COUNT_LINE)).toContain('Isi hasil hitung')
    expect(countLineIssue(item(), { ...EMPTY_COUNT_LINE, counted: '-5' })).not.toBeNull()
    expect(countLineIssue(item(), { ...EMPTY_COUNT_LINE, counted: '2,5' })).toContain('kelipatan')
    expect(countLineIssue(item(), { ...EMPTY_COUNT_LINE, counted: '0' })).toBeNull()
  })
  it('kelebihan stok wajib modal terkonfirmasi atau alasan (BR-06)', () => {
    const base = { ...EMPTY_COUNT_LINE, counted: '12' }
    expect(countLineIssue(item(), base)).toContain('modal')
    expect(countLineIssue(item(), { ...base, cost: '24.000' })).toContain('Centang')
    expect(countLineIssue(item(), { ...base, cost: '24.000', costConfirmed: true })).toBeNull()
    expect(countLineIssue(item(), { ...base, costMode: 'ZERO', zeroReason: 'Sisa ukur' })).toBeNull()
  })
  it('kelebihan kabel menjadi potongan baru berlabel', () => {
    const cable = item({ base_unit: 'm', quantity_step: '0.1', track_segments: true, system_qty: '50' })
    const form = { ...EMPTY_COUNT_LINE, counted: '51', costMode: 'ZERO' as const, zeroReason: 'Sisa ukur' }
    expect(countLineIssue(cable, form)).toContain('label')
    expect(countLineIssue(cable, { ...form, newLabel: 'R2-K1' })).toBeNull()
  })
  it('payload mengirim setiap posisi tepat sekali dengan field sesuai selisih', () => {
    const result = buildPostCount(count([item(), item({ position_id: 'pos-2', system_qty: '5' })]), {
      'pos-1': { ...EMPTY_COUNT_LINE, counted: '9', reason: 'Pecah' },
      'pos-2': { ...EMPTY_COUNT_LINE, counted: '6', cost: '12.000', costConfirmed: true },
    }, '')
    expect(result).toEqual({
      reason: 'Hitung stok',
      items: [
        { position_id: 'pos-1', counted_qty: '9', reason: 'Pecah' },
        { position_id: 'pos-2', counted_qty: '6', acquisition_cost: '12000', cost_confirmed: true },
      ],
    })
  })
  it('posisi yang belum dihitung menghentikan posting', () => {
    expect(buildPostCount(count([item()]), {}, 'x')).toEqual({ issue: 'Lampu: Isi hasil hitung (0 bila habis).' })
  })
  it('perubahan sejak mulai terdeteksi', () => {
    expect(hasConflict(count([item({ changed_since_start: true })]))).toBe(true)
  })
})
