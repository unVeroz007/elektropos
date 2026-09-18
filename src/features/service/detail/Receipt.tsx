import { useEffect, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { SummaryRow } from '../../../components/ui'
import { formatDateTime, formatRupiah } from '../../../lib/numbers'
import { getShopSettings, serviceKeys } from '../api'
import { Button } from '../common'
import { CASHBOX, METHOD } from '../labels'
import { isPositive } from '../logic'
import type { Cashbox, PayMethod, PaymentState } from '../types'

export type ReceiptData = {
  ticketNumber: string
  customerName: string | null
  equipment: string
  purpose: 'DEPOSIT' | 'SETTLEMENT'
  method: PayMethod
  cashbox: Cashbox | null
  amount: string
  tendered: string | null
  change: string | null
  occurredAt: string
  actorName: string | null
  /** Keadaan tagihan tepat setelah pembayaran ini (dari server). */
  payment: PaymentState
  /** Cetak ulang: sisa/total mengikuti keadaan saat dicetak, bukan saat bayar. */
  reprint?: boolean
}

/**
 * Kuitansi DP/pelunasan (BR-10): tiket, nilai diterima, total final bila ada,
 * sisa/kelebihan, metode, petugas, waktu. Dicetak lewat dialog agar hanya
 * kuitansi yang ikut tercetak.
 */
export function ReceiptDialog({ receipt, onClose }: { receipt: ReceiptData; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null)
  const shop = useQuery({ queryKey: serviceKeys.shop, queryFn: getShopSettings, staleTime: 5 * 60_000 })
  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
  }, [])
  const final = receipt.payment.invoice_id !== null

  return (
    <dialog ref={ref} className="ui-dialog srv-receipt-dialog" aria-label="Kuitansi pembayaran servis"
      onCancel={event => { event.preventDefault(); onClose() }}>
      <div className="srv-receipt">
        <header>
          <strong>{shop.data?.name ?? 'Kuitansi servis'}</strong>
          {shop.data?.address && <span>{shop.data.address}</span>}
          {shop.data?.phone && <span>Telp. {shop.data.phone}</span>}
        </header>
        <h2>{receipt.purpose === 'DEPOSIT' ? 'Kuitansi uang muka' : 'Kuitansi pelunasan'}</h2>
        <SummaryRow label="Tiket" value={receipt.ticketNumber} />
        {receipt.customerName && <SummaryRow label="Pelanggan" value={receipt.customerName} />}
        <SummaryRow label="Alat" value={receipt.equipment} />
        <SummaryRow label="Waktu" value={formatDateTime(receipt.occurredAt)} />
        <SummaryRow label="Metode" value={`${METHOD[receipt.method]}${receipt.cashbox ? ` (${CASHBOX[receipt.cashbox]})` : ''}`} />
        <SummaryRow strong label="Diterima" value={formatRupiah(receipt.amount)} />
        {receipt.method === 'CASH' && receipt.tendered && (
          <>
            <SummaryRow label="Uang dibayarkan" value={formatRupiah(receipt.tendered)} />
            <SummaryRow label="Kembalian" value={formatRupiah(receipt.change ?? '0')} />
          </>
        )}
        {final ? (
          <>
            <SummaryRow label="Total tagihan final" value={formatRupiah(receipt.payment.invoice_net)} />
            <SummaryRow label="Total sudah dibayar" value={formatRupiah(receipt.payment.net_received)} />
            <SummaryRow strong label="Sisa" value={formatRupiah(receipt.payment.outstanding)} />
            {isPositive(receipt.payment.refund_due) && (
              <SummaryRow label="Kelebihan bayar (dikembalikan)" value={formatRupiah(receipt.payment.refund_due)} />
            )}
          </>
        ) : (
          <>
            <SummaryRow label="Total uang muka" value={formatRupiah(receipt.payment.net_received)} />
            <SummaryRow label="Total tagihan" value="Belum ditentukan" />
          </>
        )}
        <SummaryRow label="Petugas" value={receipt.actorName ?? '-'} />
        {receipt.reprint && <p className="srv-muted">Cetak ulang. Total dan sisa sesuai keadaan saat dicetak.</p>}
      </div>
      <div className="ui-dialog-actions srv-no-print">
        <Button variant="secondary" onClick={onClose}>Tutup</Button>
        <Button onClick={() => window.print()}>Cetak kuitansi</Button>
      </div>
    </dialog>
  )
}
