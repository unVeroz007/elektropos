import Dexie, { type Table } from 'dexie'

/**
 * Draf transaksi lokal (FR-POS-01, FR-RES-01).
 *
 * - Dipisah per akun dan perangkat; akun lain di browser yang sama tidak melihatnya.
 * - Maksimal 5 draf aktif per akun+perangkat. Draf tertua TIDAK dihapus diam-diam.
 * - Draf tidak mereservasi stok. Isi keranjang disimpan apa adanya beserta
 *   `operation_id` pengiriman terakhir agar hasil yang belum diketahui dapat dicek ulang.
 */

export const DRAFT_SCHEMA_VERSION = 2
export const MAX_ACTIVE_DRAFTS = 5

export type DraftStatus = 'draft' | 'sending' | 'unknown' | 'failed'

export type Draft<TContent = unknown> = {
  id?: number
  schema_version: number
  user_id: string
  device_id: string
  label: string
  content: TContent
  status: DraftStatus
  /** operation_id pengiriman terakhir; dipakai ulang saat hasil belum diketahui. */
  operation_id?: string
  created_at: string
  updated_at: string
}

class DraftDatabase extends Dexie {
  drafts!: Table<Draft, number>

  constructor() {
    super('elektropos-drafts')
    this.version(1).stores({ drafts: '++id, user_id, device_id, updated_at' })
    // Versi 2: skema draf baru. Draf versi lama tidak kompatibel (format keranjang berubah) dan dibuang.
    this.version(2)
      .stores({ drafts: '++id, [user_id+device_id], updated_at' })
      .upgrade(tx => tx.table('drafts').clear())
  }
}

const db = new DraftDatabase()

export class DraftStorageError extends Error {}

function storageError(err: unknown): DraftStorageError {
  const name = err instanceof Error ? err.name : ''
  const message = err instanceof Error ? err.message : String(err)
  if (name === 'QuotaExceededError' || /quota/i.test(message)) {
    return new DraftStorageError('Penyimpanan perangkat penuh. Hapus draf lama lalu coba lagi.')
  }
  return new DraftStorageError('Draf tidak dapat disimpan di perangkat ini.')
}

export async function listDrafts<T>(userId: string, deviceId: string): Promise<Draft<T>[]> {
  try {
    const rows = await db.drafts.where('[user_id+device_id]').equals([userId, deviceId]).toArray()
    return (rows as Draft<T>[])
      .filter(d => d.schema_version === DRAFT_SCHEMA_VERSION)
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at))
  } catch (err) {
    throw storageError(err)
  }
}

type DraftInput<T> = Pick<Draft<T>, 'label' | 'content' | 'status' | 'operation_id'>

/** Simpan draf baru atau perbarui draf `id`. Menolak draf ke-6 alih-alih menghapus yang lama. */
export async function saveDraft<T>(userId: string, deviceId: string, input: DraftInput<T>, id?: number): Promise<number> {
  const now = new Date().toISOString()
  try {
    if (id !== undefined) {
      const existing = await db.drafts.get(id)
      if (existing && existing.user_id === userId && existing.device_id === deviceId) {
        await db.drafts.update(id, { ...input, updated_at: now })
        return id
      }
    }
    const count = await db.drafts.where('[user_id+device_id]').equals([userId, deviceId]).count()
    if (count >= MAX_ACTIVE_DRAFTS) {
      throw new DraftStorageError(`Sudah ada ${MAX_ACTIVE_DRAFTS} transaksi ditahan. Lanjutkan atau hapus salah satu dulu.`)
    }
    return await db.drafts.add({
      ...input,
      schema_version: DRAFT_SCHEMA_VERSION,
      user_id: userId,
      device_id: deviceId,
      created_at: now,
      updated_at: now,
    })
  } catch (err) {
    throw err instanceof DraftStorageError ? err : storageError(err)
  }
}

export async function deleteDraft(userId: string, id: number): Promise<void> {
  try {
    const existing = await db.drafts.get(id)
    if (existing?.user_id === userId) await db.drafts.delete(id)
  } catch (err) {
    throw storageError(err)
  }
}

const DEVICE_KEY = 'elektropos-device-id'

export function getDeviceId(): string {
  try {
    const stored = localStorage.getItem(DEVICE_KEY)
    if (stored) return stored
    const created = crypto.randomUUID()
    localStorage.setItem(DEVICE_KEY, created)
    return created
  } catch {
    // Penyimpanan diblokir (mode privat): draf tetap bekerja selama tab terbuka.
    return 'ephemeral-device'
  }
}
