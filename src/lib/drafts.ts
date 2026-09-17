import Dexie, { type Table } from 'dexie'

export type DraftItem = {
  product_unit_id: string
  qty: string
  discount_mode?: 'percent' | 'amount'
  discount_value?: string
}

export type Draft = {
  id?: number
  user_id: string
  device_id: string
  label: string
  created_at: string
  updated_at: string
  cart: DraftItem[]
  payment_method: string
  customer_id?: string
  status: 'draft' | 'pending' | 'unknown'
}

class DraftDatabase extends Dexie {
  drafts!: Table<Draft, number>

  constructor() {
    super('elektropos-drafts')
    this.version(1).stores({
      drafts: '++id, user_id, device_id, updated_at'
    })
  }
}

const db = new DraftDatabase()

export async function saveDraft(
  userId: string,
  deviceId: string,
  draft: Omit<Draft, 'id' | 'user_id' | 'device_id'>
): Promise<number> {
  try {
    const existing = await db.drafts
      .where('user_id')
      .equals(userId)
      .and(d => d.device_id === deviceId)
      .first()

    if (existing?.id) {
      await db.drafts.update(existing.id, {
        ...draft,
        updated_at: new Date().toISOString(),
        status: draft.status || 'draft'
      })
      return existing.id
    } else {
      return await db.drafts.add({
        ...draft,
        user_id: userId,
        device_id: deviceId,
        updated_at: new Date().toISOString()
      } as Draft)
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (msg.includes('QuotaExceededError') || msg.includes('quota') || msg.includes('exceeded') || msg.includes('full')) {
      throw new Error('Penyimpanan perangkat penuh. Hapus beberapa draf lama untuk membebaskan ruang.')
    }
    throw new Error('Gagal menyimpan draf ke perangkat.')
  }
}

export async function loadDrafts(userId: string, deviceId: string): Promise<Draft[]> {
  try {
    return await db.drafts
      .where('user_id')
      .equals(userId)
      .and(d => d.device_id === deviceId)
      .reverse()
      .sortBy('updated_at')
  } catch {
    return []
  }
}

export async function deleteDraft(id: number): Promise<void> {
  await db.drafts.delete(id)
}

export async function clearUserDrafts(userId: string): Promise<void> {
  await db.drafts.where('user_id').equals(userId).delete()
}

export function getDeviceId(): string {
  const stored = localStorage.getItem('elektropos-device-id')
  if (stored) return stored
  const newId = crypto.randomUUID()
  localStorage.setItem('elektropos-device-id', newId)
  return newId
}
