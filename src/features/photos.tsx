import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

type Attachment = { id: string; object_key: string; mime: string; state: string; created_at: string }

const MAX_BYTES = 1024 * 1024
const ALLOWED = ['image/jpeg', 'image/png', 'image/webp']
const MAX_PER_TICKET = 5

/**
 * Upload foto privat untuk tiket servis.
 * Tiga fase agar kegagalan foto tidak menghapus tiket:
 *  - siapkan slot (prepare_attachment_v1)
 *  - unggah objek ke Storage privat
 *  - finalisasi metadata (finalize_attachment_v1)
 * Foto lama dibaca via signed URL berumur pendek.
 */
export function TicketPhotos({ ticketId }: { ticketId: string }) {
  const [items, setItems] = useState<Attachment[]>([])
  const [urls, setUrls] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)

  const load = useCallback(async () => {
    if (!supabase) return
    const { data } = await supabase.rpc('list_attachments_v1', { p_input: { ticket_id: ticketId } })
    setItems((data as Attachment[]) ?? [])
  }, [ticketId])

  useEffect(() => { void load() }, [load])

  // Ambil signed URL berumur pendek untuk foto yang sudah tersimpan
  useEffect(() => {
    async function sign() {
      if (!supabase || items.length === 0) return
      const next: Record<string, string> = {}
      for (const it of items) {
        const { data } = await supabase.storage
          .from('ticket-photos')
          .createSignedUrl(it.object_key, 300)
        if (data?.signedUrl) next[it.id] = data.signedUrl
      }
      setUrls(next)
    }
    void sign()
  }, [items])

  async function upload(file: File) {
    if (!supabase) return
    setError('')

    if (!ALLOWED.includes(file.type)) {
      setError('Foto harus berformat JPG, PNG, atau WebP.')
      return
    }
    if (file.size > MAX_BYTES) {
      setError('Ukuran foto maksimal 1 MB. Kompres dulu atau pilih foto lain.')
      return
    }
    if (items.length >= MAX_PER_TICKET) {
      setError(`Maksimal ${MAX_PER_TICKET} foto per tiket.`)
      return
    }

    setBusy(true)
    try {
      // 1. Siapkan slot
      const { data: prep, error: prepErr } = await supabase.rpc('prepare_attachment_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          ticket_id: ticketId,
          mime: file.type,
          byte_size: file.size,
        },
      })
      if (prepErr) throw new Error(prepErr.message)
      const slot = prep as { ok?: boolean; entity_id?: string; object_key?: string }
      if (!slot?.ok || !slot.object_key || !slot.entity_id) {
        throw new Error('Tidak dapat menyiapkan slot foto.')
      }

      // 2. Unggah objek
      const { error: upErr } = await supabase.storage
        .from('ticket-photos')
        .upload(slot.object_key, file, { contentType: file.type, upsert: false })
      if (upErr) throw new Error(`Unggah foto gagal: ${upErr.message}`)

      // 3. Finalisasi
      const { error: finErr } = await supabase.rpc('finalize_attachment_v1', {
        p_input: { operation_id: crypto.randomUUID(), attachment_id: slot.entity_id },
      })
      if (finErr) throw new Error(finErr.message)

      await load()
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal mengunggah foto.')
    } finally {
      setBusy(false)
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (file) void upload(file)
  }

  return (
    <div className="ticket-photos">
      <div className="ticket-photos-head">
        <h4>Foto Kondisi ({items.length}/{MAX_PER_TICKET})</h4>
        <button
          className="ghost small"
          onClick={() => inputRef.current?.click()}
          disabled={busy || items.length >= MAX_PER_TICKET}
        >
          {busy ? 'Mengunggah…' : '+ Tambah Foto'}
        </button>
      </div>

      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        onChange={onPick}
        style={{ display: 'none' }}
        aria-label="Pilih foto"
      />

      {error && <div className="error" role="alert">{error}</div>}

      {items.length === 0 && !busy && (
        <p className="empty">Belum ada foto. Foto kondisi alat membantu saat serah terima.</p>
      )}

      <div className="photo-grid">
        {items.map(it => (
          <a key={it.id} href={urls[it.id] || '#'} target="_blank" rel="noreferrer" className="photo-thumb">
            {urls[it.id]
              ? <img src={urls[it.id]} alt="Foto kondisi alat" />
              : <span className="photo-loading">Memuat…</span>}
          </a>
        ))}
      </div>
    </div>
  )
}
