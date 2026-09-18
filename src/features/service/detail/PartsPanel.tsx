import { useState, type FormEvent } from 'react'
import Decimal from 'decimal.js'
import { useQuery } from '@tanstack/react-query'
import {
  Card, ChoiceGroup, EmptyState, ErrorMessage, Loading, Notice, QuantityInput, RupiahInput, TextArea, TextInput,
} from '../../../components/ui'
import { formatDateTime, formatQuantity, formatRupiah, quantityOrNull, rupiahOrNull } from '../../../lib/numbers'
import { permissions, useProfile } from '../../../lib/session'
import { searchPartPositions, serviceKeys, useServiceCommand } from '../api'
import { Button, Collapsible, CommandError } from '../common'
import { STOCK_CONDITION, STOCK_LOCATION } from '../labels'
import { partQtyError } from '../logic'
import type { CommandResult, PartEvent, StockCondition, StockLocation, StockPositionRow, TicketDetail } from '../types'
import { useDebounced } from '../useDebounced'

function locationLabel(location: string | null): string {
  return location === 'SHOP' || location === 'FIELD_FATHER' ? STOCK_LOCATION[location] : 'Lokasi lain'
}

/** Part terpakai (stok berkurang saat dicatat) dan pengembalian sebelum tagihan final. */
export function PartsPanel({ ticket }: { ticket: TicketDetail }) {
  const profile = useProfile()
  const owner = permissions.manageService(profile)
  const open = owner && !ticket.invoice && !ticket.closed_at
  const canUse = open && ticket.work_status === 'WORKING' && Boolean(ticket.approval.active)
  const reversed = new Map<string, PartEvent[]>()
  for (const e of ticket.part_events) {
    if (e.kind === 'REVERSE' && e.reverses_event_id) {
      reversed.set(e.reverses_event_id, [...(reversed.get(e.reverses_event_id) ?? []), e])
    }
  }
  const uses = ticket.part_events.filter(e => e.kind === 'USE')

  if (uses.length === 0 && !open) return null
  return (
    <Card title="Part yang dipakai">
      {uses.length === 0
        ? <EmptyState>Belum ada part yang dipakai.</EmptyState>
        : (
          <ul className="srv-part-list">
            {uses.map(use => (
              <PartRow key={use.id} use={use} returns={reversed.get(use.id) ?? []} ticket={ticket} canReturn={open} />
            ))}
          </ul>
        )}
      {open && !canUse && (
        <Notice tone="info">Part dapat dicatat saat status "Dikerjakan" dan persetujuan biaya masih berlaku.</Notice>
      )}
      {canUse && (
        <Collapsible title="+ Catat part yang dipakai" defaultOpen={uses.length === 0}>
          <UsePartForm ticket={ticket} />
        </Collapsible>
      )}
    </Card>
  )
}

function PartRow({ use, returns, ticket, canReturn }: { use: PartEvent; returns: PartEvent[]; ticket: TicketDetail; canReturn: boolean }) {
  const [returning, setReturning] = useState(false)
  const net = use.net_qty ?? use.qty
  return (
    <li className="srv-part">
      <div className="srv-part-head">
        <strong>{use.product_name}</strong>
        <span>{formatQuantity(net, use.base_unit)}{!new Decimal(net).eq(use.qty) && ` (awal ${formatQuantity(use.qty, use.base_unit)})`}</span>
      </div>
      <p className="srv-muted">
        Dari {locationLabel(use.source_location)}{use.source_label ? ` · ${use.source_label}` : ''}
        {' · '}Harga tagih {formatRupiah(use.charge_unit_price ?? '0')}/{use.base_unit}
        {use.cost !== null && ` · Modal ${formatRupiah(use.cost)}`}
        {' · '}{formatDateTime(use.occurred_at)}
      </p>
      {returns.map(r => (
        <p key={r.id} className="srv-muted">
          Dikembalikan {formatQuantity(r.qty, r.base_unit)} · {r.reason} · {formatDateTime(r.occurred_at)}
        </p>
      ))}
      {canReturn && new Decimal(net).greaterThan(0) && !returning && (
        <Button variant="secondary" onClick={() => setReturning(true)}>Kembalikan part ini</Button>
      )}
      {returning && <ReversePartForm use={use} net={net} ticket={ticket} onDone={() => setReturning(false)} />}
    </li>
  )
}

function ReversePartForm({ use, net, ticket, onDone }: { use: PartEvent; net: string; ticket: TicketDetail; onDone: () => void }) {
  const [qty, setQty] = useState(() => new Decimal(net).toFixed())
  const [location, setLocation] = useState<StockLocation>(use.source_location === 'FIELD_FATHER' ? 'FIELD_FATHER' : 'SHOP')
  const [condition, setCondition] = useState<StockCondition>('SALEABLE')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('reverse_service_part_v1')

  const qtyValue = quantityOrNull(qty)
  let error: string | null = null
  if (!qtyValue) error = 'Isi jumlah yang dikembalikan.'
  else if (new Decimal(qtyValue).greaterThan(net)) error = `Maksimal ${formatQuantity(net, use.base_unit)}.`
  else if (reason.trim().length < 3) error = 'Tulis alasan pengembalian.'

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error || !qtyValue) return
    const result = await command.run({
      ticket_id: ticket.id, expected_version: ticket.version, use_event_id: use.id, qty: qtyValue,
      target_location: location, target_condition: condition, reason: reason.trim(),
    })
    if (result) onDone()
  }

  return (
    <form className="srv-subform" onSubmit={submit} noValidate>
      <QuantityInput label="Jumlah dikembalikan" value={qty} onChange={setQty} unit={use.base_unit} required />
      <ChoiceGroup label="Dikembalikan ke" value={location} onChange={setLocation}
        options={[{ value: 'SHOP', label: STOCK_LOCATION.SHOP }, { value: 'FIELD_FATHER', label: STOCK_LOCATION.FIELD_FATHER }]} />
      <ChoiceGroup label="Kondisi part" value={condition} onChange={setCondition}
        options={[{ value: 'SALEABLE', label: STOCK_CONDITION.SALEABLE }, { value: 'DAMAGED', label: STOCK_CONDITION.DAMAGED }]} />
      <TextArea label="Alasan" value={reason} onChange={setReason} required rows={2} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <div className="srv-actions">
        <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan pengembalian'}</Button>
        <Button variant="secondary" onClick={onDone}>Batal</Button>
      </div>
    </form>
  )
}

function UsePartForm({ ticket }: { ticket: TicketDetail }) {
  const [query, setQuery] = useState('')
  const debounced = useDebounced(query)
  const [position, setPosition] = useState<StockPositionRow | null>(null)
  const enabled = debounced.trim().length >= 2 && !position
  const results = useQuery({
    queryKey: [...serviceKeys.all, 'parts', debounced],
    queryFn: () => searchPartPositions(debounced),
    enabled,
  })

  if (!position) {
    return (
      <div>
        <TextInput type="search" label="Cari part (nama atau kode)" value={query} onChange={setQuery}
          placeholder="Mis. kapasitor, kabel NYA" maxLength={120} />
        {enabled && results.isPending && <Loading label="Mencari stok…" />}
        {results.isError && <ErrorMessage error={results.error} />}
        {enabled && results.isSuccess && results.data.length === 0 && (
          <EmptyState>Tidak ada stok bagus di toko/dibawa ayah untuk pencarian ini.</EmptyState>
        )}
        {enabled && results.isSuccess && results.data.length > 0 && (
          <ul className="srv-option-list" aria-label="Pilih stok part">
            {results.data.map(row => (
              <li key={row.position_id}>
                <button type="button" className="srv-option" onClick={() => setPosition(row)}>
                  <strong>{row.name}</strong>
                  <span>{locationLabel(row.location)}{row.label ? ` · potongan ${row.label}` : ''}</span>
                  <span className="srv-muted">Tersedia {formatQuantity(row.qty_base, row.base_unit)} · {row.sku}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    )
  }
  return <UsePartDetails key={position.position_id} ticket={ticket} position={position} onChange={() => setPosition(null)} />
}

function UsePartDetails({ ticket, position, onChange }: { ticket: TicketDetail; position: StockPositionRow; onChange: () => void }) {
  const [qty, setQty] = useState('')
  const [price, setPrice] = useState('')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useServiceCommand<CommandResult, Record<string, unknown>>('use_service_part_v1')

  const qtyError = partQtyError(qty, position)
  const priceValue = price.trim() ? rupiahOrNull(price) : null
  const error = qtyError ?? (price.trim() && !priceValue ? 'Harga tagih tidak sah.' : null)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    const qtyValue = quantityOrNull(qty)
    if (error || !qtyValue) return
    const payload: Record<string, unknown> = {
      ticket_id: ticket.id, expected_version: ticket.version, position_id: position.position_id, qty: qtyValue,
    }
    if (priceValue) payload.charge_unit_price = priceValue
    if (reason.trim()) payload.reason = reason.trim()
    if (await command.run(payload)) onChange()
  }

  return (
    <form onSubmit={submit} noValidate>
      <div className="srv-picked">
        <div>
          <strong>{position.name}</strong>
          <span className="srv-muted">
            {locationLabel(position.location)}{position.label ? ` · potongan ${position.label}` : ''}
            {' · '}tersedia {formatQuantity(position.qty_base, position.base_unit)}
          </span>
        </div>
        <Button variant="secondary" onClick={onChange}>Ganti part</Button>
      </div>
      <QuantityInput label="Jumlah dipakai" value={qty} onChange={setQty} unit={position.base_unit} required
        hint="Stok langsung berkurang saat disimpan." />
      <RupiahInput label={`Harga tagih per ${position.base_unit} (opsional)`} value={price} onChange={setPrice}
        hint="Harga final ditetapkan di tagihan. Boleh Rp0 bila tidak ditagih." />
      <TextInput label="Catatan (opsional)" value={reason} onChange={setReason} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <CommandError error={command.error} />
      <Button type="submit" disabled={command.busy}>{command.busy ? 'Menyimpan…' : 'Simpan pemakaian part'}</Button>
    </form>
  )
}
