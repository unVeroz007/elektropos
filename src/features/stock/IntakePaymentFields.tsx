import type Decimal from 'decimal.js'
import { formatRupiah } from '../../lib/numbers'
import { Checkbox, ChoiceGroup, Notice, TextInput } from '../../components/ui'
import { CASHBOX_LABEL, PAYMENT_METHOD_LABEL } from '../../components/labels'
import { useCashSession } from '../cash/api'
import type { Supplier } from '../suppliers/api'
import type { IntakePayment, PaymentMethod } from './intakeModel'

function CashboxStatus({ payment, total }: { payment: IntakePayment; total: Decimal }) {
  const session = useCashSession(payment.cashbox)
  if (!session.data) return null
  if (!session.data.open) {
    return <Notice tone="warning">{CASHBOX_LABEL[payment.cashbox]} belum dibuka. Buka kas di menu Kas sebelum membayar tunai.</Notice>
  }
  const short = total.greaterThan(session.data.expected)
  return (
    <Notice tone={short ? 'warning' : 'info'}>
      Saldo {CASHBOX_LABEL[payment.cashbox]} menurut sistem: {formatRupiah(session.data.expected)}.
      {short && ' Tidak cukup untuk pembayaran ini. Tambah uang atau pindahkan dari kas lain dulu.'}
    </Notice>
  )
}

/** Cara bayar pembelian (D3, T02). Konfirmasi non-tunai WAJIB dicentang pengguna sendiri. */
export function IntakePaymentFields({ payment, onChange, total, supplier }: {
  payment: IntakePayment
  onChange: (next: IntakePayment) => void
  total: Decimal
  supplier: Supplier | null
}) {
  const set = (patch: Partial<IntakePayment>) => onChange({ ...payment, ...patch })
  const methods: { value: PaymentMethod; label: string; description?: string }[] = [
    { value: 'CASH', label: PAYMENT_METHOD_LABEL.CASH, description: 'Uang diambil dari kas' },
    { value: 'TRANSFER', label: PAYMENT_METHOD_LABEL.TRANSFER },
    { value: 'QRIS', label: PAYMENT_METHOD_LABEL.QRIS },
  ]
  if (supplier) {
    methods.push({ value: 'SUPPLIER_CREDIT', label: 'Saldo kredit distributor', description: `Saldo ${formatRupiah(supplier.credit_balance)}` })
  }

  return (
    <div>
      <ChoiceGroup label="Cara bayar ke distributor" value={payment.method}
        onChange={method => set({ method, confirmed: false })} options={methods} />
      {payment.method === 'CASH' && (
        <>
          <ChoiceGroup label="Uang diambil dari" value={payment.cashbox} onChange={cashbox => set({ cashbox })}
            options={[
              { value: 'SHOP_DRAWER', label: CASHBOX_LABEL.SHOP_DRAWER },
              { value: 'FATHER_WALLET', label: CASHBOX_LABEL.FATHER_WALLET },
            ]} />
          <CashboxStatus payment={payment} total={total} />
        </>
      )}
      {(payment.method === 'TRANSFER' || payment.method === 'QRIS') && (
        <>
          <TextInput label="Nomor bukti/referensi (boleh kosong)" value={payment.reference}
            onChange={reference => set({ reference })} maxLength={100} />
          <Checkbox checked={payment.confirmed} onChange={confirmed => set({ confirmed })}
            label={`Saya sudah memastikan pembayaran ${formatRupiah(total)} lewat ${PAYMENT_METHOD_LABEL[payment.method]} ke distributor berhasil`} />
        </>
      )}
      {payment.method === 'SUPPLIER_CREDIT' && supplier && (
        <Notice tone="info">Saldo kredit {supplier.name}: {formatRupiah(supplier.credit_balance)}. Dipotong {formatRupiah(total)}.</Notice>
      )}
    </div>
  )
}
