import { useState, type FormEvent } from 'react'
import { configured, supabase } from '../../lib/supabase'
import { toAppError } from '../../lib/errors'
import { Notice } from '../../components/ui'
import { useOnlineStatus } from '../../lib/online'

function loginErrorText(message: string): string {
  const error = toAppError(message)
  if (error.kind === 'network') return 'Tidak dapat terhubung ke server toko. Periksa internet atau pastikan komputer toko menyala, lalu coba lagi.'
  if (/invalid login|invalid credentials|email not confirmed/i.test(message)) {
    return 'Email atau sandi salah. Periksa huruf besar/kecil lalu coba lagi.'
  }
  if (/rate limit|too many/i.test(message)) return 'Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.'
  return 'Belum bisa masuk. Coba lagi; bila terus gagal, hubungi pengelola aplikasi.'
}

export function LoginPage({ notice }: { notice?: string }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const online = useOnlineStatus()

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setBusy(true)
    setError('')
    try {
      const result = await supabase.auth.signInWithPassword({ email: email.trim(), password })
      if (result.error) setError(loginErrorText(result.error.message))
      else setPassword('')
    } catch (err) {
      setError(loginErrorText((err as Error).message ?? ''))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="login-wrap">
      <section className="login-card" aria-labelledby="login-title">
        <p className="login-eyebrow">Toko Listrik &amp; Servis Elektronik</p>
        <h1 id="login-title">ElektroPOS</h1>
        <p>Masuk dengan akun pribadi Anda.</p>
        {notice && <Notice tone="warning">{notice}</Notice>}
        {!configured && (
          <Notice tone="warning">Aplikasi belum disambungkan ke server toko. Minta pengelola aplikasi mengisi pengaturan koneksi.</Notice>
        )}
        {!online && <Notice tone="warning">Internet sedang terputus. Sambungkan dulu untuk masuk.</Notice>}
        <form onSubmit={submit} className="login-form">
          <div className="ui-field">
            <label htmlFor="login-email">Email</label>
            <input id="login-email" type="email" autoComplete="username" value={email}
              onChange={e => setEmail(e.target.value)} required />
          </div>
          <div className="ui-field">
            <label htmlFor="login-password">Sandi</label>
            <input id="login-password" type="password" autoComplete="current-password" value={password}
              onChange={e => setPassword(e.target.value)} required />
          </div>
          {error && <div className="ui-alert ui-alert-error" role="alert">{error}</div>}
          <button type="submit" className="ui-button ui-button-primary ui-button-large" disabled={busy || !configured}>
            {busy ? 'Memeriksa akun…' : 'Masuk'}
          </button>
        </form>
        <small>Akun dibuat oleh pemilik toko. Lupa sandi? Minta pemilik toko mengaturnya ulang.</small>
      </section>
    </main>
  )
}
