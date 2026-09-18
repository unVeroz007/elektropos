import { useState, type FormEvent } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  Badge, Card, ChoiceGroup, ConfirmDialog, EmptyState, ErrorMessage, Loading, Notice, PageHeader, RupiahInput,
  SummaryRow, TextInput,
} from '../../components/ui'
import { CASHBOX_LABEL, labelOf } from '../../components/labels'
import { formatDateTime, formatRupiah, rupiahOrNull } from '../../lib/numbers'
import { hasRole, permissions, useProfile, type Profile } from '../../lib/session'
import { useCommand } from '../../lib/useCommand'
import { cashKeys, useCashSession, type CashboxCode, type ClosedCashbox, type OpenCashSession } from './api'
import { closeError, difference, openError, outflowError, varianceText } from './cashModel'

type CommandResult = { ok: boolean; version?: number }

function cashboxesFor(profile: Profile): CashboxCode[] {
  return hasRole(profile, 'OWNER', 'MAINTAINER') ? ['SHOP_DRAWER', 'FATHER_WALLET'] : ['SHOP_DRAWER']
}

/** Boleh membuka/menutup cashbox ini (D1: karyawan hanya laci toko). */
function canOperate(profile: Profile, code: CashboxCode): boolean {
  return code === 'SHOP_DRAWER' ? permissions.openShopDrawer(profile) : permissions.manageFatherWallet(profile)
}

function useInvalidateCash() {
  const queryClient = useQueryClient()
  return () => queryClient.invalidateQueries({ queryKey: cashKeys.all })
}

function OpenForm({ closed }: { closed: ClosedCashbox }) {
  const invalidate = useInvalidateCash()
  const [amount, setAmount] = useState(closed.last_counted_amount ?? '')
  const [note, setNote] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useCommand<CommandResult, Record<string, unknown>>('open_cash_session_v1')
  const error = openError(amount, closed.last_counted_amount, note)
  const diff = difference(rupiahOrNull(amount), closed.last_counted_amount)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const payload: Record<string, unknown> = { cashbox_code: closed.cashbox_code, opening_amount: rupiahOrNull(amount) }
    if (note.trim()) payload.note = note.trim()
    if (await command.run(payload)) await invalidate()
  }

  return (
    <form onSubmit={submit} noValidate>
      <p>{labelOf(CASHBOX_LABEL, closed.cashbox_code)} belum dibuka. Hitung uang yang ada sekarang, lalu buka kas.</p>
      {closed.last_counted_amount !== null && (
        <SummaryRow label={`Hitungan saat tutup terakhir (${formatDateTime(closed.last_closed_at)})`}
          value={formatRupiah(closed.last_counted_amount)} />
      )}
      <RupiahInput label="Uang di laci sekarang" value={amount} onChange={value => { setAmount(value); command.reset() }} />
      {diff && !diff.isZero() && (
        <>
          <Notice tone="warning">Berbeda dari hitungan tutup terakhir: {varianceText(diff)}. Pemilik akan meninjau.</Notice>
          <TextInput label="Keterangan perbedaan" value={note} onChange={setNote} maxLength={500}
            placeholder="Contoh: ditambah uang receh dari rumah" />
        </>
      )}
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-primary ui-button-large" disabled={command.busy}>
        {command.busy ? 'Membuka…' : 'Buka kas'}
      </button>
    </form>
  )
}

function CloseForm({ session }: { session: OpenCashSession }) {
  const invalidate = useInvalidateCash()
  const [counted, setCounted] = useState('')
  const [note, setNote] = useState('')
  const [touched, setTouched] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const command = useCommand<CommandResult, Record<string, unknown>>('close_cash_session_v1')
  const error = closeError(counted, session.expected, note)
  const diff = difference(rupiahOrNull(counted), session.expected)

  async function confirm() {
    const payload: Record<string, unknown> = {
      session_id: session.id, expected_version: session.version, counted_amount: rupiahOrNull(counted),
    }
    if (note.trim()) payload.note = note.trim()
    const result = await command.run(payload)
    setConfirming(false)
    if (result) await invalidate()
  }

  return (
    <form onSubmit={event => { event.preventDefault(); setTouched(true); if (!error) setConfirming(true) }} noValidate>
      <RupiahInput label="Hitungan uang fisik" value={counted} onChange={value => { setCounted(value); command.reset() }} />
      {diff && <SummaryRow label="Selisih dengan saldo sistem" value={varianceText(diff)} tone={diff.isZero() ? 'success' : 'danger'} />}
      {diff && !diff.isZero() && (
        <TextInput label="Keterangan selisih" value={note} onChange={setNote} maxLength={500} placeholder="Contoh: kembalian salah" />
      )}
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>Tutup kas</button>
      <ConfirmDialog open={confirming} title="Tutup kas?" confirmLabel="Ya, tutup kas" busy={command.busy}
        onConfirm={() => { void confirm() }} onCancel={() => setConfirming(false)}>
        <SummaryRow label="Saldo sistem" value={formatRupiah(session.expected)} />
        <SummaryRow label="Uang dihitung" value={formatRupiah(rupiahOrNull(counted) ?? '0')} />
        {diff && <SummaryRow strong label="Selisih" value={varianceText(diff)} />}
        <p>Setelah ditutup, penjualan tunai berikutnya menunggu kas dibuka lagi.</p>
      </ConfirmDialog>
    </form>
  )
}

function AdjustForm({ session }: { session: OpenCashSession }) {
  const invalidate = useInvalidateCash()
  const [kind, setKind] = useState<'OWNER_ADD' | 'OWNER_WITHDRAW' | 'EXPENSE'>('OWNER_ADD')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useCommand<CommandResult, Record<string, unknown>>('record_cash_adjustment_v1')
  const direction = kind === 'OWNER_ADD' ? 'IN' : 'OUT'
  const error = direction === 'OUT'
    ? outflowError(amount, session.expected, reason)
    : outflowError(amount, null, reason)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const result = await command.run({
      cashbox_code: session.cashbox_code, direction, kind, amount: rupiahOrNull(amount), reason: reason.trim(),
    })
    if (result) { setAmount(''); setReason(''); setTouched(false); await invalidate() }
  }

  return (
    <form onSubmit={submit} noValidate>
      <ChoiceGroup label="Jenis" value={kind} onChange={value => { setKind(value); command.reset() }} options={[
        { value: 'OWNER_ADD', label: 'Tambah uang', description: 'Uang dari pemilik masuk kas' },
        { value: 'OWNER_WITHDRAW', label: 'Ambil uang', description: 'Pemilik mengambil uang' },
        { value: 'EXPENSE', label: 'Bayar biaya', description: 'Mis. listrik, bensin' },
      ]} />
      <RupiahInput label="Jumlah" value={amount} onChange={value => { setAmount(value); command.reset() }} />
      <TextInput label="Alasan" value={reason} onChange={setReason} maxLength={500} />
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>Simpan</button>
    </form>
  )
}

function TransferForm({ session }: { session: OpenCashSession }) {
  const invalidate = useInvalidateCash()
  const target: CashboxCode = session.cashbox_code === 'SHOP_DRAWER' ? 'FATHER_WALLET' : 'SHOP_DRAWER'
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [touched, setTouched] = useState(false)
  const command = useCommand<CommandResult, Record<string, unknown>>('transfer_cash_v1')
  const error = outflowError(amount, session.expected, reason)

  async function submit(event: FormEvent) {
    event.preventDefault()
    setTouched(true)
    if (error) return
    const result = await command.run({
      source_cashbox: session.cashbox_code, target_cashbox: target, amount: rupiahOrNull(amount), reason: reason.trim(),
    })
    if (result) { setAmount(''); setReason(''); setTouched(false); await invalidate() }
  }

  return (
    <form onSubmit={submit} noValidate>
      <p>Pindahkan uang ke <strong>{labelOf(CASHBOX_LABEL, target)}</strong> (keduanya harus sedang dibuka). Bukan pendapatan baru.</p>
      <RupiahInput label="Jumlah dipindah" value={amount} onChange={value => { setAmount(value); command.reset() }} />
      <TextInput label="Alasan" value={reason} onChange={setReason} maxLength={500} placeholder="Contoh: setoran uang servis ayah" />
      {touched && error && <ErrorMessage error={error} />}
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-primary" disabled={command.busy}>Pindahkan uang</button>
    </form>
  )
}

export function ReviewForm({ sessionId, version, onDone }: { sessionId: string; version: number; onDone?: () => void }) {
  const invalidate = useInvalidateCash()
  const [note, setNote] = useState('')
  const command = useCommand<CommandResult, Record<string, unknown>>('review_cash_session_v1')
  async function submit(event: FormEvent) {
    event.preventDefault()
    const payload: Record<string, unknown> = { session_id: sessionId, expected_version: version }
    if (note.trim()) payload.note = note.trim()
    if (await command.run(payload)) { await invalidate(); onDone?.() }
  }
  return (
    <form onSubmit={submit} noValidate>
      <TextInput label="Catatan tinjauan (opsional)" value={note} onChange={setNote} maxLength={500} />
      <ErrorMessage error={command.error} />
      <button type="submit" className="ui-button ui-button-secondary" disabled={command.busy}>Tandai sudah ditinjau</button>
    </form>
  )
}

function OpenSessionView({ session, profile }: { session: OpenCashSession; profile: Profile }) {
  const [panel, setPanel] = useState<'close' | 'adjust' | 'transfer' | null>(null)
  const operate = canOperate(profile, session.cashbox_code)
  const manage = permissions.manageCash(profile)
  const movements = session.movements ?? []
  return (
    <>
      <SummaryRow label={`Dibuka ${formatDateTime(session.opened_at)}${session.opened_by_name ? ` oleh ${session.opened_by_name}` : ''}`}
        value={formatRupiah(session.opening_amount)} />
      <SummaryRow label="Uang masuk" value={formatRupiah(session.total_in)} tone="success" />
      <SummaryRow label="Uang keluar" value={formatRupiah(session.total_out)} tone="danger" />
      <SummaryRow strong label="Saldo seharusnya (sistem)" value={formatRupiah(session.expected)} />
      <p className="muted">Saldo sistem bukan bukti uang fisik. Tetap hitung uang di laci.</p>
      {session.review_pending && (
        <Notice tone="warning">
          Uang awal berbeda dari hitungan tutup sebelumnya ({formatRupiah(session.opening_variance ?? '0')}).
          {session.opening_note ? ` Keterangan: ${session.opening_note}.` : ''}
          {manage && <ReviewForm sessionId={session.id} version={session.version} />}
        </Notice>
      )}
      {operate && (
        <div className="button-row">
          <button type="button" className="ui-button ui-button-primary" onClick={() => setPanel(p => p === 'close' ? null : 'close')}>
            Tutup kas
          </button>
          {manage && (
            <>
              <button type="button" className="ui-button ui-button-secondary" onClick={() => setPanel(p => p === 'adjust' ? null : 'adjust')}>
                Tambah / ambil / biaya
              </button>
              <button type="button" className="ui-button ui-button-secondary" onClick={() => setPanel(p => p === 'transfer' ? null : 'transfer')}>
                Pindah uang
              </button>
            </>
          )}
        </div>
      )}
      {panel === 'close' && <CloseForm key={session.version} session={session} />}
      {panel === 'adjust' && <AdjustForm session={session} />}
      {panel === 'transfer' && <TransferForm session={session} />}

      <h3>Catatan uang</h3>
      {movements.length === 0 ? <EmptyState>Belum ada uang masuk/keluar sejak kas dibuka.</EmptyState> : (
        <ul className="card-list">
          {movements.map(m => (
            <li key={m.id} className="list-card">
              <span className="list-card-title">{m.label}</span>
              <span className="muted">{formatDateTime(m.occurred_at)}{m.actor_name ? ` · ${m.actor_name}` : ''}{m.reference ? ` · ${m.reference}` : ''}</span>
              {m.reason && <span className="muted">{m.reason}</span>}
              <span className="list-card-money">{m.direction === 'IN' ? '+' : '−'}{formatRupiah(m.amount)}</span>
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

function CashboxPanel({ code, profile }: { code: CashboxCode; profile: Profile }) {
  const session = useCashSession(code)
  return (
    <Card title={labelOf(CASHBOX_LABEL, code)}
      actions={session.data && <Badge tone={session.data.open ? 'success' : 'neutral'}>{session.data.open ? 'Dibuka' : 'Ditutup'}</Badge>}>
      {session.isPending && <Loading label="Memuat kas…" />}
      <ErrorMessage error={session.error} />
      {session.data && (session.data.open
        ? <OpenSessionView session={session.data} profile={profile} />
        : canOperate(profile, code)
          ? <OpenForm key={session.data.last_session_id ?? 'first'} closed={session.data} />
          : <p>Kas belum dibuka.</p>)}
    </Card>
  )
}

/** Kas laci toko & dompet ayah (FR-CASH-01, BR-12). */
export function CashPage() {
  const profile = useProfile()
  return (
    <section>
      <PageHeader title={profile.role === 'STAFF' ? 'Kas laci toko' : 'Kas'}
        description="Buka kas di awal hari, tutup dengan menghitung uang fisik. Transfer/QRIS tidak masuk laci." />
      {cashboxesFor(profile).map(code => <CashboxPanel key={code} code={code} profile={profile} />)}
    </section>
  )
}
