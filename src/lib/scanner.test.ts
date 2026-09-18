import { describe, expect, it } from 'vitest'
import { createHidState, feedHidKey, normalizeBarcode } from './scanner'

function typeFast(state: ReturnType<typeof createHidState>, text: string, start: number, gap = 10): number {
  let t = start
  for (const ch of text) {
    feedHidKey(state, ch, t)
    t += gap
  }
  return t
}

describe('scanner barcode', () => {
  it('menormalkan spasi tanpa membuang nol di depan', () => {
    expect(normalizeBarcode('  0012345678901 ')).toBe('0012345678901')
    expect(normalizeBarcode('8 991 001')).toBe('8991001')
  })

  it('mendeteksi scan HID saat Enter ditekan', () => {
    const state = createHidState()
    const t = typeFast(state, '8991001001001', 1000)
    expect(feedHidKey(state, 'Enter', t)).toBe('8991001001001')
  })

  it('menolak Enter dengan kode terlalu pendek', () => {
    const state = createHidState()
    feedHidKey(state, 'a', 1000)
    expect(feedHidKey(state, 'Enter', 1005)).toBeNull()
  })

  it('memisahkan ketikan lambat sebagai scan baru', () => {
    const state = createHidState()
    for (const ch of '111111') feedHidKey(state, ch, 1000)
    const t = typeFast(state, '222222', 2000)
    expect(feedHidKey(state, 'Enter', t)).toBe('222222')
  })

  it('ketikan manual lambat lalu Enter tidak dianggap scan (tidak memotong kode)', () => {
    const state = createHidState()
    const t = typeFast(state, '899100', 1000, 250)
    expect(feedHidKey(state, 'Enter', t)).toBeNull()
  })

  it('Enter yang datang lama setelah ketikan cepat tidak dianggap scan', () => {
    const state = createHidState()
    const t = typeFast(state, '12345', 1000)
    expect(feedHidKey(state, 'Enter', t + 2000)).toBeNull()
  })

  it('mengabaikan tombol non-karakter', () => {
    const state = createHidState()
    expect(feedHidKey(state, 'Shift', 1000)).toBeNull()
    expect(feedHidKey(state, 'ArrowUp', 1001)).toBeNull()
    expect(feedHidKey(state, 'Escape', 1002)).toBeNull()
    expect(state.buffer).toBe('')
  })
})
