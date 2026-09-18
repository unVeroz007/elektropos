import { useQuery } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'

export type CashboxCode = 'SHOP_DRAWER' | 'FATHER_WALLET'

export type CashMovement = {
  id: string
  direction: 'IN' | 'OUT'
  kind: string
  label: string
  amount: string
  reason: string | null
  occurred_at: string
  actor_name: string | null
  reference: string | null
}

export type OpenCashSession = {
  open: true
  id: string
  cashbox_code: CashboxCode
  cashbox_label: string
  status: 'OPEN' | 'CLOSED'
  business_date: string
  opened_at: string
  opened_by_name: string | null
  opening_amount: string
  previous_counted_amount: string | null
  opening_variance: string | null
  opening_note: string | null
  expected: string
  total_in: string
  total_out: string
  closed_at: string | null
  closed_by_name: string | null
  counted_amount: string | null
  variance: string | null
  close_note: string | null
  needs_review: boolean
  review_pending: boolean
  reviewed_at: string | null
  review_note: string | null
  version: number
  movements?: CashMovement[]
}

export type ClosedCashbox = {
  open: false
  cashbox_code: CashboxCode
  last_session_id: string | null
  last_closed_at: string | null
  last_counted_amount: string | null
}

export type CashSessionView = OpenCashSession | ClosedCashbox

/** Sesi dari riwayat: bentuk sama dengan sesi terbuka tetapi `open` bisa false. */
export type CashSessionRecord = Omit<OpenCashSession, 'open'> & { open: boolean }

export const cashKeys = {
  all: ['cash'] as const,
  session: (code: CashboxCode) => ['cash', 'session', code] as const,
  sessionById: (id: string) => ['cash', 'session-id', id] as const,
  history: (filter: Record<string, unknown>) => ['cash', 'history', filter] as const,
}

export function useCashSession(code: CashboxCode, enabled = true) {
  return useQuery({
    queryKey: cashKeys.session(code),
    queryFn: () => readRpc<CashSessionView>('get_cash_session_v1', { cashbox_code: code }),
    enabled,
    refetchInterval: 60_000,
  })
}
