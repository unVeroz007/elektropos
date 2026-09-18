import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useProfile } from '../../lib/session'
import { EmptyState, PageHeader } from '../../components/ui'
import { access, type AccessKey } from './access'
import { homePath } from './nav'

/** Tampilkan halaman hanya bila peran boleh; selain itu pesan ramah (bukan redirect diam-diam). */
export function RequireAccess({ rule, children }: { rule: AccessKey; children: ReactNode }) {
  const profile = useProfile()
  if (access[rule](profile)) return <>{children}</>
  return (
    <section>
      <PageHeader title="Halaman ini tidak tersedia untuk akun Anda" />
      <EmptyState>
        <p>Minta pemilik toko bila Anda perlu melakukan pekerjaan ini.</p>
        <Link className="ui-button ui-button-primary" to={homePath(profile)}>Kembali ke halaman awal</Link>
      </EmptyState>
    </section>
  )
}

export function NotFoundPage() {
  const profile = useProfile()
  return (
    <section>
      <PageHeader title="Halaman tidak ditemukan" description="Alamat yang dibuka tidak ada atau sudah dipindah." />
      <Link className="ui-button ui-button-primary" to={homePath(profile)}>Kembali ke halaman awal</Link>
    </section>
  )
}
