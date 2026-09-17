import { useEffect, useState } from 'react'

/**
 * Deteksi status koneksi secara real-time.
 * Menampilkan pesan ramah (AT-28) saat internet terputus,
 * bukan error teknis yang menakutkan pengguna non-teknis.
 */
export function useOnlineStatus(): boolean {
  const [online, setOnline] = useState(() => {
    if (typeof navigator === 'undefined') return true
    return navigator.onLine
  })

  useEffect(() => {
    const onUp = () => setOnline(true)
    const onDown = () => setOnline(false)
    window.addEventListener('online', onUp)
    window.addEventListener('offline', onDown)
    return () => {
      window.removeEventListener('online', onUp)
      window.removeEventListener('offline', onDown)
    }
  }, [])

  return online
}

/**
 * Pesan ramah untuk pengguna non-teknis tentang gangguan koneksi.
 */
export const OFFLINE_MESSAGES = {
  banner: 'Internet sedang terputus. Data lokal tersimpan, tidak ada transaksi baru yang masuk.',
  finalize: 'Pembayaran tidak dapat dilakukan tanpa koneksi internet. Coba lagi saat jaringan pulih.',
  draftSave: 'Draf tersimpan di perangkat ini. Anda bisa melanjutkan saat koneksi kembali.',
  draftLoad: 'Koneksi pulih. Draf lokal siap digunakan.',
} as const

/**
 * Deteksi apakah error disebabkan oleh koneksi terputus.
 */
export function isNetworkError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err)
  return /Failed to fetch|NetworkError|Network request failed|ERR_NETWORK|Load failed|ECONNREFUSED|ERR_CONNECTION/i.test(msg)
}
