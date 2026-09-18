import { useRef, useState, type ChangeEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Card, EmptyState, ErrorMessage, Notice } from '../../../components/ui'
import { AppError } from '../../../lib/errors'
import { serviceKeys } from '../api'
import { compressPhoto } from '../photoCompress'
import { PHOTO_QUOTA, SIGNED_URL_SECONDS, listPhotos, signPhotoUrls, uploadTicketPhoto, type UploadPhase } from '../photoUpload'

const PHASES: Record<UploadPhase, { label: string; step: number }> = {
  compress: { label: 'Mengecilkan foto…', step: 1 },
  prepare: { label: 'Menyiapkan tempat foto…', step: 2 },
  upload: { label: 'Mengunggah foto…', step: 3 },
  finalize: { label: 'Menyimpan foto…', step: 4 },
}

/**
 * Foto kondisi alat (maks. 5). Kegagalan foto tidak memengaruhi tiket; pengguna
 * cukup mencoba lagi. Foto dibuka lewat tautan sementara (5 menit) yang diperbarui otomatis.
 */
export function TicketPhotos({ ticketId, canUpload, highlight }: { ticketId: string; canUpload: boolean; highlight?: boolean }) {
  const queryClient = useQueryClient()
  const inputRef = useRef<HTMLInputElement>(null)
  const [phase, setPhase] = useState<UploadPhase | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  const photos = useQuery({ queryKey: serviceKeys.photos(ticketId), queryFn: () => listPhotos(ticketId) })
  const items = photos.data ?? []
  const urls = useQuery({
    queryKey: [...serviceKeys.photos(ticketId), 'urls', items.map(i => i.id).join(',')],
    queryFn: () => signPhotoUrls(items),
    enabled: items.length > 0,
    // Perbarui tautan sebelum kedaluwarsa.
    refetchInterval: (SIGNED_URL_SECONDS - 60) * 1000,
  })
  const full = items.length >= PHOTO_QUOTA

  async function onPick(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file) return
    setError(null)
    setDone(false)
    try {
      setPhase('compress')
      const blob = await compressPhoto(file)
      await uploadTicketPhoto(ticketId, blob, setPhase)
      setDone(true)
    } catch (err) {
      // uploadTicketPhoto selalu melempar AppError; compressPhoto melempar Error berkalimat awam.
      setError(err instanceof AppError ? err.display : err instanceof Error ? err.message : 'Foto gagal diproses.')
    } finally {
      setPhase(null)
      await queryClient.invalidateQueries({ queryKey: serviceKeys.photos(ticketId) })
    }
  }

  return (
    <Card title={`Foto kondisi alat (${items.length}/${PHOTO_QUOTA})`}>
      {highlight && canUpload && items.length === 0 && (
        <Notice tone="info">Tiket tersimpan. Tambahkan foto kondisi alat sekarang agar jelas saat serah terima.</Notice>
      )}
      {photos.isError && <ErrorMessage error={photos.error} />}
      {photos.isSuccess && items.length === 0 && <EmptyState>Belum ada foto.</EmptyState>}
      {items.length > 0 && (
        <ul className="srv-photo-grid">
          {items.map(item => {
            const url = urls.data?.[item.id]
            return (
              <li key={item.id}>
                {url
                  ? <a href={url} target="_blank" rel="noreferrer"><img src={url} alt="Foto kondisi alat" loading="lazy" /></a>
                  : <span className="srv-muted">{urls.isError ? 'Foto tidak dapat dibuka' : 'Memuat…'}</span>}
              </li>
            )
          })}
        </ul>
      )}
      {phase && (
        <div role="status" className="srv-progress">
          <span>{PHASES[phase].label}</span>
          <progress max={4} value={PHASES[phase].step} />
        </div>
      )}
      {error && <ErrorMessage error={error} />}
      {done && !phase && <Notice tone="success">Foto tersimpan.</Notice>}
      {canUpload && (
        <>
          <input ref={inputRef} type="file" accept="image/jpeg,image/png,image/webp" capture="environment"
            className="srv-visually-hidden" tabIndex={-1} aria-hidden="true" onChange={event => void onPick(event)} />
          <button type="button" className="ui-button ui-button-secondary" disabled={Boolean(phase) || full}
            onClick={() => inputRef.current?.click()}>
            {full ? 'Sudah 5 foto (maksimal)' : phase ? 'Sedang mengunggah…' : '+ Ambil / pilih foto'}
          </button>
        </>
      )}
    </Card>
  )
}
