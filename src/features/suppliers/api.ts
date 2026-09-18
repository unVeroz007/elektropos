import { useQuery } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'

export type Supplier = {
  id: string
  name: string
  contact: string | null
  address: string | null
  active: boolean
  version: number
  credit_balance: string
  pending_return_count: number
  pending_claim_value: string
}

export type SupplierReturnItem = {
  line_no: number
  product_id: string
  sku: string
  name: string
  qty_base: string
  unit: string
  cost: string
  source_location: string
  condition: string
  position_label: string | null
}

export type SupplierReturn = {
  id: string
  document_number: string
  supplier_id: string
  supplier_name: string
  status: 'PENDING' | 'SETTLED'
  reason: string
  claim_value: string
  created_at: string
  outcome: string | null
  settled_amount: string | null
  settlement_method: string | null
  settlement_cashbox: string | null
  settlement_reference: string | null
  settlement_difference: string | null
  settlement_note: string | null
  settled_at: string | null
  replacement_document_number: string | null
  version: number
  items: SupplierReturnItem[]
}

export const supplierKeys = {
  all: ['suppliers'] as const,
  list: (query: string, includeInactive: boolean) => ['suppliers', 'list', query, includeInactive] as const,
  returns: (filter: Record<string, unknown>) => ['suppliers', 'returns', filter] as const,
}

export function useSuppliers(query = '', includeInactive = false, enabled = true) {
  return useQuery({
    queryKey: supplierKeys.list(query, includeInactive),
    queryFn: async () => (await readRpc<{ items: Supplier[] }>('list_suppliers_v1', {
      ...(query ? { query } : {}), include_inactive: includeInactive,
    })).items,
    enabled,
  })
}
