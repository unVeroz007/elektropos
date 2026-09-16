import { describe, expect, it } from 'vitest'
import { createHidState, feedHidKey, normalizeBarcode } from './scanner'

describe('scanner barcode', () => {
  it('menormalkan spasi tanpa membuang nol di depan', () => {
    expect(normalizeBarcode('  0012345678901 ')).toBe('0012345678901')
    expect(normalizeBarcode('8 991 001')).toBe('8991001')
  })

  it('mendeteksi scan HID saat Enter ditekan', () => {
    const state = createHidState()
    const chars = '8991001001001'.split('')
    let result: string | null = null
    let t = 1000
    for (const ch of chars) {
      result = feedHidKey(state, ch, t)
      t += 10
    }
    expect(result).toBeNull()
    result = feedHidKey(state, 'Enter', t)
    expect(result).toBe('8991001001001')
  })

  it('menolak Enter dengan kode terlalu pendek', () => {
    const state = createHidState()
    feedHidKey(state, 'a', 1000)
    expect(feedHidKey(state, 'Enter', 1005)).toBeNull()
  })

  it('memisahkan ketikan lambat sebagai scan baru', () => {
    const state = createHidState()
    for (const ch of '111111') feedHidKey(state, ch, 1000)
    let t = 2000
    for (const ch of '222222') {
      feedHidKey(state, ch, t)
      t += 10
    }
    expect(feedHidKey(state, 'Enter', t)).toBe('222222')
  })

  it('mengabaikan tombol non-karakter', () => {
    const state = createHidState()
    expect(feedHidKey(state, 'Shift', 1000)).toBeNull()
    expect(feedHidKey(state, 'ArrowUp', 1001)).toBeNull()
    expect(state.buffer).toBe('')
  })

  it('mengabaikan panah yang dipencet panjang', () => {
    const state = createHidState()
    expect(feedHidKey(state, 'ArrowDown', 1000)).toBeNull()
    expect(feedHidKey(state, 'Escape', 1000)).toBeNull()
    expect(state.buffer).toBe('')
  })
})
