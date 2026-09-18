import { useQuery } from '@tanstack/react-query'
import { Badge, Card, ErrorMessage, Loading, Notice, PageHeader, SummaryRow } from '../../components/ui'
import { BACKUP_STATUS_LABEL, labelOf } from '../../components/labels'
import { formatDateTime } from '../../lib/numbers'
import { readRpc } from '../../lib/rpc'

type BackupRun = { status: string; started_at: string; completed_at: string | null; label?: string | null; error?: string | null }

type Health = {
  server_time: string
  last_backup: (BackupRun & { restore_verified_at: string | null }) | null
  last_successful_backup_at: string | null
  backup_stale: boolean
  db_size_mb?: number
  detail?: {
    products: number
    invoices: number
    tickets: number
    attachments: number
    pending_attachments: number
    expired_pending_attachments: number
    photo_bytes: number
    last_backup_photo_count: number | null
    last_backup_total_bytes: number | null
    last_backup_mirror_status: string | null
    last_restore_verified_at: string | null
  }
  technical?: {
    postgres_version: string
    last_backup_label: string | null
    last_backup_error: string | null
    recent_backups: BackupRun[]
    largest_tables: { table: string; bytes: number }[]
  }
}

function megabytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined) return '-'
  return `${(bytes / 1_048_576).toLocaleString('id-ID', { maximumFractionDigits: 1 })} MB`
}

/** Kesehatan & backup (FR-OPS-01). Detail teknis hanya untuk akun teknis. */
export function HealthPage() {
  const health = useQuery({
    queryKey: ['settings', 'health'],
    queryFn: () => readRpc<Health>('get_health_v1'),
    refetchInterval: 60_000,
  })
  if (health.isPending) return <Loading label="Memeriksa sistem…" />
  if (health.isError) return <ErrorMessage error={health.error} />
  const h = health.data

  return (
    <section>
      <PageHeader title="Kesehatan & backup" description={`Diperiksa ${formatDateTime(h.server_time)}`} />
      {h.backup_stale
        ? <Notice tone="warning">Belum ada backup berhasil dalam 24 jam terakhir. Jalankan backup dan salin ke disk eksternal (lihat panduan operasi).</Notice>
        : <Notice tone="success">Backup terakhir berhasil {formatDateTime(h.last_successful_backup_at)}.</Notice>}

      <Card title="Backup">
        <SummaryRow label="Backup terakhir" value={h.last_backup
          ? <>{formatDateTime(h.last_backup.started_at)} <Badge tone={h.last_backup.status === 'SUCCEEDED' ? 'success' : h.last_backup.status === 'FAILED' ? 'danger' : 'info'}>
              {labelOf(BACKUP_STATUS_LABEL, h.last_backup.status)}</Badge></>
          : 'Belum pernah'} />
        {h.detail && (
          <>
            <SummaryRow label="Uji pemulihan terakhir" value={h.detail.last_restore_verified_at ? formatDateTime(h.detail.last_restore_verified_at) : 'Belum pernah'} />
            <SummaryRow label="Salinan ke disk eksternal" value={h.detail.last_backup_mirror_status ?? 'Tidak diatur'} />
            <SummaryRow label="Foto di backup terakhir" value={h.detail.last_backup_photo_count ?? '-'} />
            <SummaryRow label="Ukuran backup terakhir" value={megabytes(h.detail.last_backup_total_bytes)} />
          </>
        )}
      </Card>

      {h.detail && (
        <Card title="Data">
          <SummaryRow label="Ukuran database" value={`${h.db_size_mb ?? '-'} MB`} />
          <SummaryRow label="Barang aktif" value={h.detail.products} />
          <SummaryRow label="Nota" value={h.detail.invoices} />
          <SummaryRow label="Tiket servis" value={h.detail.tickets} />
          <SummaryRow label="Foto tersimpan" value={`${h.detail.attachments} (${megabytes(h.detail.photo_bytes)})`} />
          <SummaryRow label="Foto sedang diunggah / gagal" value={`${h.detail.pending_attachments} / ${h.detail.expired_pending_attachments}`} />
        </Card>
      )}

      {h.technical && (
        <Card title="Detail teknis">
          <SummaryRow label="PostgreSQL" value={h.technical.postgres_version} />
          {h.technical.last_backup_error && <ErrorMessage error={`Error backup terakhir: ${h.technical.last_backup_error}`} />}
          <h3>10 backup terakhir</h3>
          <ul className="plain-list">
            {h.technical.recent_backups.map(b => (
              <li key={`${b.started_at}-${b.label ?? ''}`}>
                {formatDateTime(b.started_at)} · {labelOf(BACKUP_STATUS_LABEL, b.status)}{b.label ? ` · ${b.label}` : ''}{b.error ? ` · ${b.error}` : ''}
              </li>
            ))}
          </ul>
          <h3>Tabel terbesar</h3>
          <ul className="plain-list">
            {h.technical.largest_tables.map(t => <li key={t.table}>{t.table}: {megabytes(t.bytes)}</li>)}
          </ul>
        </Card>
      )}
    </section>
  )
}
