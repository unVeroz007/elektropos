import { describe, expect, it } from 'vitest'
import { buildProductPayload, canBeWholeRoll, EMPTY_FORM, KIND_PRESETS, unitChanged, type ProductFormState } from './productForm'

const cable = (patch: Partial<ProductFormState> = {}): ProductFormState => ({
  ...EMPTY_FORM, ...KIND_PRESETS.METER, sku: 'KBL', name: 'Kabel NYA', sell_price: '7.500', ...patch,
})

describe('satuan roll utuh (keputusan pemilik 18-09-2026)', () => {
  it('pilihan roll utuh hanya untuk barang roll dengan isi satuan > 1', () => {
    expect(canBeWholeRoll(cable())).toBe(false)
    expect(canBeWholeRoll(cable({ unit_label: 'roll 100 m', factor_base: '100', sale_step: '1' }))).toBe(true)
    expect(canBeWholeRoll({ ...EMPTY_FORM, factor_base: '12' })).toBe(false)
  })

  it('isi > 1 tidak otomatis roll utuh: dikirim sesuai pilihan pemilik', () => {
    const bundle = cable({ unit_label: 'ikat 10 m', factor_base: '10', sale_step: '1', sell_price: '70.000' })
    expect(buildProductPayload(bundle).whole_roll).toBe(false)
    expect(buildProductPayload({ ...bundle, unit_label: 'roll 100 m', factor_base: '100', whole_roll: true }).whole_roll).toBe(true)
  })

  it('tanda tersisa tidak ikut terkirim bila barang/satuan tidak memenuhi syarat', () => {
    expect(buildProductPayload(cable({ whole_roll: true })).whole_roll).toBe(false)
  })

  it('mengubah tanda roll utuh dianggap perubahan satuan (versi satuan baru)', () => {
    const roll = cable({ unit_label: 'roll 100 m', factor_base: '100', sale_step: '1', whole_roll: true })
    expect(unitChanged(roll, { ...roll, whole_roll: false })).toBe(true)
    expect(unitChanged(roll, { ...roll, name: 'Kabel NYA merah' })).toBe(false)
  })
})
