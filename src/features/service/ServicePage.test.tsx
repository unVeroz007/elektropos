// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { screen } from '@testing-library/react'
import { renderPage } from '../../test/render'
import { ServicePage } from './ServicePage'

const readRpc = vi.fn()
vi.mock('../../lib/rpc', () => ({
  readRpc: (...args: unknown[]) => readRpc(...args),
  commandRpc: vi.fn(),
  newOperationId: () => 'op-1',
}))

describe('daftar tiket servis', () => {
  beforeEach(() => { readRpc.mockReset() })

  it('menampilkan error server, bukan "belum ada tiket" (bug audit K12)', async () => {
    readRpc.mockRejectedValue(new Error('column "created_at" does not exist'))
    renderPage(<ServicePage />, { url: '/servis', path: '/servis' })
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(screen.queryByText(/Belum ada tiket servis/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Coba muat lagi' })).toBeInTheDocument()
  })

  it('menampilkan tiket dari kontrak {items, next_cursor}', async () => {
    readRpc.mockResolvedValue({
      items: [{
        id: 't1', number: 'SRV-20260918-000001', work_status: 'READY', service_location: 'STORE',
        custody_location: 'SHOP', equipment_type: 'TV', equipment_brand: 'Sharp', equipment_model: null,
        complaint: 'Mati total', customer_name: 'Budi', customer_phone: '0812', created_at: '2026-09-18T01:00:00Z',
        scheduled_at: null, closed_at: null, not_picked_up: true, payment_status: 'UNPAID',
      }],
      next_cursor: null,
    })
    renderPage(<ServicePage />, { url: '/servis', path: '/servis', role: 'STAFF' })
    expect(await screen.findByText('SRV-20260918-000001')).toBeInTheDocument()
    expect(readRpc).toHaveBeenCalledWith('list_service_tickets_v1', expect.objectContaining({ limit: 25 }))
  })
})
