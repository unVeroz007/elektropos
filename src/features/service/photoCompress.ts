/**
 * Kompresi foto di browser sebelum unggah (S07).
 *
 * Foto kamera HP (4–12 MB) dikecilkan: sisi terpanjang maks ±1600px, JPEG,
 * target ≤ 1 MiB (batas server). Menggambar ulang ke canvas sekaligus membuang
 * metadata EXIF (lokasi GPS, model HP) karena berkas baru hanya berisi piksel.
 */

export const MAX_UPLOAD_BYTES = 1024 * 1024
export const MAX_SIDE = 1600
export const OUTPUT_MIME = 'image/jpeg'
const QUALITIES = [0.85, 0.75, 0.65, 0.55, 0.45]
const MIN_SIDE = 480

export type Size = { width: number; height: number }

/** Skala agar sisi terpanjang ≤ maxSide, rasio tetap, tidak pernah memperbesar. */
export function fitWithin(source: Size, maxSide = MAX_SIDE): Size {
  const longest = Math.max(source.width, source.height)
  if (longest <= 0) throw new Error('Ukuran gambar tidak sah.')
  const scale = Math.min(1, maxSide / longest)
  return {
    width: Math.max(1, Math.round(source.width * scale)),
    height: Math.max(1, Math.round(source.height * scale)),
  }
}

export type Encoder = (size: Size, quality: number) => Promise<Blob>

/**
 * Coba kualitas menurun; bila masih > batas, perkecil 80% dan ulangi.
 * Encoder disuntikkan agar logika dapat diuji tanpa canvas.
 */
export async function compressToLimit(source: Size, encode: Encoder, maxBytes = MAX_UPLOAD_BYTES): Promise<{ blob: Blob; size: Size }> {
  let size = fitWithin(source)
  for (;;) {
    for (const quality of QUALITIES) {
      const blob = await encode(size, quality)
      if (blob.size > 0 && blob.size <= maxBytes) return { blob, size }
    }
    if (Math.max(size.width, size.height) <= MIN_SIDE) break
    size = fitWithin(size, Math.round(Math.max(size.width, size.height) * 0.8))
  }
  throw new Error('Foto tidak dapat dikecilkan di bawah 1 MB. Coba foto lain.')
}

type Drawable = { source: CanvasImageSource; size: Size; close: () => void }

async function decode(file: Blob): Promise<Drawable> {
  if (typeof createImageBitmap === 'function') {
    // imageOrientation 'from-image' memutar sesuai EXIF sebelum metadata dibuang.
    const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
    return { source: bitmap, size: { width: bitmap.width, height: bitmap.height }, close: () => bitmap.close() }
  }
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    return { source: img, size: { width: img.naturalWidth, height: img.naturalHeight }, close: () => undefined }
  } finally {
    URL.revokeObjectURL(url)
  }
}

function canvasEncoder(drawable: Drawable): Encoder {
  return (size, quality) => new Promise<Blob>((resolve, reject) => {
    const canvas = document.createElement('canvas')
    canvas.width = size.width
    canvas.height = size.height
    const context = canvas.getContext('2d')
    if (!context) { reject(new Error('Perangkat tidak dapat memproses foto.')); return }
    context.fillStyle = '#ffffff' // PNG transparan → latar putih pada JPEG
    context.fillRect(0, 0, size.width, size.height)
    context.drawImage(drawable.source, 0, 0, size.width, size.height)
    canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('Foto gagal diproses.')), OUTPUT_MIME, quality)
  })
}

/** Kecilkan foto dan buang metadata. Hasil selalu JPEG ≤ 1 MiB. */
export async function compressPhoto(file: Blob): Promise<Blob> {
  if (!file.type.startsWith('image/')) throw new Error('Berkas bukan foto. Pilih foto JPG, PNG, atau WebP.')
  let drawable: Drawable
  try {
    drawable = await decode(file)
  } catch {
    throw new Error('Foto tidak dapat dibuka. Coba ambil ulang atau pilih foto lain.')
  }
  try {
    const { blob } = await compressToLimit(drawable.size, canvasEncoder(drawable))
    return blob
  } finally {
    drawable.close()
  }
}
