import { describe, expect, it } from 'vitest'
import { compressToLimit, fitWithin, MAX_UPLOAD_BYTES, type Size } from './photoCompress'

/** Encoder palsu: ukuran berkas sebanding piksel × kualitas. */
const fakeEncoder = (bytesPerPixel: number) => async (size: Size, quality: number) =>
  new Blob([new Uint8Array(Math.round(size.width * size.height * bytesPerPixel * quality))])

describe('kompresi foto (S07)', () => {
  it('memperkecil sisi terpanjang tanpa mengubah rasio', () => {
    expect(fitWithin({ width: 4000, height: 3000 })).toEqual({ width: 1600, height: 1200 })
    expect(fitWithin({ width: 3000, height: 4000 })).toEqual({ width: 1200, height: 1600 })
  })
  it('tidak pernah memperbesar foto kecil', () => {
    expect(fitWithin({ width: 800, height: 600 })).toEqual({ width: 800, height: 600 })
  })
  it('menolak ukuran tidak sah', () => {
    expect(() => fitWithin({ width: 0, height: 0 })).toThrow()
  })
  it('menurunkan kualitas lalu ukuran sampai ≤ 1 MiB', async () => {
    const { blob, size } = await compressToLimit({ width: 4000, height: 3000 }, fakeEncoder(1))
    expect(blob.size).toBeLessThanOrEqual(MAX_UPLOAD_BYTES)
    expect(Math.max(size.width, size.height)).toBeLessThanOrEqual(1600)
  })
  it('menyerah dengan pesan jelas bila tidak mungkin di bawah batas', async () => {
    await expect(compressToLimit({ width: 4000, height: 3000 }, fakeEncoder(100))).rejects.toThrow('1 MB')
  })
})
