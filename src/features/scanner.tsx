import { useEffect, useId, useRef, useState, type FormEvent } from 'react'
import { normalizeBarcode } from '../lib/scanner'
import { useCameraScanner, useHidInputScanner } from '../lib/useScanner'
import '../components/ui.css'
import './scanner.css'

type Props = {
  onScan: (code: string) => void
  title?: string
  description?: string
  /** Buka kamera otomatis saat panel tampil (default false). */
  autoStart?: boolean
}

/**
 * Pemindai barcode untuk pengguna non-teknis. Dipakai kasir, barang masuk dan daftar barcode.
 *  - Scanner fisik: klik kolom kode (atau tombol "Siap scan"), lalu scan. Hanya kolom ini yang
 *    mendengarkan; keyboard di kolom lain tidak dicegat.
 *  - Kamera: satu tombol langsung menyala, bip + kartu hijau saat terbaca, fokus ulang/manual.
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
  const [ready, setReady] = useState(false)
  const inputRef = useRef<HTMLInputElement | null>(null)
  const inputId = useId()

  const handleCode = (code: string) => {
    setFlash(code)
    onScan(code)
  }

  useHidInputScanner(inputRef, code => {
    setManual('')
    handleCode(code)
  })
  const camera = useCameraScanner(handleCode)
  const { start, stop } = camera

  useEffect(() => {
    if (open) void start()
    else stop()
  }, [open, start, stop])

  useEffect(() => {
    if (!flash) return
    const timer = setTimeout(() => setFlash(null), 2500)
    return () => clearTimeout(timer)
  }, [flash])

  function submitManual(event: FormEvent) {
    event.preventDefault()
    const code = normalizeBarcode(manual)
    if (code) handleCode(code)
    setManual('')
    inputRef.current?.focus()
  }

  const scanning = camera.state === 'scanning'
  const canRefocus = camera.focus.modes.includes('continuous') || camera.focus.modes.includes('single-shot')

  return (
    <section className="sc-panel" aria-label={title}>
      <div className="sc-head">
        <div>
          <h2 className="sc-title">{title}</h2>
          <p className="sc-desc">{description}</p>
        </div>
        <button type="button" className={`ui-button ${open ? 'ui-button-secondary' : 'ui-button-primary'}`}
          onClick={() => setOpen(v => !v)} aria-pressed={open}>
          {open ? 'Tutup kamera' : 'Scan dengan kamera'}
        </button>
      </div>

      {flash && (
        <div className="sc-flash" role="status">
          <span className="sc-flash-icon" aria-hidden="true">✓</span>
          <span>Terbaca: <strong>{flash}</strong></span>
        </div>
      )}

      {open && (
        <div className="sc-camera">
          <div className="sc-viewport">
            <video ref={camera.videoRef} muted playsInline className="sc-video" />
            <div className="sc-reticle" aria-hidden="true" />
            {scanning && <div className="sc-live">Kamera menyala</div>}
          </div>

          {camera.state === 'starting' && <p className="sc-note" role="status">Menyalakan kamera…</p>}
          {camera.error && <div className="ui-alert ui-alert-error" role="alert">{camera.error}</div>}

          {scanning && (
            <p className="sc-note">
              <strong>Dekatkan barcode ke kotak kuning.</strong> Jarak sekitar 10–20 cm, tahan sampai berbunyi bip.
            </p>
          )}

          {scanning && (canRefocus || camera.focus.distance) && (
            <div className="sc-focus">
              {canRefocus && (
                <button type="button" className="ui-button ui-button-secondary" onClick={() => { void camera.refocus() }}>
                  Fokuskan ulang
                </button>
              )}
              {camera.focus.distance && (
                <label className="sc-focus-range">
                  <span>Atur fokus manual (dekat ↔ jauh)</span>
                  <input type="range" min={0} max={1} step={0.05} defaultValue={0.3}
                    onChange={e => { void camera.setManualFocus(Number(e.target.value)) }} />
                </label>
              )}
            </div>
          )}

          {camera.devices.length > 1 && (
            <label className="sc-device">
              <span>Pilih kamera</span>
              <select value={camera.deviceId} onChange={e => camera.setDeviceId(e.target.value)} disabled={scanning}>
                {camera.devices.map(d => <option key={d.id} value={d.id}>{d.label}</option>)}
              </select>
            </label>
          )}
        </div>
      )}

      <form onSubmit={submitManual} className="sc-manual">
        <label className="sc-manual-label" htmlFor={inputId}>
          Kode barcode {ready ? <span className="sc-ready">(siap menerima scanner)</span> : null}
        </label>
        <div className="sc-manual-row">
          <input
            id={inputId}
            ref={inputRef}
            value={manual}
            onChange={e => setManual(e.target.value)}
            onFocus={() => setReady(true)}
            onBlur={() => setReady(false)}
            placeholder="Klik di sini lalu scan, atau ketik kode"
            inputMode="text"
            autoComplete="off"
            spellCheck={false}
          />
          <button type="submit" className="ui-button ui-button-secondary">Tambah</button>
        </div>
      </form>
      {!ready && (
        <button type="button" className="sc-ready-button" onClick={() => inputRef.current?.focus()}>
          Punya scanner fisik? Tekan di sini dulu, lalu scan barang.
        </button>
      )}
    </section>
  )
}
