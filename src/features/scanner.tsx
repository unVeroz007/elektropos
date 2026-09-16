import { useEffect, useRef, useState } from 'react'
import { useCameraScanner, useHidInputScanner } from '../lib/useScanner'

type Props = {
  onScan: (code: string) => void
  title?: string
  description?: string
  /** Buka kamera otomatis saat panel tampil (default true). */
  autoStart?: boolean
}

/**
 * Pemindai barcode ramah pengguna non-teknis:
 *  - Satu tombol: "Scan dengan Kamera" langsung menyalakan kamera (tanpa klik kedua).
 *  - Bip + kartu hijau besar saat berhasil.
 *  - Kolom ketik manual selalu tersedia sebagai cadangan.
 */
export function BarcodeScanner({
  onScan,
  title = 'Scan barcode',
  description = 'Arahkan kamera ke barcode.',
  autoStart = false,
}: Props) {
  const [open, setOpen] = useState(autoStart)
  const [manual, setManual] = useState('')
  const [flash, setFlash] = useState<string | null>(null)
  const hidRef = useRef<HTMLInputElement | null>(null)

  const handleCode = (code: string) => {
    setFlash(code)
    onScan(code)
  }

  useHidInputScanner(hidRef, code => { setManual(code); handleCode(code) })
  const camera = useCameraScanner(handleCode)

  // Kamera langsung menyala saat panel dibuka (tanpa klik kedua)
  useEffect(() => {
    if (!open) return
    if (camera.state === 'idle' && !camera.error) {
      void camera.start()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  // Sembunyikan kartu hijau setelah 2,5 detik
  useEffect(() => {
    if (!flash) return
    const t = setTimeout(() => setFlash(null), 2500)
    return () => clearTimeout(t)
  }, [flash])

  // Matikan kamera saat panel ditutup
  useEffect(() => {
    if (!open && camera.state !== 'idle') camera.stop()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  function submitManual(e: React.FormEvent) {
    e.preventDefault()
    const code = manual.trim()
    if (code) handleCode(code)
    setManual('')
    hidRef.current?.focus()
  }

  const scanning = camera.state === 'scanning'

  return (
    <div className="scanner-panel">
      <div className="scanner-head">
        <div>
          <strong>{title}</strong>
          <small>{description}</small>
        </div>
        <button
          className={open ? 'ghost' : 'primary'}
          onClick={() => setOpen(v => !v)}
        >
          {open ? 'Tutup kamera' : 'Scan dengan Kamera'}
        </button>
      </div>

      {flash && (
        <div className="scan-flash" role="status">
          <span className="scan-flash-icon">✓</span>
          <span className="scan-flash-text">Terbaca: <strong>{flash}</strong></span>
        </div>
      )}

      {open && (
        <div className="scanner-camera">
          <div className="scanner-viewport">
            <video ref={camera.videoRef} muted playsInline className="scanner-video" />
            <div className="scanner-reticle" aria-hidden="true" />
            {scanning && <div className="scanner-live">● Merekam — arahkan ke barcode</div>}
          </div>

          {camera.devices.length > 1 && (
            <label className="scanner-device">
              Kamera
              <select value={camera.deviceId} onChange={e => camera.setDeviceId(e.target.value)} disabled={scanning}>
                {camera.devices.map(d => <option key={d.id} value={d.id}>{d.label}</option>)}
              </select>
            </label>
          )}

          {camera.error && <div className="error" role="alert">{camera.error}</div>}

          {camera.state === 'starting' && <div className="notice">Menyalakan kamera…</div>}

          {scanning && (
            <div className="scanner-mega-hint">
              <strong>Dekatkan barcode ke dalam kotak kuning</strong>
              <span>Jarak sekitar 10–20 cm. Tahan sebentar sampai berbunyi bip.</span>
            </div>
          )}
        </div>
      )}

      <form onSubmit={submitManual} className="scanner-input">
        <input
          ref={hidRef}
          value={manual}
          onChange={e => setManual(e.target.value)}
          placeholder="Atau ketik kode di sini, lalu tekan Tambah"
          inputMode="text"
          autoComplete="off"
          aria-label="Kolom ketik barcode manual"
        />
        <button type="submit">Tambah</button>
      </form>

      <div className="scanner-hint">
        <small>
          Punya scanner fisik? Klik kolom di atas lalu scan — kode langsung masuk.
        </small>
      </div>
    </div>
  )
}
