import { useCallback, useEffect, useRef, useState } from 'react'
import { createHidState, feedHidKey, normalizeBarcode } from '../lib/scanner'

/**
 * Scanner HID (scanner fisik) menempel HANYA pada satu elemen input.
 * Tidak mencegat pengetikan kolom lain.
 */
export function useHidInputScanner(
  inputRef: React.RefObject<HTMLInputElement | null>,
  onScan: (code: string) => void,
  enabled = true,
) {
  const stateRef = useRef(createHidState())

  useEffect(() => {
    const el = inputRef.current
    if (!el || !enabled) return

    const onKeyDown = (event: KeyboardEvent) => {
      const code = feedHidKey(stateRef.current, event.key, Date.now())
      if (code) {
        event.preventDefault()
        onScan(code)
      }
    }
    const onBlur = () => { stateRef.current = createHidState() }

    el.addEventListener('keydown', onKeyDown)
    el.addEventListener('blur', onBlur)
    return () => {
      el.removeEventListener('keydown', onKeyDown)
      el.removeEventListener('blur', onBlur)
    }
  }, [inputRef, onScan, enabled])
}

export type CameraState = 'idle' | 'starting' | 'scanning' | 'unsupported' | 'denied' | 'error'
export type VideoDevice = { id: string; label: string }

type ZxingResult = { getText: () => string }
type ZxingReader = {
  decodeFromCanvas: (canvas: HTMLCanvasElement) => ZxingResult
}

/** Lebar maksimum frame yang diproses. */
export const MAX_PROCESS_WIDTH = 1280
/** Jeda antar percobaan decode (ms). */
export const SCAN_INTERVAL_MS = 100

/** Bunyi bip singkat saat barcode terbaca, tanpa file audio eksternal. */
function playBeep() {
  try {
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()
    osc.type = 'square'
    osc.frequency.value = 1400
    gain.gain.value = 0.08
    osc.connect(gain)
    gain.connect(ctx.destination)
    osc.start()
    osc.stop(ctx.currentTime + 0.12)
    setTimeout(() => { void ctx.close() }, 400)
  } catch {
    // audio diblokir browser; abaikan (indikator visual tetap tampil)
  }
}

/**
 * Kamera barcode. Kamera langsung menyala saat komponen aktif (tanpa klik kedua),
 * mencoba 4 orientasi tiap frame, dan membunyikan bip saat berhasil.
 */
export function useCameraScanner(onScan: (code: string) => void) {
  const [state, setState] = useState<CameraState>('idle')
  const [error, setError] = useState('')
  const [devices, setDevices] = useState<VideoDevice[]>([])
  const [deviceId, setDeviceId] = useState<string>('')
  const [lastDetected, setLastDetected] = useState('')
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const timerRef = useRef<number | null>(null)
  const activeRef = useRef(false)
  const lastRef = useRef<{ code: string; at: number } | null>(null)
  const onScanRef = useRef(onScan)
  onScanRef.current = onScan

  const refreshDevices = useCallback(async () => {
    if (!navigator.mediaDevices?.enumerateDevices) return
    const all = await navigator.mediaDevices.enumerateDevices()
    const cams = all
      .filter(d => d.kind === 'videoinput')
      .map((d, i) => ({ id: d.deviceId, label: d.label || `Kamera ${i + 1}` }))
    setDevices(cams)
    if (cams.length > 0) setDeviceId(prev => prev || cams[0].id)
  }, [])

  useEffect(() => {
    void refreshDevices()
    const md = navigator.mediaDevices
    if (!md?.addEventListener) return
    const onChange = () => { void refreshDevices() }
    md.addEventListener('devicechange', onChange)
    return () => md.removeEventListener('devicechange', onChange)
  }, [refreshDevices])

  const stop = useCallback(() => {
    activeRef.current = false
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
    streamRef.current?.getTracks().forEach(t => t.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
    setState(s => (s === 'scanning' || s === 'starting' ? 'idle' : s))
  }, [])

  const start = useCallback(async () => {
    if (activeRef.current) return
    if (typeof navigator === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      setState('unsupported')
      setError('Perangkat ini tidak menyediakan akses kamera. Ketik kode secara manual.')
      return
    }
    setState('starting')
    setError('')
    try {
      const { BrowserMultiFormatReader } = await import('@zxing/browser')
      const { BarcodeFormat, DecodeHintType } = await import('@zxing/library')

      const hints = new Map<number, unknown>()
      hints.set(DecodeHintType.POSSIBLE_FORMATS, [
        BarcodeFormat.EAN_13, BarcodeFormat.EAN_8, BarcodeFormat.UPC_A, BarcodeFormat.UPC_E,
        BarcodeFormat.CODE_128, BarcodeFormat.CODE_39, BarcodeFormat.ITF, BarcodeFormat.CODE_93,
        BarcodeFormat.QR_CODE, BarcodeFormat.DATA_MATRIX,
      ])
      hints.set(DecodeHintType.TRY_HARDER, true)

      const reader = new BrowserMultiFormatReader(hints) as unknown as ZxingReader
      const video = videoRef.current
      if (!video) throw new Error('Elemen video belum siap')

      const stream = await navigator.mediaDevices.getUserMedia({
        video: {
          deviceId: deviceId ? { exact: deviceId } : undefined,
          facingMode: deviceId ? undefined : { ideal: 'environment' },
          width: { ideal: 1920 },
          height: { ideal: 1080 },
        },
        audio: false,
      })
      streamRef.current = stream
      video.srcObject = stream
      video.setAttribute('playsinline', 'true')
      await video.play()

      const frame = document.createElement('canvas')
      const fctx = frame.getContext('2d', { willReadFrequently: true })
      const rotated = document.createElement('canvas')
      const rctx = rotated.getContext('2d', { willReadFrequently: true })
      if (!fctx || !rctx) throw new Error('Canvas 2D tidak tersedia')

      const tryDecode = (source: HTMLCanvasElement): string | null => {
        try {
          return normalizeBarcode(reader.decodeFromCanvas(source).getText())
        } catch {
          return null
        }
      }

      const rotateInto = (source: HTMLCanvasElement, degrees: number) => {
        const rad = (degrees * Math.PI) / 180
        const swap = degrees === 90 || degrees === 270
        rotated.width = swap ? source.height : source.width
        rotated.height = swap ? source.width : source.height
        rctx.save()
        rctx.translate(rotated.width / 2, rotated.height / 2)
        rctx.rotate(rad)
        rctx.drawImage(source, -source.width / 2, -source.height / 2)
        rctx.restore()
        return rotated
      }

      const emit = (code: string) => {
        if (!code) return
        const now = Date.now()
        setLastDetected(code)
        setError('')
        const last = lastRef.current
        if (!last || last.code !== code || now - last.at > 1500) {
          lastRef.current = { code, at: now }
          playBeep()
          onScanRef.current(code)
        }
      }

      const loop = () => {
        if (!activeRef.current) return
        const v = videoRef.current
        if (!v || v.readyState < 2 || v.videoWidth === 0) {
          timerRef.current = window.setTimeout(loop, 200)
          return
        }
        try {
          const scale = Math.min(1, MAX_PROCESS_WIDTH / v.videoWidth)
          frame.width = Math.round(v.videoWidth * scale)
          frame.height = Math.round(v.videoHeight * scale)
          fctx.imageSmoothingEnabled = true
          fctx.imageSmoothingQuality = 'high'
          fctx.drawImage(v, 0, 0, frame.width, frame.height)

          let code = tryDecode(frame)
          if (!code) code = tryDecode(rotateInto(frame, 90))
          if (!code) code = tryDecode(rotateInto(frame, 270))
          if (!code) code = tryDecode(rotateInto(frame, 180))

          if (code) emit(code)
        } catch {
          // frame gagal diproses; lanjut
        }
        timerRef.current = window.setTimeout(loop, SCAN_INTERVAL_MS)
      }

      activeRef.current = true
      setState('scanning')
      loop()
    } catch (e) {
      const err = e as { name?: string; message?: string }
      streamRef.current?.getTracks().forEach(t => t.stop())
      streamRef.current = null
      activeRef.current = false
      if (err.name === 'NotAllowedError' || err.name === 'SecurityError') {
        setState('denied')
        setError('Kamera tidak diizinkan. Klik ikon kunci di alamat browser, pilih "Izinkan kamera", lalu muat ulang halaman.')
      } else if (err.name === 'NotFoundError' || err.name === 'OverconstrainedError') {
        setState('unsupported')
        setError('Kamera tidak ditemukan pada perangkat ini.')
      } else {
        setState('error')
        setError(err.message || 'Kamera tidak dapat dimulai.')
      }
    }
  }, [deviceId])

  useEffect(() => () => { stop() }, [stop])

  return { state, error, videoRef, start, stop, devices, deviceId, setDeviceId, lastDetected }
}
