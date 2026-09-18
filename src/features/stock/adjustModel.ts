import { quantityOrNull, rupiahOrNull } from '../../lib/numbers'

/** Koreksi stok arah Tambah (BR-06): lot koreksi baru dengan modal terkonfirmasi atau alasan modal nol. */
export type AdjustInState = {
  productId: string
  trackSegments: boolean
  location: 'SHOP' | 'FIELD_FATHER'
  condition: 'SALEABLE' | 'DAMAGED'
  qty: string
  costMode: 'COST' | 'ZERO'
  cost: string
  costConfirmed: boolean
  zeroReason: string
  label: string
  capacity: string
  reason: string
}

export function adjustInErrors(s: AdjustInState): string[] {
  const errors: string[] = []
  if (!s.productId) errors.push('Pilih barang.')
  if (!quantityOrNull(s.qty)) errors.push('Jumlah tambah wajib diisi dan lebih dari nol.')
  if (s.costMode === 'COST') {
    if (!rupiahOrNull(s.cost)) errors.push('Total modal barang yang ditambah wajib diisi.')
    if (!s.costConfirmed) errors.push('Centang bahwa nilai modal sudah benar.')
  } else if (!s.zeroReason.trim()) {
    errors.push('Tulis alasan barang ditambah tanpa modal.')
  }
  if (s.trackSegments && !s.label.trim()) errors.push('Label roll/potongan wajib diisi.')
  if (s.capacity.trim() && !quantityOrNull(s.capacity)) errors.push('Panjang roll asal tidak sah.')
  if (!s.reason.trim()) errors.push('Alasan koreksi wajib diisi.')
  return errors
}

/** Payload `adjust_stock_v1` arah IN (tanpa operation_id). */
export function buildAdjustInPayload(s: AdjustInState): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    direction: 'IN',
    product_id: s.productId,
    location: s.location,
    condition: s.condition,
    qty_base: quantityOrNull(s.qty),
    reason: s.reason.trim(),
  }
  if (s.costMode === 'COST') {
    payload.acquisition_cost = rupiahOrNull(s.cost)
    payload.cost_confirmed = s.costConfirmed
  } else {
    payload.zero_cost_reason = s.zeroReason.trim()
  }
  if (s.trackSegments) {
    payload.label = s.label.trim()
    if (s.capacity.trim()) payload.segment_capacity = quantityOrNull(s.capacity)
  }
  return payload
}
