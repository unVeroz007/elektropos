/**
 * Utilitas barcode scanner.
 *
 * Dua mode:
 *  - HID keyboard (scanner fisik): ketikan sangat cepat diakhiri Enter pada satu input.
 *  - Kamera (laptop/HP): dekode frame video (lihat useScanner.ts).
 *
 * Prinsip keamanan UX (WF-01): handler hanya aktif pada konteks scan,
 * tidak mencegat seluruh keyboard. Karena itu hook HID menempel pada elemen
 * input yang diberikan, bukan pada `window`.
 */

export const HID_MIN_LENGTH = 3
/** Jeda maksimum antar karakter yang masih dianggap keluaran scanner (ms). */
export const HID_MAX_GAP_MS = 80

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
 * atau null bila masih mengetik / ketikan manusia biasa.
 *
 * Buffer hanya berisi karakter yang datang beruntun cepat. Ketikan lambat
 * (manusia) selalu memulai buffer baru, sehingga Enter setelah mengetik manual
 * tidak pernah menghasilkan potongan kode yang salah.
 */
export function feedHidKey(state: HidScanState, key: string, now: number): string | null {
  if (key === 'Enter') {
    const fresh = state.lastAt !== 0 && now - state.lastAt <= HID_MAX_GAP_MS * 3
    const code = normalizeBarcode(state.buffer)
    state.buffer = ''
    state.lastAt = 0
    return fresh && code.length >= HID_MIN_LENGTH ? code : null
  }
  if (key.length !== 1) return null

  if (state.lastAt !== 0 && now - state.lastAt > HID_MAX_GAP_MS) state.buffer = ''
  state.lastAt = now
  state.buffer += key
  return null
}
