import { supabase } from './supabase'
import { AppError, toAppError } from './errors'

/**
 * Pembungkus RPC Supabase.
 *
 * - `readRpc` untuk bacaan: error selalu dilempar sebagai AppError.
 * - `commandRpc` untuk perintah tulis idempoten: payload wajib membawa
 *   `operation_id`. Bila jaringan putus sehingga hasil tidak diketahui, status
 *   operasi diperiksa lewat `get_operation_v1` sebelum menyerah. Pemanggil yang
 *   mengulang WAJIB memakai operation_id yang sama (FR-POS-02, FR-RES-01).
 */

export const newOperationId = (): string => crypto.randomUUID()

function client() {
  if (!supabase) {
    throw new AppError('NOT_CONFIGURED', 'Koneksi aplikasi belum disetel.', 'unknown',
      'Salin .env.example ke .env lalu isi alamat dan kunci publik Supabase.')
  }
  return supabase
}

export async function readRpc<T>(name: string, input?: Record<string, unknown>): Promise<T> {
  const args = input === undefined ? undefined : { p_input: input }
  let response
  try {
    response = await client().rpc(name, args)
  } catch (err) {
    throw toAppError(err as Error)
  }
  if (response.error) throw toAppError(response.error)
  return response.data as T
}

export type CommandPayload = { operation_id: string } & Record<string, unknown>

export async function commandRpc<T>(name: string, payload: CommandPayload): Promise<T> {
  try {
    return await readRpc<T>(name, payload)
  } catch (err) {
    const appError = toAppError(err as Error)
    if (appError.kind !== 'network') throw appError
    const known = await findOperation<T>(name, payload.operation_id)
    if (known !== undefined) return known
    throw new AppError('UNKNOWN_RESULT', 'Hasil pengiriman belum diketahui karena koneksi terputus.', 'network',
      'Jangan membuat transaksi baru. Tekan tombol yang sama lagi saat koneksi pulih; sistem akan memeriksa agar tidak tercatat ganda.')
  }
}

/** Hasil operasi yang sudah tercatat di server, atau undefined bila belum/tidak dapat diperiksa. */
export async function findOperation<T>(command: string, operationId: string): Promise<T | undefined> {
  try {
    const status = await readRpc<{ found: boolean; result?: T }>('get_operation_v1', {
      command,
      operation_id: operationId,
    })
    return status.found ? status.result : undefined
  } catch {
    return undefined
  }
}
