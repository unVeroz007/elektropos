import { useCallback, useEffect, useState } from 'react'
import Decimal from 'decimal.js'
import { EmptyState, ErrorMessage, Loading } from '../../components/ui'
import { formatQuantity } from '../../lib/numbers'
import { listSellablePositions } from './api'
import { isWholeRoll, lineBaseQty, rollPickFromPosition, type CartLine, type RollPick } from './cart'
import type { SellablePosition } from './types'

type Loaded = { positions: SellablePosition[]; error: unknown }

/**
 * Pilih roll/potongan fisik untuk satu baris (BR-03). Bahasa awam:
 * satu baris = satu potongan; potongan dari dua roll berbeda = dua baris.
 */
export function RollPicker({ line, lines, onPick, onCancel }: {
  line: CartLine
  lines: CartLine[]
  onPick: (pick: RollPick) => void
  onCancel?: () => void
}) {
  const [loaded, setLoaded] = useState<Loaded | null>(null)
  const [attempt, setAttempt] = useState(0)
  const whole = isWholeRoll(line)

  useEffect(() => {
    let alive = true
    listSellablePositions(line.productId)
      .then(r => { if (alive) setLoaded({ positions: r.positions, error: null }) })
      .catch((error: unknown) => { if (alive) setLoaded({ positions: [], error }) })
    return () => { alive = false }
  }, [line.productId, attempt])

  const reload = useCallback(() => {
    setLoaded(null)
    setAttempt(a => a + 1)
  }, [])

  const usedElsewhere = (positionId: string) => lines
    .filter(l => l.key !== line.key && l.position?.id === positionId)
    .reduce((sum, l) => sum.plus(lineBaseQty(l) ?? 0), new Decimal(0))

  return (
    <div className="sl-roll" role="group" aria-label={`Pilih roll untuk ${line.productName}`}>
      <p className="sl-roll-help">
        {whole
          ? `Pilih roll yang masih bersegel (utuh ${formatQuantity(line.factorBase, line.baseUnit)}).`
          : 'Pilih roll yang akan dipotong. Satu baris = satu potongan. '
            + 'Jika pembeli minta potongan dari roll lain, tambahkan barang ini sekali lagi.'}
      </p>
      {!loaded && <Loading label="Memuat daftar roll…" />}
      {loaded?.error ? <ErrorMessage error={loaded.error} /> : null}
      {loaded && !loaded.error && loaded.positions.length === 0 && (
        <EmptyState>Tidak ada roll layak jual di toko untuk barang ini.</EmptyState>
      )}
      {loaded && loaded.positions.length > 0 && (
        <ul className="sl-roll-list">
          {loaded.positions.map(p => {
            const used = usedElsewhere(p.position_id)
            const left = new Decimal(p.qty_base).minus(used)
            const fitsWhole = p.sealed && p.segment_capacity !== null
              && new Decimal(p.segment_capacity).equals(line.factorBase) && used.isZero()
            const disabled = whole ? !fitsWhole : left.lessThanOrEqualTo(0)
            const selected = line.position?.id === p.position_id
            return (
              <li key={p.position_id}>
                <button type="button" className={`sl-roll-option${selected ? ' is-selected' : ''}`}
                  disabled={disabled} aria-pressed={selected} onClick={() => onPick(rollPickFromPosition(p))}>
                  <strong>Roll {p.label ?? 'tanpa label'}</strong>
                  <span>
                    Sisa {formatQuantity(p.qty_base, line.baseUnit)}
                    {p.sealed ? ' · masih bersegel' : ' · sudah terpotong'}
                  </span>
                  {!used.isZero() && (
                    <small>Sudah dipakai di keranjang {formatQuantity(used, line.baseUnit)}</small>
                  )}
                  {whole && !fitsWhole && <small>Tidak bisa dijual sebagai roll utuh</small>}
                </button>
              </li>
            )
          })}
        </ul>
      )}
      <div className="sl-row-actions">
        <button type="button" className="ui-button ui-button-secondary" onClick={reload}>Muat ulang daftar roll</button>
        {onCancel && <button type="button" className="ui-button ui-button-secondary" onClick={onCancel}>Batal ganti</button>}
      </div>
    </div>
  )
}
