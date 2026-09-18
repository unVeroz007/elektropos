import { useState } from 'react'
import Decimal from 'decimal.js'
import { Badge, QuantityInput, RupiahInput, Select, TextInput } from '../../components/ui'
import { formatQuantity, formatRupiah, parseQuantity } from '../../lib/numbers'
import {
  isWholeRoll, lineBaseQty, lineFormula, stepQty, usesStepper, type CartLine,
} from './cart'
import { RollPicker } from './RollPicker'
import type { DiscountMode, PreviewLine } from './types'

type Props = {
  line: CartLine
  lines: CartLine[]
  issue: string | null
  preview: PreviewLine | null
  canDiscount: boolean
  onChange: (patch: Partial<CartLine>) => void
  onRemove: () => void
}

function qtyParses(text: string): boolean {
  try {
    parseQuantity(text)
    return true
  } catch {
    return false // pesan sudah ditampilkan oleh QuantityInput
  }
}

/** Satu baris keranjang: jumlah, roll, diskon (pemilik) dan nilai dari server. */
export function CartLineRow({ line, lines, issue, preview, canDiscount, onChange, onRemove }: Props) {
  const [changingRoll, setChangingRoll] = useState(false)
  const whole = isWholeRoll(line)
  const showPicker = line.trackSegments && (!line.position || changingRoll)
  // Kesalahan format angka sudah tampil di bawah kolom jumlah; jangan diulang.
  const visibleIssue = issue && (line.qtyText.trim() === '' || qtyParses(line.qtyText)) ? issue : null
  const base = lineBaseQty(line)
  const lowStock = preview && base && !line.trackSegments && base.greaterThan(preview.available_base)

  return (
    <li className={`sl-line${issue ? ' has-issue' : ''}${line.priceChange ? ' has-change' : ''}`}>
      <div className="sl-line-head">
        <div>
          <strong className="sl-line-name">{line.productName}</strong>
          {line.specification && <span className="sl-line-spec">{line.specification}</span>}
        </div>
        <button type="button" className="ui-button ui-button-secondary sl-remove" onClick={onRemove}
          aria-label={`Hapus ${line.productName} dari keranjang`}>
          Hapus
        </button>
      </div>

      <p className="sl-line-formula">{lineFormula(line, formatRupiah)}</p>
      {line.priceChange && (
        <p className="sl-line-change">
          <Badge tone="warning">Harga berubah</Badge>{' '}
          Sebelumnya {formatRupiah(line.priceChange.previousPrice)}/{line.priceChange.previousLabel},
          sekarang {formatRupiah(line.sellPrice)}/{line.unitLabel}.
        </p>
      )}

      {whole ? (
        <p className="sl-line-whole">1 roll utuh ({formatQuantity(line.factorBase, line.baseUnit)})</p>
      ) : (
        <div className="sl-qty">
          {usesStepper(line) && (
            <button type="button" className="ui-button ui-button-secondary sl-step"
              aria-label={`Kurangi jumlah ${line.productName}`}
              onClick={() => onChange({ qtyText: stepQty(line, -1) })}>−</button>
          )}
          <QuantityInput label="Jumlah" unit={line.unitLabel} value={line.qtyText}
            onChange={qtyText => onChange({ qtyText })}
            hint={base && !new Decimal(line.factorBase).equals(1) ? `= ${formatQuantity(base, line.baseUnit)}` : undefined} />
          {usesStepper(line) && (
            <button type="button" className="ui-button ui-button-secondary sl-step"
              aria-label={`Tambah jumlah ${line.productName}`}
              onClick={() => onChange({ qtyText: stepQty(line, 1) })}>+</button>
          )}
        </div>
      )}

      {line.trackSegments && line.position && !changingRoll && (
        <div className="sl-roll-chosen">
          <span>
            Diambil dari roll <strong>{line.position.label ?? 'tanpa label'}</strong>
            {' '}(sisa {formatQuantity(line.position.qtyBase, line.baseUnit)})
          </span>
          <button type="button" className="ui-button ui-button-secondary" onClick={() => setChangingRoll(true)}>
            Ganti roll
          </button>
        </div>
      )}
      {showPicker && (
        <RollPicker line={line} lines={lines}
          onPick={position => { onChange({ position }); setChangingRoll(false) }}
          onCancel={line.position ? () => setChangingRoll(false) : undefined} />
      )}

      {canDiscount && <LineDiscount line={line} onChange={onChange} />}

      {visibleIssue && <p className="sl-line-issue" role="alert">{visibleIssue}</p>}
      {lowStock && (
        <p className="sl-line-warning">
          Stok toko tercatat tinggal {formatQuantity(preview.available_base, line.baseUnit)}. Periksa rak sebelum bayar.
        </p>
      )}

      <div className="sl-line-total">
        {preview ? (
          <>
            {new Decimal(preview.line_discount).greaterThan(0) && (
              <span>Diskon baris −{formatRupiah(preview.line_discount)}</span>
            )}
            <strong>{formatRupiah(preview.base_net)}</strong>
          </>
        ) : <span className="sl-muted">{issue ? 'Belum dapat dihitung' : 'Menghitung…'}</span>}
      </div>
    </li>
  )
}

function LineDiscount({ line, onChange }: { line: CartLine; onChange: (patch: Partial<CartLine>) => void }) {
  const mode: '' | DiscountMode = line.discountMode ?? ''
  return (
    <div className="sl-discount">
      <Select<'' | DiscountMode> label="Diskon barang ini" value={mode}
        onChange={value => onChange({ discountMode: value || null, discountText: '' })}
        options={[
          { value: '', label: 'Tanpa diskon' },
          { value: 'percent', label: 'Persen (%)' },
          { value: 'amount', label: 'Potongan Rupiah' },
        ]} />
      {mode === 'percent' && (
        <TextInput label="Besar diskon (%)" value={line.discountText} onChange={discountText => onChange({ discountText })}
          placeholder="Contoh: 10" />
      )}
      {mode === 'amount' && (
        <RupiahInput label="Potongan untuk baris ini" value={line.discountText}
          onChange={discountText => onChange({ discountText })} />
      )}
    </div>
  )
}
