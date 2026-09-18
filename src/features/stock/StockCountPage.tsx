import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import Decimal from 'decimal.js'
import {
  Badge, Card, Checkbox, ChoiceGroup, ConfirmDialog, ErrorMessage, Loading, Notice, PageHeader, QuantityInput,
  RupiahInput, TextInput,
} from '../../components/ui'
import { CONDITION_LABEL, LOCATION_LABEL, labelOf } from '../../components/labels'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'
import { permissions, useProfile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { stockKeys } from './api'
import {
  buildPostCount, countDifference, countLineIssue, EMPTY_COUNT_LINE, hasConflict,
  type CountItem, type CountLineForm, type StockCount,
} from './countModel'
import { StockNav } from './StockNav'

type PostResult = { status: 'POSTED'; adjusted_lines: number; document_number: string | null }

function DifferenceText({ diff, unit }: { diff: Decimal | null; unit: string }) {
  if (!diff) return null
  if (diff.isZero()) return <Badge tone="success">Cocok</Badge>
  return diff.isNegative()
    ? <Badge tone="danger">Kurang {formatQuantity(diff.abs(), unit)}</Badge>
    : <Badge tone="warning">Lebih {formatQuantity(diff, unit)}</Badge>
}

function CountLine({ item, form, showIssue, onChange }: {
  item: CountItem
  form: CountLineForm
  showIssue: boolean
  onChange: (patch: Partial<CountLineForm>) => void
}) {
  const diff = countDifference(item, form)
  const issue = countLineIssue(item, form)
  return (
    <li className="list-card">
      <span className="list-card-title">{item.name}{item.label ? ` · ${item.label}` : ''}</span>
      <span className="muted">
        {labelOf(LOCATION_LABEL, item.location)} · {labelOf(CONDITION_LABEL, item.condition)} · tercatat {formatQuantity(item.system_qty, item.base_unit)}
      </span>
      {item.changed_since_start && (
        <Notice tone="warning">Barang ini sudah berubah sejak hitungan dimulai (sekarang {formatQuantity(item.current_qty, item.base_unit)}).</Notice>
      )}
      <QuantityInput label="Hasil hitung" unit={item.base_unit} value={form.counted} onChange={counted => onChange({ counted })} />
      <DifferenceText diff={diff} unit={item.base_unit} />
      {diff && !diff.isZero() && (
        <TextInput label="Keterangan selisih (opsional)" value={form.reason} onChange={reason => onChange({ reason })} maxLength={200} />
      )}
      {diff?.greaterThan(0) && (
        <>
          <ChoiceGroup label="Modal kelebihan stok" value={form.costMode} onChange={costMode => onChange({ costMode })} options={[
            { value: 'COST', label: 'Modal diketahui' },
            { value: 'ZERO', label: 'Tanpa modal (dengan alasan)' },
          ]} />
          {form.costMode === 'COST' ? (
            <>
              <RupiahInput label="Total modal kelebihan" value={form.cost} onChange={cost => onChange({ cost })} />
              <Checkbox label="Modal ini sudah benar" checked={form.costConfirmed} onChange={costConfirmed => onChange({ costConfirmed })} />
            </>
          ) : (
            <TextInput label="Alasan tanpa modal" value={form.zeroReason} onChange={zeroReason => onChange({ zeroReason })} maxLength={200} />
          )}
          {item.track_segments && (
            <TextInput label="Label potongan baru" value={form.newLabel} onChange={newLabel => onChange({ newLabel })} maxLength={40} />
          )}
        </>
      )}
      {showIssue && issue && <p className="field-error" role="alert">{issue}</p>}
    </li>
  )
}

function PostedSummary({ count }: { count: StockCount }) {
  return (
    <Card title={count.status === 'POSTED' ? 'Hasil hitung' : 'Hitungan belum disimpan pemilik'}>
      {count.status === 'POSTED' && (
        <p>Disimpan {formatDateTime(count.posted_at)}{count.document_number ? ` · Dokumen ${count.document_number}` : ' · tanpa selisih'}.</p>
      )}
      <ul className="card-list">
        {count.items.map(item => (
          <li key={item.position_id} className="list-card">
            <span className="list-card-title">{item.name}{item.label ? ` · ${item.label}` : ''}</span>
            <span>
              Tercatat {formatQuantity(item.system_qty, item.base_unit)}
              {item.counted_qty !== null && ` · dihitung ${formatQuantity(item.counted_qty, item.base_unit)} `}
              <DifferenceText diff={item.difference ? new Decimal(item.difference) : null} unit={item.base_unit} />
            </span>
            {item.cost_delta && !new Decimal(item.cost_delta).isZero() && (
              <span className="muted">Perubahan modal {formatRupiah(item.cost_delta)}</span>
            )}
          </li>
        ))}
      </ul>
    </Card>
  )
}

function DraftCountForm({ count }: { count: StockCount }) {
  const queryClient = useQueryClient()
  const [forms, setForms] = useState<Record<string, CountLineForm>>({})
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useCommand<PostResult, Record<string, unknown>>('post_stock_count_v1')
  const built = buildPostCount(count, forms, reason)
  const conflict = hasConflict(count)

  function patch(positionId: string, change: Partial<CountLineForm>) {
    command.reset()
    setForms(f => ({ ...f, [positionId]: { ...(f[positionId] ?? EMPTY_COUNT_LINE), ...change } }))
  }

  async function submit() {
    if (!('items' in built)) return
    const result = await command.run({ count_id: count.id, reason: built.reason, items: built.items })
    setConfirming(false)
    if (result) {
      await queryClient.invalidateQueries({ queryKey: stockKeys.all })
    }
  }

  return (
    <>
      {conflict && (
        <Notice tone="warning">
          Ada barang yang terjual atau dipindah sejak hitungan dimulai. Simpan akan ditolak sistem;
          buat hitungan baru untuk barang tersebut.
        </Notice>
      )}
      <ul className="card-list">
        {count.items.map(item => (
          <CountLine key={item.position_id} item={item} form={forms[item.position_id] ?? EMPTY_COUNT_LINE}
            showIssue={touched} onChange={change => patch(item.position_id, change)} />
        ))}
      </ul>
      <Card>
        <TextInput label="Keterangan hitungan (opsional)" value={reason} onChange={setReason} maxLength={500}
          placeholder="Contoh: Hitung stok akhir bulan" />
        {touched && 'issue' in built && <ErrorMessage error={built.issue} />}
        <ErrorMessage error={command.error} />
        <button type="button" className="ui-button ui-button-primary ui-button-large" disabled={command.busy}
          onClick={() => { setTouched(true); if ('items' in built) setConfirming(true) }}>
          Simpan hasil hitung
        </button>
      </Card>
      <ConfirmDialog open={confirming} title="Simpan hasil hitung?" confirmLabel="Ya, simpan" busy={command.busy}
        onConfirm={() => { void submit() }} onCancel={() => setConfirming(false)}>
        <p>Stok tercatat disesuaikan dengan hasil hitung. Selisih kurang mengurangi modal persediaan dan tercatat sebagai kerugian stok.</p>
      </ConfirmDialog>
    </>
  )
}

/** Isi dan simpan satu hitungan stok. */
export function StockCountPage() {
  const { countId = '' } = useParams<{ countId: string }>()
  const profile = useProfile()
  const count = useQuery({
    queryKey: stockKeys.count(countId),
    queryFn: () => readRpc<StockCount>('get_stock_count_v1', { count_id: countId }),
    enabled: countId !== '',
  })

  return (
    <section>
      <PageHeader title="Hitung stok" description="Tulis jumlah yang benar-benar ada di rak/tempat."
        actions={<Link className="ui-button ui-button-secondary" to="/stok/hitung">Daftar hitungan</Link>} />
      <StockNav />
      {count.isPending && <Loading label="Memuat hitungan…" />}
      <ErrorMessage error={count.error} />
      {count.data && (count.data.status === 'POSTED' || !permissions.manageStock(profile)
        ? <PostedSummary count={count.data} />
        : <DraftCountForm key={count.data.version} count={count.data} />)}
    </section>
  )
}
