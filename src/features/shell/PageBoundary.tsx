import { Component, type ErrorInfo, type ReactNode } from 'react'
import { Link } from 'react-router-dom'

type Props = { children: ReactNode }
type State = { failed: boolean }

/**
 * Penangkap error per halaman: bila satu halaman rusak, navigasi tetap ada dan
 * pengguna mendapat tombol muat ulang, bukan layar kosong.
 */
export class PageBoundary extends Component<Props, State> {
  state: State = { failed: false }

  static getDerivedStateFromError(): State {
    return { failed: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Dicatat ke konsol browser untuk pengelola aplikasi; pengguna hanya melihat pesan awam.
    console.error('Halaman gagal ditampilkan', error, info.componentStack)
  }

  render() {
    if (!this.state.failed) return this.props.children
    return (
      <section className="page-failed" role="alert">
        <h1>Halaman ini gagal ditampilkan</h1>
        <p>Data yang sudah tersimpan tidak hilang. Muat ulang halaman untuk mencoba lagi.</p>
        <div className="button-row">
          <button type="button" className="ui-button ui-button-primary" onClick={() => window.location.reload()}>
            Muat ulang halaman
          </button>
          <Link className="ui-button ui-button-secondary" to="/" onClick={() => this.setState({ failed: false })}>
            Ke halaman awal
          </Link>
        </div>
      </section>
    )
  }
}
