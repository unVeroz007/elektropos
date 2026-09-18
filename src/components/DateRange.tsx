import { todayInShop } from '../lib/numbers'
import { TextInput } from './ui'

export const MAX_RANGE_DAYS = 366

export type DateRangeValue = { start: string; end: string }

const DATE = /^\d{4}-\d{2}-\d{2}$/

function dayNumber(date: string): number {
  return Date.UTC(Number(date.slice(0, 4)), Number(date.slice(5, 7)) - 1, Number(date.slice(8, 10))) / 86_400_000
}

/** Pesan kesalahan rentang tanggal toko (WIB), atau null bila sah. Server tetap memeriksa ulang. */
export function rangeError({ start, end }: DateRangeValue): string | null {
  if (!DATE.test(start) || !DATE.test(end)) return 'Pilih tanggal awal dan akhir.'
  const days = dayNumber(end) - dayNumber(start) + 1
  if (days < 1) return 'Tanggal awal harus sebelum atau sama dengan tanggal akhir.'
  if (days > MAX_RANGE_DAYS) return `Rentang maksimal ${MAX_RANGE_DAYS} hari. Persempit tanggalnya.`
  return null
}

/** Awal bulan berjalan di zona toko, mis. `2026-09-01`. */
export function monthStartInShop(): string {
  return `${todayInShop().slice(0, 8)}01`
}

export const RANGE_PRESETS: { label: string; range: () => DateRangeValue }[] = [
  { label: 'Hari ini', range: () => ({ start: todayInShop(), end: todayInShop() }) },
  { label: '7 hari terakhir', range: () => ({ start: todayInShop(-6), end: todayInShop() }) },
  { label: 'Bulan ini', range: () => ({ start: monthStartInShop(), end: todayInShop() }) },
]

export function DateRangeFields({ value, onChange, presets = true }: {
  value: DateRangeValue
  onChange: (value: DateRangeValue) => void
  presets?: boolean
}) {
  const error = rangeError(value)
  return (
    <div className="date-range">
      <div className="form-grid">
        <TextInput type="date" label="Dari tanggal" value={value.start} onChange={start => onChange({ ...value, start })} />
        <TextInput type="date" label="Sampai tanggal" value={value.end} onChange={end => onChange({ ...value, end })} />
      </div>
      {presets && (
        <div className="button-row">
          {RANGE_PRESETS.map(p => (
            <button key={p.label} type="button" className="ui-button ui-button-secondary" onClick={() => onChange(p.range())}>
              {p.label}
            </button>
          ))}
        </div>
      )}
      {error && <p className="field-error" role="alert">{error}</p>}
    </div>
  )
}
