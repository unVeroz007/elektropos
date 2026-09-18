import type { ReactNode } from 'react'
import { Badge, ErrorMessage, Notice } from '../../components/ui'
import type { AppError } from '../../lib/errors'
import { PAYMENT_STATUS, paymentTone, statusLabel, statusTone } from './labels'
import type { PaymentStatus, ServiceLocation, WorkStatus } from './types'

export function StatusBadge({ status, location }: { status: WorkStatus; location?: ServiceLocation }) {
  return <Badge tone={statusTone(status)}>{statusLabel(status, location)}</Badge>
}

export function PaymentBadge({ status }: { status: PaymentStatus }) {
  return <Badge tone={paymentTone(status)}>{PAYMENT_STATUS[status] ?? 'Status bayar lain'}</Badge>
}

/**
 * Hasil perintah: error bisnis ditampilkan, hasil tak diketahui (koneksi putus)
 * diberi petunjuk bahwa tombol yang sama aman ditekan lagi.
 */
export function CommandError({ error }: { error: AppError | null }) {
  if (!error) return null
  if (error.kind === 'network') {
    return (
      <Notice tone="warning">
        {error.display} Tombol yang sama aman ditekan lagi; sistem memeriksa agar tidak tercatat dua kali.
      </Notice>
    )
  }
  return <ErrorMessage error={error} />
}

/** Tombol biasa dengan kelas UI bersama. */
export function Button({ children, variant = 'primary', ...rest }: {
  children: ReactNode
  variant?: 'primary' | 'secondary' | 'danger'
  type?: 'button' | 'submit'
  disabled?: boolean
  onClick?: () => void
  large?: boolean
}) {
  const { large, type = 'button', ...buttonProps } = rest
  return (
    <button type={type} className={`ui-button ui-button-${variant}${large ? ' ui-button-large' : ''}`} {...buttonProps}>
      {children}
    </button>
  )
}

/** Panel lipat untuk langkah yang jarang dipakai (tetap bisa dengan keyboard). */
export function Collapsible({ title, children, defaultOpen }: { title: string; children: ReactNode; defaultOpen?: boolean }) {
  return (
    <details className="srv-collapsible" open={defaultOpen}>
      <summary>{title}</summary>
      <div className="srv-collapsible-body">{children}</div>
    </details>
  )
}
