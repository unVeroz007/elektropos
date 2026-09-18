import { describe, expect, it } from 'vitest'
import { EMPTY_SETTLE, OUTCOMES, replacementLinesFor, settlePayload } from './returnModel'

const lamp = {
  id: 'p-lamp', name: 'Lampu LED', sku: 'LMP', base_unit: 'pcs', track_segments: false,
  units: [{ id: 'u-pcs', label: 'pcs', factor_base: '1', is_default: true }],
}
const cable = {
  id: 'p-cable', name: 'Kabel NYA', sku: 'KBL', base_unit: 'm', track_segments: true,
  units: [
    { id: 'u-roll', label: 'roll 100m', factor_base: '100', is_default: true },
    { id: 'u-m', label: 'm', factor_base: '1', is_default: false },
  ],
}

describe('retur distributor diganti barang (keputusan pemilik 18-09-2026)', () => {
  it('barang pengganti menjadi pilihan utama', () => {
    expect(EMPTY_SETTLE.outcome).toBe('REPLACEMENT')
    expect(OUTCOMES[0]).toBe('REPLACEMENT')
  })

  it('usulan pengganti = barang & jumlah yang dikembalikan, dijumlah per barang, dalam satuan stok', () => {
    const lines = replacementLinesFor([
      { product_id: 'p-lamp', qty_base: '3.000' },
      { product_id: 'p-cable', qty_base: '60.000' },
      { product_id: 'p-cable', qty_base: '40.000' },
      { product_id: 'p-hilang', qty_base: '1' },
    ], [lamp, cable])
    expect(lines.map(l => [l.productId, l.unitId, l.qty])).toEqual([
      ['p-lamp', 'u-pcs', '3'],
      ['p-cable', 'u-m', '100'],
    ])
    // Kabel dilacak per roll: pembagian roll ikut terisi agar langsung bisa disimpan.
    expect(lines[1].rollCount).toBe('1')
    expect(lines[1].rollCapacity).toBe('100')
  })

  it('usulan langsung menjadi payload sah tanpa modal (modal = nilai klaim di server)', () => {
    const lines = replacementLinesFor([{ product_id: 'p-lamp', qty_base: '2' }], [lamp])
    const built = settlePayload('ret-1', 3, { ...EMPTY_SETTLE, lines })
    expect(built).toEqual({
      payload: {
        supplier_return_id: 'ret-1', expected_version: 3, outcome: 'REPLACEMENT',
        items: [{ product_unit_id: 'u-pcs', qty: '2' }],
      },
    })
  })
})
