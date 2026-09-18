import Decimal from 'decimal.js'
import { formatQuantity, parseQuantity, rupiahOrNull } from '../../lib/numbers'

/**
 * Logika formulir hitung stok (FR-INV-03, BR-06). Server otoritatif: selisih,
 * modal koreksi dan konflik versi dihitung ulang saat posting.
 */

export type CountItem = {
  line_no: number
  position_id: string
  product_id: string
  sku: string
  name: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  label: string | null
  location: string
  condition: string
  system_qty: string
  expected_version: number
  current_qty: string
  current_version: number
  changed_since_start: boolean
  counted_qty: string | null
  difference: string | null
  cost_delta: string | null
  reason: string | null
}

export type StockCount = {
  id: string
  status: 'DRAFT' | 'POSTED'
  version: number
  note: string | null
  created_at: string
  posted_at: string | null
  document_number: string | null
  items: CountItem[]
}

export type CountLineForm = {
  counted: string
  reason: string
  /** Kelebihan stok: modal diketahui (COST) atau alasan modal nol (ZERO). */
  costMode: 'COST' | 'ZERO'
  cost: string
  costConfirmed: boolean
  zeroReason: string
  newLabel: string
}

export const EMPTY_COUNT_LINE: CountLineForm = {
  counted: '', reason: '', costMode: 'COST', cost: '', costConfirmed: false, zeroReason: '', newLabel: '',
}

function safeQuantity(text: string): Decimal | null {
  try {
    return parseQuantity(text)
  } catch {
    return null
  }
}

/** Selisih hitung − sistem, atau null bila hitungan belum sah. */
export function countDifference(item: CountItem, form: CountLineForm): Decimal | null {
  const counted = safeQuantity(form.counted)
  return counted ? counted.minus(item.system_qty) : null
}

/** Masalah isian satu baris (kalimat awam), atau null. */
export function countLineIssue(item: CountItem, form: CountLineForm): string | null {
  if (form.counted.trim() === '') return 'Isi hasil hitung (0 bila habis).'
  const counted = safeQuantity(form.counted)
  if (!counted) {
    try {
      parseQuantity(form.counted)
    } catch (err) {
      return (err as Error).message
    }
    return 'Hasil hitung tidak sah.'
  }
  const step = new Decimal(item.quantity_step || '1')
  if (!step.isZero() && !counted.mod(step).isZero()) {
    return `Hasil hitung harus kelipatan ${formatQuantity(step, item.base_unit)}.`
  }
  const diff = counted.minus(item.system_qty)
  if (diff.greaterThan(0)) {
    if (form.costMode === 'COST') {
      if (!rupiahOrNull(form.cost)) return 'Isi total modal untuk kelebihan stok.'
      if (!form.costConfirmed) return 'Centang bahwa modal kelebihan stok sudah benar.'
    } else if (form.zeroReason.trim().length < 3) {
      return 'Tulis alasan kelebihan stok tanpa modal.'
    }
    if (item.track_segments && form.newLabel.trim() === '') {
      return 'Kelebihan kabel dicatat sebagai potongan baru: isi labelnya.'
    }
  }
  return null
}

export type PostCountItem = {
  position_id: string
  counted_qty: string
  reason?: string
  acquisition_cost?: string
  cost_confirmed?: boolean
  zero_cost_reason?: string
  new_label?: string
}

/** Payload posting, atau masalah pertama. Setiap posisi wajib dikirim tepat sekali. */
export function buildPostCount(count: StockCount, forms: Record<string, CountLineForm>, reason: string):
  { items: PostCountItem[]; reason: string } | { issue: string } {
  const items: PostCountItem[] = []
  for (const item of count.items) {
    const form = forms[item.position_id] ?? EMPTY_COUNT_LINE
    const issue = countLineIssue(item, form)
    if (issue) return { issue: `${item.name}${item.label ? ` (${item.label})` : ''}: ${issue}` }
    const counted = safeQuantity(form.counted) as Decimal
    const line: PostCountItem = { position_id: item.position_id, counted_qty: counted.toFixed() }
    if (form.reason.trim()) line.reason = form.reason.trim()
    if (counted.greaterThan(item.system_qty)) {
      if (form.costMode === 'COST') {
        line.acquisition_cost = rupiahOrNull(form.cost) as string
        line.cost_confirmed = true
      } else {
        line.zero_cost_reason = form.zeroReason.trim()
      }
      if (item.track_segments) line.new_label = form.newLabel.trim()
    }
    items.push(line)
  }
  return { items, reason: reason.trim() || 'Hitung stok' }
}

/** Ada posisi yang berubah sejak hitungan dimulai: posting pasti ditolak (VERSION_CONFLICT). */
export function hasConflict(count: StockCount): boolean {
  return count.items.some(i => i.changed_since_start)
}
