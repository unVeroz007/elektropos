import { useCallback } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'
import { useCommand } from '../../lib/useCommand'
import type {
  CustomerHistory, CustomerSearchRow, ShopSettings, SimilarCustomer, StockPositionRow, TicketDetail, TicketPage,
  WorkStatus, ServiceLocation,
} from './types'

export const serviceKeys = {
  all: ['service'] as const,
  list: (filters: TicketFilters) => ['service', 'tickets', filters] as const,
  ticket: (id: string) => ['service', 'ticket', id] as const,
  photos: (id: string) => ['service', 'photos', id] as const,
  customers: ['service', 'customers'] as const,
  customerSearch: (query: string) => ['service', 'customers', 'search', query] as const,
  customerHistory: (id: string) => ['service', 'customers', 'history', id] as const,
  shop: ['service', 'shop'] as const,
}

export type TicketFilters = {
  status?: WorkStatus[]
  query?: string
  include_closed?: boolean
  not_picked_up?: boolean
  service_location?: ServiceLocation
}

export function listTickets(filters: TicketFilters, cursor: string | null): Promise<TicketPage> {
  const input: Record<string, unknown> = { limit: 25 }
  if (filters.status?.length) input.status = filters.status
  if (filters.query?.trim()) input.query = filters.query.trim()
  if (filters.include_closed) input.include_closed = true
  if (filters.not_picked_up) input.not_picked_up = true
  if (filters.service_location) input.service_location = filters.service_location
  if (cursor) input.cursor = cursor
  return readRpc<TicketPage>('list_service_tickets_v1', input)
}

export const getTicket = (ticketId: string) => readRpc<TicketDetail>('get_service_ticket_v1', { ticket_id: ticketId })

export function searchCustomers(query: string): Promise<CustomerSearchRow[]> {
  const input: Record<string, unknown> = { limit: 25 }
  if (query.trim()) input.query = query.trim()
  return readRpc<CustomerSearchRow[]>('search_customers_v1', input)
}

export async function findSimilarCustomers(name: string, phone: string): Promise<SimilarCustomer[]> {
  const input: Record<string, unknown> = {}
  if (name.trim()) input.name = name.trim()
  if (phone.trim()) input.phone = phone.trim()
  const result = await readRpc<{ candidates: SimilarCustomer[] }>('find_similar_customers_v1', input)
  return result.candidates ?? []
}

export const customerHistory = (customerId: string) =>
  readRpc<CustomerHistory>('list_customer_history_v1', { customer_id: customerId, limit: 50 })

export async function searchPartPositions(query: string): Promise<StockPositionRow[]> {
  const result = await readRpc<{ rows: StockPositionRow[] }>('list_stock_positions_v1', {
    query: query.trim(), condition: 'SALEABLE', limit: 30,
  })
  return (result.rows ?? []).filter(r => r.location === 'SHOP' || r.location === 'FIELD_FATHER')
}

export const getShopSettings = () => readRpc<ShopSettings>('get_shop_settings_v1')

/**
 * Perintah tulis servis. operation_id dijaga `useCommand` (tetap sama selama hasil
 * belum diketahui); setelah sukses atau konflik versi data servis dimuat ulang.
 */
export function useServiceCommand<T, P extends Record<string, unknown>>(rpcName: string) {
  const command = useCommand<T, P>(rpcName)
  const queryClient = useQueryClient()
  const { run: rawRun } = command
  const run = useCallback(async (payload: P): Promise<T | null> => {
    const result = await rawRun(payload)
    await queryClient.invalidateQueries({ queryKey: serviceKeys.all })
    return result
  }, [rawRun, queryClient])
  return { ...command, run }
}
