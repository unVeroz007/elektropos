import { describe, expect, it } from 'vitest'
import { allocateCost, parseQuantity, rupiahHalfUp, toBaseQuantity } from './numbers'

describe('aturan angka P1', () => {
  it('mengonversi meter dan menolak pecahan stok tak tepat', () => {
    expect(toBaseQuantity('2.500', '1', '0.100')).toBe('2.500')
    expect(() => toBaseQuantity('0.001', '0.100', '0.001')).toThrow()
    expect(() => toBaseQuantity('1.500', '1', '1')).toThrow()
  })
  it('menolak input ambigu dan presisi lebih dari tiga desimal', () => {
    expect(parseQuantity('2,5').toString()).toBe('2.5')
    expect(() => parseQuantity('1.000,5')).toThrow()
    expect(() => parseQuantity('0,0001')).toThrow()
    expect(() => parseQuantity('Infinity')).toThrow()
  })
  it('membulatkan tagihan dan modal tanpa float', () => {
    expect(rupiahHalfUp('9000.9')).toBe('9001')
    expect(allocateCost('500000', '2.500', '100')).toBe('12500.000000')
    expect(allocateCost('0.000001', '0.100', '0.100')).toBe('0.000001')
  })
})
