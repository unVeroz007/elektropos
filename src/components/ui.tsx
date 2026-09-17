import { useEffect, useId, useRef, type ReactNode } from 'react'
import { errorText } from '../lib/errors'
import { parseQuantity, parseRupiah } from '../lib/numbers'
import './ui.css'

/**
 * Komponen UI bersama. Semua modul memakai komponen ini agar tampilan, ukuran
 * sentuh, label dan pesan error konsisten untuk pengguna senior.
 */

export function PageHeader({ title, description, actions }: {
  title: string
  description?: string
  actions?: ReactNode
}) {
  return (
    <header className="ui-page-header">
      <div>
        <h1>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      {actions && <div className="ui-page-actions">{actions}</div>}
    </header>
  )
}

/** Pesan error siap tampil. Menerima AppError, error Supabase, atau teks. */
export function ErrorMessage({ error }: { error: unknown }) {
  if (!error) return null
  const text = typeof error === 'string' ? error : errorText(error as Error)
  return <div className="ui-alert ui-alert-error" role="alert">{text}</div>
}

export function Notice({ tone = 'info', children }: { tone?: 'info' | 'success' | 'warning'; children: ReactNode }) {
  return <div className={`ui-alert ui-alert-${tone}`} role={tone === 'success' ? 'status' : undefined}>{children}</div>
}

export function Loading({ label = 'Memuat…' }: { label?: string }) {
  return <p className="ui-loading" role="status">{label}</p>
}

export function EmptyState({ children }: { children: ReactNode }) {
  return <div className="ui-empty">{children}</div>
}

export function Card({ title, actions, children }: { title?: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <section className="ui-card">
      {(title || actions) && (
        <div className="ui-card-head">
          {title && <h2>{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </section>
  )
}

export function Field({ label, hint, error, children }: {
  label: string
  hint?: string
  error?: string | null
  children: (id: string, describedBy?: string) => ReactNode
}) {
  const id = useId()
  const hintId = hint ? `${id}-hint` : undefined
  const errorId = error ? `${id}-error` : undefined
  const describedBy = [hintId, errorId].filter(Boolean).join(' ') || undefined
  return (
    <div className="ui-field">
      <label htmlFor={id}>{label}</label>
      {children(id, describedBy)}
      {hint && <small id={hintId}>{hint}</small>}
      {error && <small id={errorId} className="ui-field-error">{error}</small>}
    </div>
  )
}

type TextInputProps = {
  label: string
  value: string
  onChange: (value: string) => void
  hint?: string
  placeholder?: string
  required?: boolean
  disabled?: boolean
  autoFocus?: boolean
  maxLength?: number
}

export function TextInput({ label, value, onChange, hint, ...rest }: TextInputProps & { type?: 'text' | 'tel' | 'date' | 'datetime-local' | 'search' }) {
  return (
    <Field label={label} hint={hint}>
      {(id, describedBy) => (
        <input id={id} aria-describedby={describedBy} value={value} onChange={e => onChange(e.target.value)} {...rest} />
      )}
    </Field>
  )
}

export function TextArea({ label, value, onChange, hint, rows = 3, ...rest }: TextInputProps & { rows?: number }) {
  return (
    <Field label={label} hint={hint}>
      {(id, describedBy) => (
        <textarea id={id} aria-describedby={describedBy} rows={rows} value={value} onChange={e => onChange(e.target.value)} {...rest} />
      )}
    </Field>
  )
}

/** Input Rupiah bulat. Nilai tetap teks mentah; validasi tampil di bawah kolom. */
export function RupiahInput({ label, value, onChange, hint, ...rest }: TextInputProps) {
  let error: string | null = null
  if (value.trim() !== '') {
    try { parseRupiah(value) } catch (err) { error = (err as Error).message }
  }
  return (
    <Field label={label} hint={hint} error={error}>
      {(id, describedBy) => (
        <div className="ui-affix">
          <span aria-hidden="true">Rp</span>
          <input id={id} aria-describedby={describedBy} aria-invalid={Boolean(error)} inputMode="numeric"
            autoComplete="off" value={value} onChange={e => onChange(e.target.value)} {...rest} />
        </div>
      )}
    </Field>
  )
}

/** Input kuantitas (koma atau titik desimal) dengan satuan di sebelah kanan. */
export function QuantityInput({ label, value, onChange, unit, hint, ...rest }: TextInputProps & { unit?: string }) {
  let error: string | null = null
  if (value.trim() !== '') {
    try { parseQuantity(value) } catch (err) { error = (err as Error).message }
  }
  return (
    <Field label={label} hint={hint} error={error}>
      {(id, describedBy) => (
        <div className="ui-affix ui-affix-end">
          <input id={id} aria-describedby={describedBy} aria-invalid={Boolean(error)} inputMode="decimal"
            autoComplete="off" value={value} onChange={e => onChange(e.target.value)} {...rest} />
          {unit && <span aria-hidden="true">{unit}</span>}
        </div>
      )}
    </Field>
  )
}

export function Select<T extends string>({ label, value, onChange, options, hint, disabled }: {
  label: string
  value: T
  onChange: (value: T) => void
  options: { value: T; label: string }[]
  hint?: string
  disabled?: boolean
}) {
  return (
    <Field label={label} hint={hint}>
      {(id, describedBy) => (
        <select id={id} aria-describedby={describedBy} value={value} disabled={disabled}
          onChange={e => onChange(e.target.value as T)}>
          {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
        </select>
      )}
    </Field>
  )
}

/**
 * Pilihan besar berbentuk tombol (radio) untuk keputusan penting seperti metode bayar.
 */
export function ChoiceGroup<T extends string>({ label, value, onChange, options }: {
  label: string
  value: T
  onChange: (value: T) => void
  options: { value: T; label: string; description?: string }[]
}) {
  const name = useId()
  return (
    <fieldset className="ui-choices">
      <legend>{label}</legend>
      {options.map(o => (
        <label key={o.value} className={o.value === value ? 'is-selected' : undefined}>
          <input type="radio" name={name} value={o.value} checked={o.value === value} onChange={() => onChange(o.value)} />
          <span>{o.label}</span>
          {o.description && <small>{o.description}</small>}
        </label>
      ))}
    </fieldset>
  )
}

export function Checkbox({ label, checked, onChange, disabled }: {
  label: string
  checked: boolean
  onChange: (checked: boolean) => void
  disabled?: boolean
}) {
  return (
    <label className="ui-checkbox">
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  )
}

/**
 * Dialog konfirmasi untuk aksi berbahaya/tak dapat dibatalkan (tutup kas,
 * kosongkan keranjang, serah terima). Memakai <dialog> native: fokus terkunci & Escape menutup.
 */
export function ConfirmDialog({ open, title, children, confirmLabel, cancelLabel = 'Batal', danger, busy, onConfirm, onCancel }: {
  open: boolean
  title: string
  children?: ReactNode
  confirmLabel: string
  cancelLabel?: string
  danger?: boolean
  busy?: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  const ref = useRef<HTMLDialogElement>(null)
  const titleId = useId()
  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    if (open && !dialog.open) dialog.showModal()
    if (!open && dialog.open) dialog.close()
  }, [open])
  return (
    <dialog ref={ref} className="ui-dialog" onCancel={e => { e.preventDefault(); onCancel() }} aria-labelledby={titleId}>
      <h2 id={titleId}>{title}</h2>
      {children && <div className="ui-dialog-body">{children}</div>}
      <div className="ui-dialog-actions">
        <button type="button" className="ui-button ui-button-secondary" onClick={onCancel} disabled={busy}>{cancelLabel}</button>
        <button type="button" className={`ui-button ${danger ? 'ui-button-danger' : 'ui-button-primary'}`} onClick={onConfirm} disabled={busy} autoFocus>
          {busy ? 'Memproses…' : confirmLabel}
        </button>
      </div>
    </dialog>
  )
}

/** Baris label–nilai untuk ringkasan (struk, saldo kas, laporan). */
export function SummaryRow({ label, value, strong, tone }: {
  label: ReactNode
  value: ReactNode
  strong?: boolean
  tone?: 'danger' | 'success'
}) {
  return (
    <div className={`ui-summary-row${strong ? ' is-strong' : ''}${tone ? ` is-${tone}` : ''}`}>
      <span>{label}</span>
      <span>{value}</span>
    </div>
  )
}

export function Badge({ tone = 'neutral', children }: { tone?: 'neutral' | 'info' | 'success' | 'warning' | 'danger'; children: ReactNode }) {
  return <span className={`ui-badge ui-badge-${tone}`}>{children}</span>
}
