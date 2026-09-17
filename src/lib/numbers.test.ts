import { describe, expect, it } from 'vitest'
import {
  formatQuantity, formatRupiah, parsePercent, parseQuantity, parseRupiah, quantityOrNull, rupiahOrNull, todayInShop,
} from './numbers'

describe('parseQuantity (BR-01)', () => {
  it('menerima koma atau titik desimal hingga 3 angka', () => {
    expect(parseQuantity('2,5').toFixed()).toBe('2.5')
    expect(parseQuantity(' 2.125 ').toFixed()).toBe('2.125')
  })
  it('menolak format ambigu, presisi berlebih, dan nilai tak hingga', () => {
    for (const bad of ['1.000,5', '0,0001', 'Infinity', 'NaN', '-1', '1e3', '', ' ', '1,2,3']) {
      expect(() => parseQuantity(bad), bad).toThrow()
    }
  })
  it('menolak nilai di atas batas', () => {
    expect(() => parseQuantity('1000000000')).toThrow()
  })
  it('quantityOrNull tidak melempar untuk input sementara saat mengetik', () => {
    expect(quantityOrNull('')).toBeNull()
    expect(quantityOrNull('0')).toBeNull()
    expect(quantityOrNull('3,')).toBeNull()
    expect(quantityOrNull('3,5')).toBe('3.5')
  })
})

describe('parseRupiah', () => {
  it('menerima angka polos dan pemisah ribuan titik/spasi', () => {
    expect(parseRupiah('50000').toFixed(0)).toBe('50000')
    expect(parseRupiah('Rp 1.250.000').toFixed(0)).toBe('1250000')
    expect(parseRupiah('7 500').toFixed(0)).toBe('7500')
  })
  it('menolak pecahan, kelompok ribuan salah, dan negatif', () => {
    for (const bad of ['1000,50', '1.00', '12.3456', '-500', 'abc', '']) {
      expect(rupiahOrNull(bad), bad).toBeNull()
    }
  })
})

describe('parsePercent', () => {
  it('membatasi 0-100 dengan 4 desimal', () => {
    expect(parsePercent('12,5').toFixed()).toBe('12.5')
    expect(() => parsePercent('100.0001')).toThrow()
    expect(() => parsePercent('-1')).toThrow()
  })
})

describe('format tampilan', () => {
  it('memformat Rupiah dengan pembulatan half-up dan ribuan titik', () => {
    expect(formatRupiah('18750.5')).toBe('Rp18.751')
    expect(formatRupiah('9999999999999999')).toBe('Rp9.999.999.999.999.999')
    expect(formatRupiah('-2500')).toBe('-Rp2.500')
  })
  it('memformat kuantitas dengan koma desimal dan satuan', () => {
    expect(formatQuantity('2.500', 'm')).toBe('2,5 m')
    expect(formatQuantity('1200.000', 'pcs')).toBe('1.200 pcs')
  })
  it('tanggal hari ini memakai zona Asia/Jakarta', () => {
    expect(todayInShop()).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })
})
