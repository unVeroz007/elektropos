/**
 * Utilitas barcode scanner.
 *
 * Dua mode:
 *  - HID keyboard (scanner fisik): ketikan cepat diakhiri Enter pada satu input.
 *  - Kamera (laptop/HP): BarcodeDetector API bila tersedia.
 *
 * Prinsip keamanan UX (WF-01): handler hanya aktif pada konteks scan,
 * tidak mencegat seluruh keyboard. Karena itu hook HID menempel pada elemen
 * input yang diberikan, bukan pada `window`.
 */

const HID_MIN_LENGTH = 3
const HID_MAX_GAP_MS = 80

export function normalizeBarcode(raw: string): string {
  return raw.trim().replace(/\s+/g, '')
}

export type HidScanState = {
  buffer: string
  lastAt: number
}

export function createHidState(): HidScanState {
  return { buffer: '', lastAt: 0 }
}

/**
 * Proses satu tombol. Mengembalikan kode penuh bila scan terdeteksi,
 * atau null bila masih mengetik.
 */
export function feedHidKey(state: HidScanState, key: string, now: number): string | null {
  if (key === 'Enter') {
    const code = normalizeBarcode(state.buffer)
    state.buffer = ''
    state.lastAt = 0
    return code.length >= HID_MIN_LENGTH ? code : null
  }
  if (key.length !== 1) return null

  const gap = now - state.lastAt
  if (state.lastAt !== 0 && gap > HID_MAX_GAP_MS && state.buffer.length >= HID_MIN_LENGTH) {
    // Ketikan lama dianggap scan sebelumnya; mulai buffer baru
    state.buffer = ''
  }
  state.lastAt = now
  state.buffer += key
  return null
}
