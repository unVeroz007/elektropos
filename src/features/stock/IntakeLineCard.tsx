import { formatQuantity } from '../../lib/numbers'
import { Card, Checkbox, QuantityInput, RupiahInput, Select, TextInput } from '../../components/ui'
import {
  lineBaseQty, rollLabelsPreview, rollTotal, withAutoRolls, type IntakeLine, type ManualPosition,
} from './intakeModel'

type Unit = { id: string; label: string; factor_base: string }

function PositionRow({ position, baseUnit, onChange, onRemove }: {
  position: ManualPosition
  baseUnit: string
  onChange: (patch: Partial<ManualPosition>) => void
  onRemove: () => void
}) {
  return (
    <div className="sub-card">
      <div className="form-grid">
        <TextInput label="Label potongan" value={position.label} onChange={label => onChange({ label })} maxLength={40}
          placeholder="Contoh: SISA-1" />
        <QuantityInput label="Panjang" unit={baseUnit} value={position.length} onChange={length => onChange({ length })} />
        <QuantityInput label="Panjang roll asal (boleh kosong)" unit={baseUnit} value={position.capacity}
          onChange={capacity => onChange({ capacity })} />
      </div>
      <Checkbox label="Masih segel utuh" checked={position.sealed} onChange={sealed => onChange({ sealed })} />
      <button type="button" className="ui-button ui-button-secondary" onClick={onRemove}>Hapus potongan ini</button>
    </div>
  )
}

function RollSection({ line, onChange }: { line: IntakeLine; onChange: (next: IntakeLine) => void }) {
  const base = lineBaseQty(line)
  const total = rollTotal(line)
  const matches = base !== null && total.equals(base)
  const manual = (patch: Partial<IntakeLine>) => onChange({ ...line, ...patch, rollsAuto: false })
  const updatePosition = (key: string, patch: Partial<ManualPosition>) =>
    manual({ positions: line.positions.map(p => p.key === key ? { ...p, ...patch } : p) })
  const labels = rollLabelsPreview(line)

  return (
    <fieldset className="roll-section">
      <legend>Pembagian per roll</legend>
      <p className="muted">Setiap roll fisik menjadi satu posisi berlabel agar bisa dipilih saat menjual (BR-03).</p>
      <div className="form-grid">
        <QuantityInput label="Jumlah roll utuh" unit="roll" value={line.rollCount} onChange={rollCount => manual({ rollCount })} />
        <QuantityInput label="Panjang per roll" unit={line.baseUnit} value={line.rollCapacity}
          onChange={rollCapacity => manual({ rollCapacity })} />
        <TextInput label="Awalan label (boleh kosong)" hint="Kosong = label dibuat otomatis" value={line.labelPrefix}
          onChange={labelPrefix => manual({ labelPrefix })} maxLength={30} placeholder="Contoh: NYA-A" />
      </div>
      {line.positions.map(p => (
        <PositionRow key={p.key} position={p} baseUnit={line.baseUnit} onChange={patch => updatePosition(p.key, patch)}
          onRemove={() => manual({ positions: line.positions.filter(x => x.key !== p.key) })} />
      ))}
      <button type="button" className="ui-button ui-button-secondary"
        onClick={() => manual({ positions: [...line.positions, { key: crypto.randomUUID(), label: '', length: '', capacity: '', sealed: false }] })}>
        Tambah potongan sisa (bukan roll utuh)
      </button>
      <p className={matches ? 'text-success' : 'text-danger'} role="status">
        Total roll {formatQuantity(total, line.baseUnit)} {matches ? '= ' : '≠ '}
        jumlah masuk {base ? formatQuantity(base, line.baseUnit) : '-'}
      </p>
      {labels.length > 0 && <p className="muted">Label: {labels.join(', ')}</p>}
    </fieldset>
  )
}

export function IntakeLineCard({ line, units, onChange, onRemove }: {
  line: IntakeLine
  units: Unit[]
  onChange: (next: IntakeLine) => void
  onRemove: () => void
}) {
  const base = lineBaseQty(line)
  const set = (patch: Partial<IntakeLine>) => onChange(withAutoRolls({ ...line, ...patch }))
  const chooseUnit = (unitId: string) => {
    const unit = units.find(u => u.id === unitId)
    if (unit) set({ unitId: unit.id, unitLabel: unit.label, factor: unit.factor_base })
  }
  const costIsZero = line.cost.trim() !== '' && /^0+$/.test(line.cost.replace(/[.\s]/g, ''))

  return (
    <Card title={line.productName} actions={
      <button type="button" className="ui-button ui-button-secondary" onClick={onRemove}>Hapus baris</button>
    }>
      <p className="muted">Kode {line.sku}</p>
      <div className="form-grid">
        {units.length > 1 && (
          <Select label="Satuan" value={line.unitId} onChange={chooseUnit}
            options={units.map(u => ({ value: u.id, label: `${u.label} (isi ${formatQuantity(u.factor_base, line.baseUnit)})` }))} />
        )}
        <QuantityInput label="Jumlah masuk" unit={line.unitLabel} value={line.qty} onChange={qty => set({ qty })}
          hint={base && line.factor !== '1' ? `= ${formatQuantity(base, line.baseUnit)}` : undefined} />
        <RupiahInput label="Total modal baris ini" value={line.cost} onChange={cost => set({ cost })}
          hint="Total harga beli semua barang di baris ini (sudah termasuk ongkos/diskon), bukan harga satuan." />
      </div>
      {costIsZero && (
        <TextInput label="Alasan modal nol (wajib)" value={line.freeReason} onChange={freeReason => set({ freeReason })}
          maxLength={200} placeholder="Contoh: bonus dari distributor" />
      )}
      {line.trackSegments && <RollSection line={line} onChange={onChange} />}
    </Card>
  )
}
