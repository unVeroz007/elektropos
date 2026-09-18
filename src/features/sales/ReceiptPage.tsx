import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Badge, ErrorMessage, Loading, Notice } from '../../components/ui'
import { formatDateTime, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import { getInvoice, getShopSettings } from './api'
import { paymentLabel, paymentStatus } from './labels'
import {
  isPositive, itemDiscount, itemFormula, itemName, receiptColumns, receiptPayments, receiptText,
} from './receipt'
import type { Invoice, ShopSettings } from './types'
import './sales.css'

/** Struk nota (FR-POS-03, S08): cetak 58/80 mm, salin teks, retur untuk pemilik. */
export function ReceiptPage() {
  const { invoiceId = '' } = useParams<{ invoiceId: string }>()
  const profile = useProfile()
  const invoice = useQuery({ queryKey: ['sales', 'invoice', invoiceId], queryFn: () => getInvoice(invoiceId), enabled: invoiceId !== '' })
  const shop = useQuery({ queryKey: ['sales', 'shop-settings'], queryFn: getShopSettings, staleTime: 300_000 })
  const [copied, setCopied] = useState<'ok' | 'failed' | null>(null)

  if (!invoiceId) return <Notice tone="warning">Nomor nota tidak ada di alamat halaman.</Notice>
  if (invoice.isPending) return <Loading label="Memuat struk…" />
  if (invoice.isError) {
    return (
      <div className="sl-page">
        <ErrorMessage error={invoice.error} />
        <button type="button" className="ui-button ui-button-secondary" onClick={() => { void invoice.refetch() }}>
          Coba lagi
        </button>
      </div>
    )
  }

  const data = invoice.data
  const settings = shop.data ?? null
  const width = settings?.receipt_width === 80 ? 80 : 58
  const canReturn = permissions.processReturn(profile) && data.kind === 'SALE'
    && data.items.some(i => isPositive(i.returnable_qty))

  async function copyText() {
    try {
      await navigator.clipboard.writeText(receiptText(data, settings, receiptColumns(width)))
      setCopied('ok')
    } catch {
      setCopied('failed') // izin clipboard ditolak browser; pesan ditampilkan
    }
  }

  return (
    <div className="sl-page sl-receipt-page">
      <div className="sl-receipt-actions">
        <button type="button" className="ui-button ui-button-primary" onClick={() => window.print()}>Cetak struk</button>
        <button type="button" className="ui-button ui-button-secondary" onClick={() => { void copyText() }}>
          Salin teks struk
        </button>
        {canReturn && (
          <Link className="ui-button ui-button-secondary" to={`/retur/${data.id}`}>Retur barang</Link>
        )}
        <Link className="ui-button ui-button-secondary" to="/kasir">Transaksi baru</Link>
        <Link className="ui-button ui-button-secondary" to="/riwayat">Riwayat nota</Link>
      </div>
      {copied === 'ok' && <Notice tone="success">Teks struk tersalin. Tempel di WhatsApp atau catatan.</Notice>}
      {copied === 'failed' && <ErrorMessage error="Teks struk tidak dapat disalin di browser ini. Gunakan tombol Cetak." />}
      <ReceiptBody invoice={data} shop={settings} width={width} />
    </div>
  )
}

function ReceiptBody({ invoice, shop, width }: { invoice: Invoice; shop: ShopSettings | null; width: 58 | 80 }) {
  const status = paymentStatus(invoice.money.payment_status)
  return (
    <article className="sl-receipt" data-width={width} aria-label={`Struk ${invoice.number}`}>
      <header className="sl-receipt-head">
        <h1>{shop?.name || 'Nama toko belum diisi'}</h1>
        {shop?.address && <p>{shop.address}</p>}
        {shop?.phone && <p>Telp {shop.phone}</p>}
      </header>
      <dl className="sl-receipt-meta">
        <div><dt>Nota</dt><dd>{invoice.number}</dd></div>
        <div><dt>Waktu</dt><dd>{formatDateTime(invoice.posted_at)}</dd></div>
        {invoice.cashier_name && <div><dt>Petugas</dt><dd>{invoice.cashier_name}</dd></div>}
        {invoice.customer && <div><dt>Pelanggan</dt><dd>{invoice.customer.name}</dd></div>}
      </dl>

      <ul className="sl-receipt-items">
        {invoice.items.map(item => {
          const discount = itemDiscount(item)
          return (
            <li key={item.id}>
              <span className="sl-receipt-name">{itemName(item)}</span>
              <span className="sl-receipt-row"><span>{itemFormula(item)}</span><span>{formatRupiah(item.base_net)}</span></span>
              {discount && (
                <span className="sl-receipt-row"><span>Diskon barang</span><span>−{formatRupiah(discount)}</span></span>
              )}
            </li>
          )
        })}
      </ul>

      <div className="sl-receipt-totals">
        <p className="sl-receipt-row"><span>Subtotal</span><span>{formatRupiah(invoice.subtotal_net_lines)}</span></p>
        {isPositive(invoice.discount_total) && (
          <p className="sl-receipt-row"><span>Diskon nota</span><span>−{formatRupiah(invoice.discount_total)}</span></p>
        )}
        <p className="sl-receipt-row sl-receipt-total"><span>Total</span><span>{formatRupiah(invoice.total)}</span></p>
        {invoice.free_reason && <p>Keterangan: {invoice.free_reason}</p>}
        {receiptPayments(invoice).map(p => (
          <div key={p.id}>
            <p className="sl-receipt-row">
              <span>Dibayar ({paymentLabel(p.method)})</span><span>{formatRupiah(p.tendered ?? p.amount)}</span>
            </p>
            {p.method === 'CASH' && p.change !== null && (
              <p className="sl-receipt-row"><span>Kembalian</span><span>{formatRupiah(p.change)}</span></p>
            )}
            {p.reference && <p className="sl-receipt-small">Ref: {p.reference}</p>}
          </div>
        ))}
      </div>

      {invoice.credits.length > 0 && (
        <div className="sl-receipt-credits">
          {invoice.credits.map(credit => (
            <div key={credit.id}>
              <p className="sl-receipt-row"><span>Retur {credit.number}</span><span>−{formatRupiah(credit.total)}</span></p>
              <p className="sl-receipt-small">{formatDateTime(credit.posted_at)}{credit.reason ? ` · ${credit.reason}` : ''}</p>
              {credit.refunds.map(r => (
                <p key={r.payment_id} className="sl-receipt-row">
                  <span>Uang kembali ({paymentLabel(r.method)})</span><span>{formatRupiah(r.amount)}</span>
                </p>
              ))}
            </div>
          ))}
        </div>
      )}
      <p className="sl-receipt-status">Status: <Badge tone={status.tone}>{status.label}</Badge></p>
      <p className="sl-receipt-thanks">Terima kasih</p>
    </article>
  )
}
