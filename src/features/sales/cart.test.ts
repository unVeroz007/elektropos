import { describe, expect, it } from 'vitest'
import {
  addToCart, applyProductRefresh, buildSaleInput, cartIssues, isWholeRoll, lineIssue, NO_DISCOUNT, quickCashOptions,
  stepQty, type CartLine, type ProductSnapshot, type RollPick,
} from './cart'
import { draftLabel, parseCartDraft } from './cartDraft'
import type { ProductDetail } from './types'

const lamp: ProductSnapshot = {
  productId: 'p-lamp', productName: 'Lampu LED 12W', specification: '', baseUnit: 'pcs', quantityStep: '1',
  trackSegments: false, unitId: 'u-lamp', unitLabel: 'pcs', unitVersion: 1, factorBase: '1', wholeRoll: false, saleStep: '1', sellPrice: '18000',
}
const cableMeter: ProductSnapshot = {
  productId: 'p-cable', productName: 'Kabel NYA', specification: '1,5 mm', baseUnit: 'm', quantityStep: '0.1',
  trackSegments: true, unitId: 'u-m', unitLabel: 'm', unitVersion: 1, factorBase: '1', wholeRoll: false, saleStep: '0.1', sellPrice: '7500',
}
const cableRoll: ProductSnapshot = { ...cableMeter, unitId: 'u-roll', unitLabel: 'roll 100m', factorBase: '100', wholeRoll: true, saleStep: '1', sellPrice: '650000' }
/** Keputusan pemilik 18-09-2026: satuan isi > 1 tanpa tanda roll utuh dijual sebagai potongan. */
const cableBundle: ProductSnapshot = { ...cableMeter, unitId: 'u-ikat', unitLabel: 'ikat 10m', factorBase: '10', saleStep: '1', sellPrice: '70000' }

const roll = (patch: Partial<RollPick>): RollPick => ({ id: 'r1', label: 'R-01', qtyBase: '100', capacity: '100', sealed: true, version: 1, ...patch })
const line = (snapshot: ProductSnapshot, key: string, patch: Partial<CartLine> = {}): CartLine => ({
  ...addToCart([], snapshot, key)[0], ...patch,
})

describe('keranjang menyimpan snapshot (T03)', () => {
  it('barang biasa yang sama digabung, qty naik satu langkah', () => {
    const once = addToCart([], lamp, 'a')
    const twice = addToCart(once, lamp, 'b')
    expect(twice).toHaveLength(1)
    expect(twice[0].qtyText).toBe('2')
    expect(twice[0].sellPrice).toBe('18000')
  })
  it('potongan kabel selalu baris baru (satu baris = satu potongan)', () => {
    const lines = addToCart(addToCart([], cableMeter, 'a'), cableMeter, 'b')
    expect(lines).toHaveLength(2)
    expect(lines[0].qtyText).toBe('')
  })
  it('tombol − tidak turun di bawah satu langkah', () => {
    expect(stepQty({ qtyText: '1', saleStep: '1' }, -1)).toBe('1')
    expect(stepQty({ qtyText: 'x', saleStep: '1' }, 1)).toBe('1')
    expect(stepQty({ qtyText: '2,5', saleStep: '0.5' }, 1)).toBe('3')
  })
})

describe('validasi baris', () => {
  it('qty kosong/salah langkah/pecahan pcs ditolak tanpa melempar', () => {
    expect(lineIssue(line(lamp, 'a', { qtyText: '' }), [])).toContain('Isi jumlah')
    expect(lineIssue(line(lamp, 'a', { qtyText: '1,5' }), [])).toContain('kelipatan')
    expect(lineIssue(line(lamp, 'a', { qtyText: '1.000,5' }), [])).not.toBeNull()
    expect(lineIssue(line(lamp, 'a', { qtyText: '3' }), [])).toBeNull()
  })
  it('meter harus sesuai ukuran terkecil 0,1 m', () => {
    const l = line(cableMeter, 'a', { qtyText: '2,55', position: roll({ sealed: false, qtyBase: '50' }) })
    expect(lineIssue(l, [l])).not.toBeNull()
  })
  it('diskon baris salah format ditolak', () => {
    expect(lineIssue(line(lamp, 'a', { discountMode: 'percent', discountText: '120' }), [])).not.toBeNull()
    expect(lineIssue(line(lamp, 'a', { discountMode: 'amount', discountText: '5.000' }), [])).toBeNull()
  })
})

describe('roll & potongan (BR-03, bukti audit K05)', () => {
  it('potongan wajib memilih roll fisik', () => {
    const l = line(cableMeter, 'a', { qtyText: '10' })
    expect(lineIssue(l, [l])).toContain('Pilih roll')
  })
  it('6 m tidak bisa dijual sebagai potongan 10 m', () => {
    const l = line(cableMeter, 'a', { qtyText: '10', position: roll({ id: 'p6', label: 'P-6', qtyBase: '6', sealed: false }) })
    expect(lineIssue(l, [l])).toContain('tidak bisa disambung')
  })
  it('dua baris dari potongan yang sama tidak melebihi sisanya', () => {
    const piece = roll({ id: 'p6', label: 'P-6', qtyBase: '6', sealed: false })
    const a = line(cableMeter, 'a', { qtyText: '4', position: piece })
    const b = line(cableMeter, 'b', { qtyText: '3', position: piece })
    expect(cartIssues([a, b]).size).toBe(2)
  })
  it('roll utuh hanya dari roll bersegel berkapasitas sama', () => {
    expect(isWholeRoll(cableRoll)).toBe(true)
    const open = line(cableRoll, 'a', { position: roll({ sealed: false, qtyBase: '60' }) })
    expect(lineIssue(open, [open])).toContain('bersegel')
    const sealed = line(cableRoll, 'b', { position: roll({}) })
    expect(lineIssue(sealed, [sealed])).toBeNull()
  })
  it('satuan berisi 10 m tanpa tanda roll utuh dipotong dari satu potongan', () => {
    expect(isWholeRoll(cableBundle)).toBe(false)
    const fits = line(cableBundle, 'a', { qtyText: '2', position: roll({ id: 'p60', qtyBase: '60', sealed: false }) })
    expect(lineIssue(fits, [fits])).toBeNull()
    const tooLong = line(cableBundle, 'b', { qtyText: '7', position: roll({ id: 'p60', qtyBase: '60', sealed: false }) })
    expect(lineIssue(tooLong, [tooLong])).toContain('tidak bisa disambung')
  })
  it('roll yang dijual utuh tidak boleh dipotong di baris lain', () => {
    const whole = line(cableRoll, 'a', { position: roll({}) })
    const cut = line(cableMeter, 'b', { qtyText: '2', position: roll({}) })
    expect(lineIssue(cut, [whole, cut])).toContain('dijual utuh')
  })
})

describe('payload ke server', () => {
  const ready = [
    line(lamp, 'a', { qtyText: '2', discountMode: 'amount', discountText: '1.000' }),
    line(cableMeter, 'b', { qtyText: '2,5', position: roll({ id: 'r9', sealed: false, qtyBase: '50', version: 4 }) }),
  ]
  it('STAFF tidak pernah mengirim field diskon (bukti audit K02)', () => {
    const input = buildSaleInput({ lines: ready, canDiscount: false, invoiceDiscount: { mode: 'percent', text: '100' }, customerId: null, clientReferenceId: 'c1' })
    expect(JSON.stringify(input)).not.toContain('discount')
  })
  it('pemilik mengirim diskon kanonik, roll mengirim posisi & versinya', () => {
    const input = buildSaleInput({ lines: ready, canDiscount: true, invoiceDiscount: { mode: 'percent', text: '5' }, customerId: 'cust', clientReferenceId: 'c1' })
    expect(input).toEqual({
      client_reference_id: 'c1', customer_id: 'cust', discount_mode: 'percent', discount_value: '5',
      items: [
        { product_unit_id: 'u-lamp', qty: '2', expected_unit_version: 1, discount_mode: 'amount', discount_value: '1000' },
        { product_unit_id: 'u-m', qty: '2.5', expected_unit_version: 1, position_id: 'r9', expected_position_version: 4 },
      ],
    })
  })
  it('keranjang bermasalah tidak menghasilkan payload', () => {
    expect(buildSaleInput({ lines: [line(lamp, 'a', { qtyText: '' })], canDiscount: false, invoiceDiscount: NO_DISCOUNT, customerId: null, clientReferenceId: 'c' })).toBeNull()
  })
})

describe('PRICE_CHANGED', () => {
  const product = (units: ProductDetail['units'], active = true): ProductDetail => ({
    id: 'p-lamp', name: 'Lampu LED 12W', specification: '', base_unit: 'pcs', quantity_step: '1', track_segments: false, active, units,
  })
  const unit = (patch: Partial<ProductDetail['units'][number]>) => ({
    id: 'u-lamp', label: 'pcs', factor_base: '1', sale_step: '1', sell_price: '18000', is_default: true, whole_roll: false, version: 1, active: true, ...patch,
  }) as ProductDetail['units'][number]

  it('baris memakai satuan baru dan menandai harga lama untuk diperiksa', () => {
    const lines = applyProductRefresh([line(lamp, 'a')], [product([unit({ active: false }), unit({ id: 'u-new', sell_price: '20000', version: 1 })])])
    expect(lines[0].unitId).toBe('u-new')
    expect(lines[0].sellPrice).toBe('20000')
    expect(lines[0].priceChange).toEqual({ previousPrice: '18000', previousLabel: 'pcs' })
  })
  it('produk diarsip ditandai tidak tersedia', () => {
    const lines = applyProductRefresh([line(lamp, 'a')], [product([unit({})], false)])
    expect(lines[0].unavailable).toBe(true)
    expect(lineIssue(lines[0], lines)).toContain('tidak dijual')
  })
})

describe('uang tunai & draf', () => {
  it('nominal cepat selalu di atas total', () => {
    expect(quickCashOptions('37500')).toEqual(['40000', '50000', '100000'])
    expect(quickCashOptions('50000')).toEqual(['55000', '60000', '100000'])
  })
  it('draf yang disimpan dapat dibaca ulang; draf rusak ditolak', () => {
    const content = { kind: 'sale-cart', lines: [line(lamp, 'a')], invoiceDiscount: NO_DISCOUNT, customer: null, paymentMethod: 'QRIS', clientReferenceId: 'c1' }
    expect(parseCartDraft(JSON.parse(JSON.stringify(content)))?.paymentMethod).toBe('QRIS')
    expect(parseCartDraft({ kind: 'sale-cart', lines: [{ key: 1 }] })).toBeNull()
    expect(parseCartDraft({ cart: [] })).toBeNull()
  })
  it('label draf mudah dikenali', () => {
    expect(draftLabel([line(lamp, 'a', { qtyText: '2' }), line(cableMeter, 'b')], { id: 'c', name: 'Budi', phone: null }))
      .toBe('Lampu LED 12W 2 pcs + 1 barang lain (Budi)')
  })
})
