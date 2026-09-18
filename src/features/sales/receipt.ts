import Decimal from 'decimal.js'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { paymentLabel, paymentStatus } from './labels'
import type { Invoice, InvoiceItem, InvoicePayment, ShopSettings } from './types'

/** Isi struk (FR-POS-03, S08) sebagai data tampilan dan teks polos yang dapat disalin. */

/** Lebar karakter teks struk: 32 kolom untuk kertas 58 mm, 48 kolom untuk 80 mm. */
export function receiptColumns(width: number | null | undefined): number {
  return width === 80 ? 48 : 32
}

export function isPositive(value: string | null | undefined): boolean {
  return value !== null && value !== undefined && value !== '' && new Decimal(value).greaterThan(0)
}

/** Nama barang tanpa akhiran "(satuan)" yang sudah ditulis server di deskripsi. */
export function itemName(item: InvoiceItem): string {
  const suffix = item.unit_label ? ` (${item.unit_label})` : ''
  return suffix && item.description.endsWith(suffix) ? item.description.slice(0, -suffix.length) : item.description
}

/** "2 pcs × Rp15.000" */
export function itemFormula(item: InvoiceItem): string {
  const unit = item.unit_label ?? ''
  return `${formatQuantity(item.qty_sell, unit || undefined)} × ${formatRupiah(item.unit_price)}${unit ? `/${unit}` : ''}`
}

export function itemDiscount(item: InvoiceItem): string | null {
  return isPositive(item.line_discount) ? item.line_discount : null
}

/** Penerimaan uang pelanggan (bukan refund/koreksi) untuk bagian pembayaran struk. */
export function receiptPayments(invoice: Invoice): InvoicePayment[] {
  return invoice.payments.filter(p => p.direction === 'IN' && p.purpose !== 'PAYMENT_REPLACEMENT'
    && p.purpose !== 'PAYMENT_REVERSAL')
}

function pad(left: string, right: string, columns: number): string {
  const space = columns - left.length - right.length
  return space >= 1 ? `${left}${' '.repeat(space)}${right}` : `${left}\n${' '.repeat(Math.max(0, columns - right.length))}${right}`
}

function center(text: string, columns: number): string {
  if (text.length >= columns) return text
  return `${' '.repeat(Math.floor((columns - text.length) / 2))}${text}`
}

function wrap(text: string, columns: number): string[] {
  const words = text.split(/\s+/).filter(Boolean)
  const out: string[] = []
  let line = ''
  for (const word of words) {
    if (line && `${line} ${word}`.length > columns) {
      out.push(line)
      line = word
    } else {
      line = line ? `${line} ${word}` : word
    }
  }
  if (line) out.push(line)
  return out
}

/** Teks struk polos (untuk tombol "Salin teks struk", mis. dikirim lewat WhatsApp). */
export function receiptText(invoice: Invoice, shop: ShopSettings | null, columns = 32): string {
  const rule = '-'.repeat(columns)
  const out: string[] = []
  if (shop?.name) out.push(...wrap(shop.name, columns).map(l => center(l, columns)))
  if (shop?.address) out.push(...wrap(shop.address, columns).map(l => center(l, columns)))
  if (shop?.phone) out.push(center(`Telp ${shop.phone}`, columns))
  out.push(rule)
  out.push(`Nota  : ${invoice.number}`)
  out.push(`Waktu : ${formatDateTime(invoice.posted_at)}`)
  if (invoice.cashier_name) out.push(`Kasir : ${invoice.cashier_name}`)
  if (invoice.customer) out.push(`Pelanggan: ${invoice.customer.name}`)
  out.push(rule)
  for (const item of invoice.items) {
    out.push(...wrap(itemName(item), columns))
    out.push(pad(`  ${itemFormula(item)}`, formatRupiah(item.base_net), columns))
    const discount = itemDiscount(item)
    if (discount) out.push(pad('  Diskon barang', `-${formatRupiah(discount)}`, columns))
  }
  out.push(rule)
  out.push(pad('Subtotal', formatRupiah(invoice.subtotal_net_lines), columns))
  if (isPositive(invoice.discount_total)) out.push(pad('Diskon nota', `-${formatRupiah(invoice.discount_total)}`, columns))
  out.push(pad('TOTAL', formatRupiah(invoice.total), columns))
  if (invoice.free_reason) out.push(...wrap(`Keterangan: ${invoice.free_reason}`, columns))
  for (const p of receiptPayments(invoice)) {
    out.push(pad(`Bayar (${paymentLabel(p.method)})`, formatRupiah(p.tendered ?? p.amount), columns))
    if (p.method === 'CASH' && p.change !== null) out.push(pad('Kembalian', formatRupiah(p.change), columns))
  }
  for (const credit of invoice.credits) {
    out.push(rule)
    out.push(pad(`Retur ${credit.number}`, `-${formatRupiah(credit.total)}`, columns))
    for (const r of credit.refunds) {
      out.push(pad(`  Uang kembali (${paymentLabel(r.method)})`, formatRupiah(r.amount), columns))
    }
  }
  if (invoice.credits.length > 0 || invoice.money.payment_status !== 'PAID') {
    out.push(pad('Status', paymentStatus(invoice.money.payment_status).label, columns))
  }
  out.push(rule)
  out.push(center('Terima kasih', columns))
  return out.join('\n')
}
