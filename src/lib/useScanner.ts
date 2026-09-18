import { useCallback, useEffect, useRef, useState } from 'react'
import { createHidState, feedHidKey, normalizeBarcode } from './scanner'

/**
 * Scanner HID (scanner fisik) menempel HANYA pada satu elemen input.
 * Tidak mencegat pengetikan kolom lain maupun keyboard global.
 */
export function useHidInputScanner(
  inputRef: React.RefObject<HTMLInputElement | null>,
  onScan: (code: string) => void,
  enabled = true,
) {
  const stateRef = useRef(createHidState())
  const onScanRef = useRef(onScan)
  useEffect(() => { onScanRef.current = onScan }, [onScan])

  useEffect(() => {
    const el = inputRef.current
    if (!el || !enabled) return

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.isComposing) return
      const code = feedHidKey(stateRef.current, event.key, Date.now())
      if (code) {
        event.preventDefault()
        onScanRef.current(code)
      }
    }
    const onBlur = () => { stateRef.current = createHidState() }

    el.addEventListener('keydown', onKeyDown)
    el.addEventListener('blur', onBlur)
    return () => {
      el.removeEventListener('keydown', onKeyDown)
      el.removeEventListener('blur', onBlur)
    }
  }, [inputRef, enabled])
}

export type CameraState = 'idle' | 'starting' | 'scanning' | 'unsupported' | 'denied' | 'error'
export type VideoDevice = { id: string; label: string }

/** Kemampuan fokus kamera yang dilaporkan browser (tidak semua kamera mendukung). */
export type FocusSupport = {
  modes: string[]
  distance: { min: number; max: number; step: number } | null
}

type ZxingResult = { getText: () => string }
type ZxingReader = {
  decodeFromCanvas: (canvas: HTMLCanvasElement) => ZxingResult
}
type FocusCapabilities = {
  focusMode?: string[]
  focusDistance?: { min: number; max: number; step?: number }
}

/** Lebar maksimum frame yang diproses. */
export const MAX_PROCESS_WIDTH = 1280
/** Jeda antar percobaan decode (ms). */
export const SCAN_INTERVAL_MS = 100
/** Kode sama dihitung lagi hanya bila tidak terlihat selama jeda ini (ms). */
export const REPEAT_AFTER_ABSENT_MS = 1200

/**
 * Dedup kamera (S12): barcode yang terus terlihat hanya dihitung sekali. Kode sama
 * dihitung lagi setelah keluar dari bingkai minimal REPEAT_AFTER_ABSENT_MS.
 */
export function shouldEmitCameraCode(
  last: { code: string; seenAt: number } | null,
  code: string,
  now: number,
): boolean {
  return !(last !== null && last.code === code && now - last.seenAt < REPEAT_AFTER_ABSENT_MS)
}

/** Bunyi bip singkat saat barcode terbaca, tanpa file audio eksternal. */
function playBeep() {
  const Ctx = window.AudioContext
    ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
  if (!Ctx) return
  try {
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
  } catch (err) {
    // Audio diblokir kebijakan autoplay browser: indikator visual tetap tampil.
    void err
  }
}

function readFocusSupport(track: MediaStreamTrack | undefined): FocusSupport {
  const caps = (track?.getCapabilities?.() ?? {}) as FocusCapabilities
  const distance = caps.focusDistance
  return {
    modes: caps.focusMode ?? [],
    distance: distance && distance.max > distance.min
      ? { min: distance.min, max: distance.max, step: distance.step || (distance.max - distance.min) / 20 }
      : null,
  }
}

async function applyFocus(track: MediaStreamTrack | undefined, constraint: Record<string, unknown>): Promise<boolean> {
  if (!track?.applyConstraints) return false
  try {
    await track.applyConstraints({ advanced: [constraint] } as unknown as MediaTrackConstraints)
    return true
  } catch {
    // Kamera menolak pengaturan fokus: tetap memakai fokus bawaan.
    return false
  }
}

/**
 * Kamera barcode: mencoba 4 orientasi tiap frame, bip saat berhasil, dedup kode
 * yang terus terlihat, dan fokus otomatis/manual bila kamera mendukung.
 */
export function useCameraScanner(onScan: (code: string) => void) {
  const [state, setState] = useState<CameraState>('idle')
  const [error, setError] = useState('')
  const [devices, setDevices] = useState<VideoDevice[]>([])
  const [deviceId, setDeviceId] = useState<string>('')
  const [lastDetected, setLastDetected] = useState('')
  const [focus, setFocus] = useState<FocusSupport>({ modes: [], distance: null })
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const timerRef = useRef<number | null>(null)
  const activeRef = useRef(false)
  const lastRef = useRef<{ code: string; seenAt: number } | null>(null)
  // Dinaikkan setiap stop(); start() yang masih menunggu kamera membatalkan diri bila token berubah.
  const sessionRef = useRef(0)
  const onScanRef = useRef(onScan)
  useEffect(() => { onScanRef.current = onScan }, [onScan])

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
    sessionRef.current += 1
    activeRef.current = false
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
    streamRef.current?.getTracks().forEach(t => t.stop())
    streamRef.current = null
    if (videoRef.current) videoRef.current.srcObject = null
    setFocus({ modes: [], distance: null })
    setState(s => (s === 'scanning' || s === 'starting' ? 'idle' : s))
  }, [])

  /** Minta kamera memfokuskan ulang (mis. barcode buram karena terlalu dekat). */
  const refocus = useCallback(async () => {
    const track = streamRef.current?.getVideoTracks()[0]
    const modes = readFocusSupport(track).modes
    if (modes.includes('single-shot')) await applyFocus(track, { focusMode: 'single-shot' })
    if (modes.includes('continuous')) await applyFocus(track, { focusMode: 'continuous' })
  }, [])

  /** Fokus manual: 0 = paling dekat, 1 = paling jauh (dipetakan ke rentang kamera). */
  const setManualFocus = useCallback(async (fraction: number) => {
    const track = streamRef.current?.getVideoTracks()[0]
    const support = readFocusSupport(track)
    if (!support.distance) return
    const { min, max } = support.distance
    const value = min + (max - min) * Math.min(1, Math.max(0, fraction))
    await applyFocus(track, { focusMode: 'manual', focusDistance: value })
  }, [])

  const start = useCallback(async () => {
    if (activeRef.current) return
    const session = ++sessionRef.current
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
      if (!video) throw new Error('Tampilan kamera belum siap. Tutup lalu buka lagi.')

      const stream = await navigator.mediaDevices.getUserMedia({
        video: {
          deviceId: deviceId ? { exact: deviceId } : undefined,
          facingMode: deviceId ? undefined : { ideal: 'environment' },
          width: { ideal: 1920 },
          height: { ideal: 1080 },
        },
        audio: false,
      })
      if (session !== sessionRef.current) {
        // Panel ditutup saat izin kamera masih diminta: jangan biarkan kamera menyala.
        stream.getTracks().forEach(t => t.stop())
        return
      }
      streamRef.current = stream
      video.srcObject = stream
      video.setAttribute('playsinline', 'true')
      await video.play()

      const track = stream.getVideoTracks()[0]
      const support = readFocusSupport(track)
      if (support.modes.includes('continuous')) await applyFocus(track, { focusMode: 'continuous' })
      setFocus(support)

      const frame = document.createElement('canvas')
      const fctx = frame.getContext('2d', { willReadFrequently: true })
      const rotated = document.createElement('canvas')
      const rctx = rotated.getContext('2d', { willReadFrequently: true })
      if (!fctx || !rctx) throw new Error('Browser ini tidak dapat memproses gambar kamera.')

      const tryDecode = (source: HTMLCanvasElement): string | null => {
        try {
          return normalizeBarcode(reader.decodeFromCanvas(source).getText())
        } catch {
          return null // frame ini tidak berisi barcode terbaca
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
        const emitNow = shouldEmitCameraCode(lastRef.current, code, now)
        lastRef.current = { code, seenAt: now }
        if (!emitNow) return
        playBeep()
        onScanRef.current(code)
      }

      const loop = () => {
        if (!activeRef.current) return
        const v = videoRef.current
        if (!v || v.readyState < 2 || v.videoWidth === 0) {
          timerRef.current = window.setTimeout(loop, 200)
          return
        }
        const scale = Math.min(1, MAX_PROCESS_WIDTH / v.videoWidth)
        frame.width = Math.round(v.videoWidth * scale)
        frame.height = Math.round(v.videoHeight * scale)
        fctx.imageSmoothingEnabled = true
        fctx.imageSmoothingQuality = 'high'
        fctx.drawImage(v, 0, 0, frame.width, frame.height)

        const code = tryDecode(frame)
          ?? tryDecode(rotateInto(frame, 90))
          ?? tryDecode(rotateInto(frame, 270))
          ?? tryDecode(rotateInto(frame, 180))
        if (code) emit(code)
        timerRef.current = window.setTimeout(loop, SCAN_INTERVAL_MS)
      }

      if (session !== sessionRef.current) return
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
      } else if (err.name === 'NotReadableError') {
        setState('error')
        setError('Kamera sedang dipakai aplikasi lain. Tutup aplikasi itu lalu coba lagi.')
      } else {
        setState('error')
        setError('Kamera tidak dapat dimulai. Coba lagi atau ketik kode secara manual.')
      }
    }
  }, [deviceId])

  useEffect(() => () => { stop() }, [stop])

  return {
    state, error, videoRef, start, stop, devices, deviceId, setDeviceId, lastDetected,
    focus, refocus, setManualFocus,
  }
}
