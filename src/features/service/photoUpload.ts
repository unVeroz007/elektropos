import { commandRpc, newOperationId, readRpc } from '../../lib/rpc'
import { AppError, toAppError } from '../../lib/errors'
import { supabase } from '../../lib/supabase'
import { OUTPUT_MIME } from './photoCompress'

/**
 * Unggah foto tiket tiga tahap (kontrak foto): siapkan slot → unggah objek →
 * finalisasi. Slot berlaku 30 menit; bila kedaluwarsa/ditolak saat unggah,
 * dibuat slot baru SATU kali secara otomatis. Kegagalan foto tidak menyentuh tiket.
 */

export const PHOTO_BUCKET = 'ticket-photos'
export const PHOTO_QUOTA = 5
export const SIGNED_URL_SECONDS = 300
const SLOT_SAFETY_MS = 60_000

export type UploadPhase = 'compress' | 'prepare' | 'upload' | 'finalize'

type Slot = { entity_id: string; object_key: string; upload_expires_at: string; bucket: string }

export type Attachment = { id: string; object_key: string; mime: string; byte_size: number; created_at: string }

function storage() {
  if (!supabase) throw new AppError('NOT_CONFIGURED', 'Koneksi aplikasi belum disetel.', 'unknown')
  return supabase.storage
}

class RetryableSlotError extends Error {}

async function attempt(ticketId: string, blob: Blob, onPhase: (phase: UploadPhase) => void): Promise<void> {
  onPhase('prepare')
  const slot = await commandRpc<Slot>('prepare_attachment_v1', {
    operation_id: newOperationId(), ticket_id: ticketId, mime: OUTPUT_MIME, byte_size: blob.size,
  })
  if (Date.parse(slot.upload_expires_at) - Date.now() < SLOT_SAFETY_MS) {
    throw new RetryableSlotError('Slot foto sudah kedaluwarsa.')
  }

  onPhase('upload')
  const { error } = await storage().from(slot.bucket || PHOTO_BUCKET)
    .upload(slot.object_key, blob, { contentType: OUTPUT_MIME, upsert: false })
  if (error) {
    const appError = toAppError(error)
    if (appError.kind === 'network') throw appError
    // Ditolak policy (slot kedaluwarsa/berpindah akun): coba slot baru.
    throw new RetryableSlotError('Unggahan ditolak.')
  }

  onPhase('finalize')
  try {
    await commandRpc('finalize_attachment_v1', { operation_id: newOperationId(), attachment_id: slot.entity_id })
  } catch (err) {
    const appError = toAppError(err as Error)
    if (appError.code === 'ALREADY_FINALIZED') return
    if (appError.code === 'ATTACHMENT_INVALID') throw new RetryableSlotError(appError.message)
    throw appError
  }
}

/** Jalankan unggah dengan satu kali slot baru bila slot pertama gagal. */
export async function uploadTicketPhoto(ticketId: string, blob: Blob, onPhase: (phase: UploadPhase) => void): Promise<void> {
  try {
    await attempt(ticketId, blob, onPhase)
  } catch (err) {
    if (!(err instanceof RetryableSlotError)) throw toAppError(err as Error)
    try {
      await attempt(ticketId, blob, onPhase)
    } catch (second) {
      if (second instanceof RetryableSlotError) {
        throw new AppError('ATTACHMENT_INVALID', 'Foto belum tersimpan.', 'business',
          'Tiket tetap aman. Coba unggah lagi beberapa saat kemudian.')
      }
      throw toAppError(second as Error)
    }
  }
}

export const listPhotos = (ticketId: string) => readRpc<Attachment[]>('list_attachments_v1', { ticket_id: ticketId })

/** Signed URL berumur pendek per foto; foto yang gagal ditandatangani dilewati. */
export async function signPhotoUrls(items: Attachment[]): Promise<Record<string, string>> {
  const urls: Record<string, string> = {}
  for (const item of items) {
    const { data } = await storage().from(PHOTO_BUCKET).createSignedUrl(item.object_key, SIGNED_URL_SECONDS)
    if (data?.signedUrl) urls[item.id] = data.signedUrl
  }
  return urls
}
