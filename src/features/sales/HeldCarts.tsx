import { useState } from 'react'
import { Badge, Card, ConfirmDialog } from '../../components/ui'
import { MAX_ACTIVE_DRAFTS } from '../../lib/drafts'
import { formatDateTime } from '../../lib/numbers'
import { DRAFT_STATUS_LABEL, type CartDraft } from './cartDraft'

/** Daftar transaksi yang ditahan (maks 5). Lanjutkan atau hapus dengan konfirmasi. */
export function HeldCarts({ drafts, cartEmpty, onResume, onDelete }: {
  drafts: CartDraft[]
  cartEmpty: boolean
  onResume: (draft: CartDraft) => void
  onDelete: (draft: CartDraft) => Promise<void>
}) {
  const [pendingDelete, setPendingDelete] = useState<CartDraft | null>(null)
  const [busy, setBusy] = useState(false)
  if (drafts.length === 0) return null

  async function confirmDelete() {
    if (!pendingDelete) return
    setBusy(true)
    try {
      await onDelete(pendingDelete)
    } finally {
      setBusy(false)
      setPendingDelete(null)
    }
  }

  return (
    <Card title={`Transaksi ditahan (${drafts.length} dari ${MAX_ACTIVE_DRAFTS})`}>
      {!cartEmpty && (
        <p className="sl-muted">Untuk melanjutkan transaksi yang ditahan, selesaikan atau tahan keranjang sekarang dulu.</p>
      )}
      <ul className="sl-drafts">
        {drafts.map(draft => (
          <li key={draft.id} className="sl-draft">
            <div>
              <strong>{draft.label}</strong>
              <small>Disimpan {formatDateTime(draft.updated_at)}</small>
              {draft.status !== 'draft' && (
                <Badge tone={draft.status === 'unknown' ? 'warning' : 'info'}>{DRAFT_STATUS_LABEL[draft.status]}</Badge>
              )}
            </div>
            <div className="sl-row-actions">
              <button type="button" className="ui-button ui-button-primary" disabled={!cartEmpty}
                onClick={() => onResume(draft)}>
                {draft.status === 'unknown' ? 'Periksa & lanjutkan' : 'Lanjutkan'}
              </button>
              <button type="button" className="ui-button ui-button-secondary" onClick={() => setPendingDelete(draft)}>
                Hapus
              </button>
            </div>
          </li>
        ))}
      </ul>
      <ConfirmDialog open={pendingDelete !== null} title="Hapus transaksi yang ditahan?" danger busy={busy}
        confirmLabel="Ya, hapus" onCancel={() => setPendingDelete(null)} onConfirm={() => { void confirmDelete() }}>
        <p>“{pendingDelete?.label}” akan dihapus dari perangkat ini. Barang di dalamnya tidak ikut terjual.</p>
        {pendingDelete?.status === 'unknown' && (
          <p><strong>Perhatian:</strong> hasil pembayaran transaksi ini belum pasti. Periksa Riwayat Nota lebih dulu.</p>
        )}
      </ConfirmDialog>
    </Card>
  )
}
