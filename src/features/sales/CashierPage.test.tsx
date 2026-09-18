// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { renderPage } from '../../test/render'
import { CashierPage } from './CashierPage'

const readRpc = vi.fn()
const commandRpc = vi.fn()
vi.mock('../../lib/rpc', () => ({
  readRpc: (...args: unknown[]) => readRpc(...args),
  commandRpc: (...args: unknown[]) => commandRpc(...args),
  newOperationId: () => 'op-fixed',
}))
vi.mock('../../lib/drafts', () => ({
  listDrafts: async () => [],
  saveDraft: async () => 1,
  deleteDraft: async () => undefined,
  getDeviceId: () => 'device-1',
}))

const lamp = {
  id: 'p1', sku: 'LMP', name: 'Lampu LED 12W', specification: '', base_unit: 'pcs', shelf: 'A1', track_segments: false,
  quantity_step: '1', version: 1, stock_shop: '10', stock_field: '0',
  units: [{ id: 'u1', label: 'pcs', factor_base: '1', sale_step: '1', sell_price: '18000', is_default: true, whole_roll: false, version: 3 }],
}

const preview = (qty: string, total: string) => ({
  ok: true, subtotal: total, discount: '0', total, requires_owner_reason: false, tendered: null, change: null,
  items: [{
    line_no: 1, product_id: 'p1', product_unit_id: 'u1', unit_version: 3, description: 'Lampu', unit_label: 'pcs',
    track_segments: false, position_id: null, qty_sell: qty, qty_base: qty, unit_price: '18000', gross_exact: total,
    line_discount: '0', base_net: total, invoice_discount_alloc: '0', net_total: total, available_base: '10',
  }],
})

describe('kasir', () => {
  beforeEach(() => {
    readRpc.mockReset()
    commandRpc.mockReset()
    readRpc.mockImplementation(async (name: string, input?: { items?: { qty: string }[] }) => {
      if (name === 'get_cash_session_v1') return { open: true }
      if (name === 'search_products_v1') return [lamp]
      if (name === 'preview_sale_v1') {
        const qty = input?.items?.[0]?.qty ?? '1'
        return preview(qty, String(18000 * Number(qty)))
      }
      throw new Error(`RPC tak terduga ${name}`)
    })
  })

  it('STAFF: cari, tambah, QRIS wajib dicentang, lalu bayar dengan total server', async () => {
    const user = userEvent.setup()
    commandRpc.mockResolvedValue({ ok: true, entity_id: 'inv-1', document_number: 'SALE-1', total: '36000', change: '0' })
    renderPage(<CashierPage />, { role: 'STAFF', url: '/kasir', path: '/kasir' })

    await user.type(screen.getByLabelText('Cari barang'), 'lampu')
    await user.click(await screen.findByRole('button', { name: /Tambah pcs/ }))
    await user.click(screen.getByRole('button', { name: 'Tambah jumlah Lampu LED 12W' }))
    expect(screen.queryByLabelText(/Diskon/)).not.toBeInTheDocument()

    await user.click(screen.getByLabelText(/QRIS/))
    const pay = await screen.findByRole('button', { name: 'Bayar Rp36.000' })
    expect(pay).toBeDisabled()
    await user.click(screen.getByLabelText('Saya sudah memastikan uang masuk'))
    await waitFor(() => expect(pay).toBeEnabled())
    await user.click(pay)

    await waitFor(() => expect(commandRpc).toHaveBeenCalledTimes(1))
    const [name, payload] = commandRpc.mock.calls[0]
    expect(name).toBe('finalize_sale_v1')
    expect(payload).toMatchObject({
      operation_id: 'op-fixed',
      items: [{ product_unit_id: 'u1', qty: '2', expected_unit_version: 3 }],
      payment: { method: 'QRIS', confirmed: true },
    })
    expect(JSON.stringify(payload)).not.toContain('discount')
  })

  it('tunai: uang kurang memblokir tombol bayar', async () => {
    const user = userEvent.setup()
    renderPage(<CashierPage />, { role: 'STAFF', url: '/kasir', path: '/kasir' })
    await user.type(screen.getByLabelText('Cari barang'), 'lampu')
    await user.click(await screen.findByRole('button', { name: /Tambah pcs/ }))
    await user.type(screen.getByLabelText('Uang diterima dari pembeli'), '10.000')
    expect(await screen.findByText('Uang kurang Rp8.000.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Bayar/ })).toBeDisabled()
    expect(commandRpc).not.toHaveBeenCalled()
  })
})
