import { useEffect, useRef, useState } from 'react'
import { toAppError, type AppError } from '../../lib/errors'
import { previewSale } from './api'
import type { SaleInput, SalePreview } from './types'

export const PREVIEW_DELAY_MS = 350

export type PreviewState =
  | { status: 'empty' }
  | { status: 'loading'; last: SalePreview | null }
  | { status: 'ready'; data: SalePreview }
  | { status: 'error'; error: AppError }

type PreviewResult = { key: string; data?: SalePreview; error?: AppError }

/**
 * Total dari server (S01). Pratinjau dipanggil ulang setiap isi keranjang berubah
 * (dengan jeda). Status `ready` hanya bila hasil server cocok dengan isi saat ini;
 * selama itu belum terjadi, tombol Bayar harus menunggu.
 */
export function useSalePreview(input: SaleInput | null, onError?: (error: AppError) => void) {
  const key = input ? JSON.stringify(input) : null
  const [result, setResult] = useState<PreviewResult | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [lastGood, setLastGood] = useState<SalePreview | null>(null)
  const onErrorRef = useRef(onError)
  useEffect(() => { onErrorRef.current = onError }, [onError])

  useEffect(() => {
    if (!key) return
    let alive = true
    const timer = setTimeout(() => {
      previewSale(JSON.parse(key) as SaleInput)
        .then(data => {
          if (!alive) return
          setLastGood(data)
          setResult({ key, data })
        })
        .catch((err: unknown) => {
          if (!alive) return
          const error = toAppError(err as Error)
          setResult({ key, error })
          onErrorRef.current?.(error)
        })
    }, PREVIEW_DELAY_MS)
    return () => {
      alive = false
      clearTimeout(timer)
    }
  }, [key, attempt])

  let state: PreviewState
  if (!key) state = { status: 'empty' }
  else if (result?.key !== key) state = { status: 'loading', last: lastGood }
  else if (result.error) state = { status: 'error', error: result.error }
  else state = { status: 'ready', data: result.data as SalePreview }

  const retry = () => {
    setResult(null)
    setAttempt(a => a + 1)
  }

  return { state, key, retry }
}
