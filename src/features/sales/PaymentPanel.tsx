import { Link } from 'react-router-dom'
import Decimal from 'decimal.js'
import {
  Card, Checkbox, ChoiceGroup, ErrorMessage, Notice, RupiahInput, SummaryRow, TextArea, TextInput,
} from '../../components/ui'
import { formatRupiah } from '../../lib/numbers'
import { quickCashOptions } from './cart'
import type { PreviewState } from './hooks'
import type { PaymentForm } from './payment'
import type { PaymentMethod, SalePreview } from './types'

const METHOD_OPTIONS: { value: PaymentMethod; label: string; description: string }[] = [
  { value: 'CASH', label: 'Tunai', description: 'Uang masuk laci' },
  { value: 'TRANSFER', label: 'Transfer', description: 'Ke rekening toko' },
  { value: 'QRIS', label: 'QRIS', description: 'Scan kode QR' },
]

type Props = {
  preview: PreviewState
  form: PaymentForm
  onFormChange: (patch: Partial<PaymentForm>) => void
  canDiscount: boolean
  drawerClosed: boolean
  blocker: string | null
  busy: boolean
  unknownResult: boolean
  error: unknown
  onPay: () => void
  onRetryPreview: () => void
}

/** Ringkasan total dari server, metode bayar, dan tombol Bayar. */
export function PaymentPanel(props: Props) {
  const { preview, form, onFormChange, drawerClosed, blocker, busy, unknownResult } = props
  const data: SalePreview | null = preview.status === 'ready' ? preview.data
    : preview.status === 'loading' ? preview.last : null
  const stale = preview.status !== 'ready'
  const free = preview.status === 'ready' && preview.data.requires_owner_reason
  const total = preview.status === 'ready' ? preview.data.total : null

  return (
    <Card title="Pembayaran">
      <div className={`sl-summary${stale ? ' is-stale' : ''}`} aria-live="polite">
        <SummaryRow label="Subtotal" value={data ? formatRupiah(data.subtotal) : '-'} />
        {data && new Decimal(data.discount).greaterThan(0) && (
          <SummaryRow label="Diskon nota" value={`−${formatRupiah(data.discount)}`} />
        )}
        <SummaryRow strong label="Total bayar" value={<span className="sl-money">{data ? formatRupiah(data.total) : '-'}</span>} />
        {preview.status === 'loading' && <p className="sl-muted">Menghitung total dari sistem…</p>}
      </div>
      {preview.status === 'error' && (
        <>
          <ErrorMessage error={preview.error} />
          <button type="button" className="ui-button ui-button-secondary" onClick={props.onRetryPreview}>
            Hitung ulang total
          </button>
        </>
      )}

      {free ? (
        <>
          <Notice tone="warning">Total nota Rp0. Hanya pemilik yang boleh memproses, dan alasan wajib diisi.</Notice>
          {props.canDiscount && (
            <TextArea label="Alasan nota Rp0" value={form.freeReason} maxLength={500}
              onChange={freeReason => onFormChange({ freeReason })} placeholder="Contoh: hadiah untuk pelanggan tetap" />
          )}
        </>
      ) : (
        <>
          <ChoiceGroup label="Cara bayar" value={form.method} options={METHOD_OPTIONS}
            onChange={method => onFormChange({ method, confirmedTotal: null })} />
          {form.method === 'CASH'
            ? <CashFields form={form} total={data?.total ?? null} change={preview.status === 'ready' ? preview.data.change : null}
                drawerClosed={drawerClosed} onFormChange={onFormChange} />
            : <NonCashFields form={form} total={total} onFormChange={onFormChange} />}
        </>
      )}

      {unknownResult && (
        <Notice tone="warning">
          <strong>Hasil pembayaran belum diketahui.</strong> Jangan buat transaksi baru. Tekan Bayar lagi saat koneksi
          pulih; sistem memeriksa agar tidak tercatat dua kali.
        </Notice>
      )}
      <ErrorMessage error={props.error} />

      <button type="button" className="ui-button ui-button-primary ui-button-large sl-pay"
        disabled={blocker !== null || busy} onClick={props.onPay} aria-describedby="sl-pay-blocker">
        {busy ? 'Menyimpan pembayaran…'
          : unknownResult ? 'Bayar lagi (periksa status)'
            : total ? `Bayar ${formatRupiah(total)}` : 'Bayar'}
      </button>
      {blocker && !busy && <p id="sl-pay-blocker" className="sl-blocker">{blocker}</p>}
    </Card>
  )
}

function CashFields({ form, total, change, drawerClosed, onFormChange }: {
  form: PaymentForm
  total: string | null
  change: string | null
  drawerClosed: boolean
  onFormChange: (patch: Partial<PaymentForm>) => void
}) {
  return (
    <div className="sl-cash">
      {drawerClosed && (
        <Notice tone="warning">
          Laci kas toko belum dibuka, jadi pembayaran tunai belum bisa dicatat.{' '}
          <Link to="/kas">Buka kas di menu Kas Laci</Link>, atau pilih Transfer/QRIS.
        </Notice>
      )}
      <RupiahInput label="Uang diterima dari pembeli" value={form.tenderedText}
        onChange={tenderedText => onFormChange({ tenderedText })} placeholder="Contoh: 50.000" />
      {total && (
        <div className="sl-quick" role="group" aria-label="Nominal cepat">
          <button type="button" className="ui-button ui-button-secondary"
            onClick={() => onFormChange({ tenderedText: total })}>Uang pas</button>
          {quickCashOptions(total).map(option => (
            <button key={option} type="button" className="ui-button ui-button-secondary"
              onClick={() => onFormChange({ tenderedText: option })}>{formatRupiah(option)}</button>
          ))}
        </div>
      )}
      {change !== null && (
        <div className="sl-change" aria-live="polite">
          <span>Kembalian</span>
          <strong className="sl-money">{formatRupiah(change)}</strong>
        </div>
      )}
    </div>
  )
}

function NonCashFields({ form, total, onFormChange }: {
  form: PaymentForm
  total: string | null
  onFormChange: (patch: Partial<PaymentForm>) => void
}) {
  const confirmed = total !== null && form.confirmedTotal === total
  return (
    <div className="sl-noncash">
      <p>
        Periksa HP/rekening toko: pastikan uang {total ? <strong>{formatRupiah(total)}</strong> : 'sesuai total'} sudah
        benar-benar masuk sebelum menekan Bayar.
      </p>
      <Checkbox label="Saya sudah memastikan uang masuk" checked={confirmed} disabled={total === null}
        onChange={checked => onFormChange({ confirmedTotal: checked ? total : null })} />
      <TextInput label="Catatan / nomor referensi (boleh kosong)" value={form.reference} maxLength={100}
        onChange={reference => onFormChange({ reference })} />
    </div>
  )
}
