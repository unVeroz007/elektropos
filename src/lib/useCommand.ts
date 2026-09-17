import { useCallback, useRef, useState } from 'react'
import { commandRpc, newOperationId } from './rpc'
import { AppError, toAppError } from './errors'

type CommandState<T> = {
  busy: boolean
  error: AppError | null
  result: T | null
}

/**
 * Perintah tulis idempoten untuk satu aksi pengguna (mis. "Bayar").
 *
 * operation_id dipertahankan selama hasil belum diketahui (koneksi putus), sehingga
 * menekan tombol lagi tidak membuat transaksi ganda. operation_id baru dibuat setelah
 * sukses, setelah penolakan bisnis yang pasti, atau saat `reset()` (isi berubah).
 */
export function useCommand<T, P extends Record<string, unknown>>(rpcName: string) {
  const operationId = useRef<string | null>(null)
  const [state, setState] = useState<CommandState<T>>({ busy: false, error: null, result: null })

  const run = useCallback(async (payload: P): Promise<T | null> => {
    operationId.current ??= newOperationId()
    setState(s => ({ ...s, busy: true, error: null }))
    try {
      const result = await commandRpc<T>(rpcName, { ...payload, operation_id: operationId.current })
      operationId.current = null
      setState({ busy: false, error: null, result })
      return result
    } catch (err) {
      const appError = toAppError(err as Error)
      // Hasil belum diketahui: simpan operation_id untuk percobaan ulang yang aman.
      if (appError.kind !== 'network') operationId.current = null
      setState({ busy: false, error: appError, result: null })
      return null
    }
  }, [rpcName])

  /** Panggil saat isi transaksi berubah agar tidak memakai ulang operation_id lama. */
  const reset = useCallback(() => {
    operationId.current = null
    setState({ busy: false, error: null, result: null })
  }, [])

  return { ...state, run, reset, pendingOperationId: () => operationId.current }
}
