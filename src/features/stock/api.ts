import { useInfiniteQuery } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'

export type StockPositionRow = {
  position_id: string
  version: number
  product_id: string
  sku: string
  name: string
  base_unit: string
  quantity_step: string
  track_segments: boolean
  location: 'SHOP' | 'FIELD_FATHER'
  condition: 'SALEABLE' | 'DAMAGED'
  qty_base: string
  label: string | null
  segment_capacity: string | null
  sealed: boolean
  lot_id: string
  lot_posted_at: string
  lot_remaining_qty?: string
  lot_remaining_cost?: string
}

export type StockMovementRow = {
  id: string
  occurred_at: string
  kind: string
  qty_delta: string
  product_id: string
  sku: string
  name: string
  base_unit: string
  position_id: string
  label: string | null
  location: string
  condition: string
  document_number: string | null
  document_kind: string | null
  reason: string | null
  invoice_number: string | null
  service_ticket_number: string | null
  actor_name: string | null
  cost_delta?: string
}

export type Page<T> = { rows: T[]; has_more: boolean; next_offset: number | null }

export const stockKeys = {
  all: ['stock'] as const,
  positions: (filter: Record<string, unknown>) => ['stock', 'positions', filter] as const,
  movements: (filter: Record<string, unknown>) => ['stock', 'movements', filter] as const,
  counts: ['stock', 'counts'] as const,
  count: (id: string) => ['stock', 'count', id] as const,
}

/** Daftar halaman-demi-halaman (limit/offset server) dengan tombol "Muat lebih banyak". */
export function usePagedRpc<T>(rpc: string, key: readonly unknown[], input: Record<string, unknown>, enabled = true) {
  return useInfiniteQuery({
    queryKey: key,
    queryFn: ({ pageParam }) => readRpc<Page<T>>(rpc, { ...input, limit: 50, offset: pageParam }),
    initialPageParam: 0,
    getNextPageParam: last => last.has_more ? last.next_offset ?? undefined : undefined,
    enabled,
  })
}
