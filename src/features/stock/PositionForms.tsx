import { useState, type FormEvent } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import Decimal from 'decimal.js'
import { useCommand } from '../../lib/useCommand'
import { formatQuantity, formatRupiah, quantityOrNull } from '../../lib/numbers'
import { Card, ChoiceGroup, ConfirmDialog, ErrorMessage, QuantityInput, SummaryRow, TextArea, TextInput } from '../../components/ui'
import { CONDITION_LABEL, LOCATION_LABEL, labelOf } from '../../components/labels'
import type { StockPositionRow } from './api'

type Done = () => void

export function positionText(p: Pick<StockPositionRow, 'name' | 'label' | 'location' | 'condition'>): string {
  return [p.name, p.label, labelOf(LOCATION_LABEL, p.location), labelOf(CONDITION_LABEL, p.condition)].filter(Boolean).join(' · ')
}

function useInvalidateStock() {
  const queryClient = useQueryClient()
  return () => Promise.all([
    queryClient.invalidateQueries({ queryKey: ['stock'] }),
    queryClient.invalidateQueries({ queryKey: ['products'] }),
  ])
}

function qtyError(qty: string, position: StockPositionRow): string | null {
  const value = quantityOrNull(qty)
  if (!value) return 'Jumlah wajib diisi dan lebih dari nol.'
  if (new Decimal(value).greaterThan(position.qty_base)) return `Melebihi stok posisi ini (${formatQuantity(position.qty_base, position.base_unit)}).`
  return null
}

const PLACES = [
  { location: 'SHOP', condition: 'SALEABLE' },
  { location: 'FIELD_FATHER', condition: 'SALEABLE' },
  { location: 'SHOP', condition: 'DAMAGED' },
  { location: 'FIELD_FATHER', condition: 'DAMAGED' },
] as const

/** Pindah stok: toko ↔ dibawa ayah, layak ↔ rusak (transfer_stock_v1). */
export function TransferForm({ position, onDone }: { position: StockPositionRow; onDone: Done }) {
  const invalidate = useInvalidateStock()
  const options = PLACES.filter(p => p.location !== position.location || p.condition !== position.condition)
    .map(p => ({ value: `${p.location}|${p.condition}`, label: `${labelOf(LOCATION_LABEL, p.location)} · ${labelOf(CONDITION_LABEL, p.condition)}` }))
  const [destination, setDestination] = useState(options[0].value)
  const [qty, setQty] = useState(new Decimal(position.qty_base).toFixed())
  const [label, setLabel] = useState('')
  const [reason, setReason] = useState('')
  const [shown, setShown] = useState(false)
  const command = useCommand<{ ok: boolean }, Record<string, unknown>>('transfer_stock_v1')
  const [location, condition] = destination.split('|')
  const errors = [qtyError(qty, position), !reason.trim() && 'Alasan wajib diisi.',
    position.track_segments && !label.trim() && 'Label roll/potongan baru wajib diisi.'].filter(Boolean) as string[]

  async function submit(event: FormEvent) {
    event.preventDefault()
    setShown(true)
    if (errors.length) return
    const result = await command.run({
      position_id: position.position_id, expected_version: position.version, qty_base: quantityOrNull(qty),
      destination_location: location, destination_condition: condition, reason: reason.trim(),
      ...(position.track_segments ? { destination_label: label.trim() } : {}),
    })
    if (result) { await invalidate(); onDone() }
  }

  return (
    <form onSubmit={submit}>
      <ChoiceGroup label="Pindahkan ke" value={destination} onChange={v => { setDestination(v); command.reset() }} options={options} />
      <QuantityInput label="Jumlah dipindah" unit={position.base_unit} value={qty} onChange={v => { setQty(v); command.reset() }} />
      {position.track_segments && (
        <TextInput label="Label untuk potongan di tujuan" value={label} onChange={v => { setLabel(v); command.reset() }} maxLength={40}
          hint="Tulis label yang sama pada roll/potongan fisiknya." />
      )}
      <TextInput label="Alasan" value={reason} onChange={v => { setReason(v); command.reset() }} maxLength={500}
        placeholder="Contoh: dibawa ayah untuk servis rumah" />
      <FormFooter errors={shown ? errors : []} error={command.error} busy={command.busy} label="Pindahkan" onCancel={onDone} />
    </form>
  )
}

/** Buang barang rusak/hilang (dispose_stock_v1): stok & modal keluar, dicatat sebagai kerugian. */
export function DisposeForm({ position, onDone }: { position: StockPositionRow; onDone: Done }) {
  const invalidate = useInvalidateStock()
  const [qty, setQty] = useState(new Decimal(position.qty_base).toFixed())
  const [reason, setReason] = useState('')
  const [note, setNote] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [shown, setShown] = useState(false)
  const command = useCommand<{ ok: boolean; cost_removed: string }, Record<string, unknown>>('dispose_stock_v1')
  const errors = [qtyError(qty, position), !reason.trim() && 'Alasan wajib diisi.'].filter(Boolean) as string[]

  async function confirm() {
    const result = await command.run({
      position_id: position.position_id, expected_version: position.version, qty_base: quantityOrNull(qty),
      reason: reason.trim(), ...(note.trim() ? { note: note.trim() } : {}),
    })
    setConfirming(false)
    if (result) { await invalidate(); onDone() }
  }

  return (
    <form onSubmit={e => { e.preventDefault(); setShown(true); if (!errors.length) setConfirming(true) }}>
      <QuantityInput label="Jumlah dibuang" unit={position.base_unit} value={qty} onChange={v => { setQty(v); command.reset() }} />
      <TextInput label="Alasan" value={reason} onChange={v => { setReason(v); command.reset() }} maxLength={500}
        placeholder="Contoh: lampu pecah, tidak bisa diretur" />
      <TextArea label="Catatan (boleh kosong)" value={note} onChange={setNote} maxLength={500} />
      <FormFooter errors={shown ? errors : []} error={command.error} busy={command.busy} label="Buang barang" onCancel={onDone} danger />
      <ConfirmDialog open={confirming} title="Buang barang ini?" confirmLabel="Ya, buang" danger busy={command.busy}
        onConfirm={() => { void confirm() }} onCancel={() => setConfirming(false)}>
        <p>{formatQuantity(quantityOrNull(qty) ?? '0', position.base_unit)} {position.name} keluar dari stok dan dicatat sebagai kerugian. Tidak dapat dibatalkan.</p>
      </ConfirmDialog>
    </form>
  )
}

/** Koreksi kurang pada satu posisi (adjust_stock_v1 arah OUT). */
export function AdjustOutForm({ position, onDone }: { position: StockPositionRow; onDone: Done }) {
  const invalidate = useInvalidateStock()
  const [qty, setQty] = useState('')
  const [reason, setReason] = useState('')
  const [shown, setShown] = useState(false)
  const command = useCommand<{ ok: boolean; cost_delta: string }, Record<string, unknown>>('adjust_stock_v1')
  const errors = [qtyError(qty, position), !reason.trim() && 'Alasan wajib diisi.'].filter(Boolean) as string[]

  async function submit(event: FormEvent) {
    event.preventDefault()
    setShown(true)
    if (errors.length) return
    const result = await command.run({
      direction: 'OUT', position_id: position.position_id, expected_version: position.version,
      qty_base: quantityOrNull(qty), reason: reason.trim(),
    })
    if (result) { await invalidate(); onDone() }
  }

  return (
    <form onSubmit={submit}>
      <SummaryRow label="Stok tercatat" value={formatQuantity(position.qty_base, position.base_unit)} />
      <QuantityInput label="Kurangi sebanyak" unit={position.base_unit} value={qty} onChange={v => { setQty(v); command.reset() }} />
      <TextInput label="Alasan" value={reason} onChange={v => { setReason(v); command.reset() }} maxLength={500}
        placeholder="Contoh: terpotong tanpa nota" />
      {position.lot_remaining_cost && (
        <p className="muted">Modal ikut berkurang sesuai modal roll/lot ini (sisa modal lot {formatRupiah(position.lot_remaining_cost)}).</p>
      )}
      <FormFooter errors={shown ? errors : []} error={command.error} busy={command.busy} label="Simpan koreksi kurang" onCancel={onDone} />
    </form>
  )
}

export function FormFooter({ errors, error, busy, label, onCancel, danger }: {
  errors: string[]
  error: unknown
  busy: boolean
  label: string
  onCancel?: () => void
  danger?: boolean
}) {
  return (
    <>
      {errors.length > 0 && <div className="ui-alert ui-alert-error" role="alert"><ul>{errors.map(e => <li key={e}>{e}</li>)}</ul></div>}
      <ErrorMessage error={error} />
      <div className="button-row">
        <button type="submit" className={`ui-button ${danger ? 'ui-button-danger' : 'ui-button-primary'}`} disabled={busy}>
          {busy ? 'Menyimpan…' : label}
        </button>
        {onCancel && <button type="button" className="ui-button ui-button-secondary" onClick={onCancel}>Batal</button>}
      </div>
    </>
  )
}

export type PositionAction = 'transfer' | 'adjust' | 'dispose'

export function PositionActionCard({ position, action, onDone }: { position: StockPositionRow; action: PositionAction; onDone: Done }) {
  const titles: Record<PositionAction, string> = { transfer: 'Pindahkan stok', adjust: 'Koreksi kurang', dispose: 'Buang barang rusak' }
  return (
    <Card title={`${titles[action]}: ${positionText(position)}`}>
      {action === 'transfer' && <TransferForm position={position} onDone={onDone} />}
      {action === 'adjust' && <AdjustOutForm position={position} onDone={onDone} />}
      {action === 'dispose' && <DisposeForm position={position} onDone={onDone} />}
    </Card>
  )
}
