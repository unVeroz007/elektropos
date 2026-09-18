import { useState, type ChangeEvent } from 'react'
import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'
import { useCommand } from '../../lib/useCommand'
import { Card, ConfirmDialog, ErrorMessage, Notice, PageHeader, SummaryRow } from '../../components/ui'
import { downloadText } from '../../components/download'
import { catalogKeys } from './api'
import { COLUMN_HELP, csvToImportRows, IMPORT_COLUMNS, templateCsv, type ImportRow } from './csv'

type PreviewResult = { ok: boolean; total: number; valid: number; errors: { line: number; code: string; message: string }[] }
type CommitResult = { ok: boolean; count: number }

export function CatalogImportPage() {
  const queryClient = useQueryClient()
  const [fileName, setFileName] = useState('')
  const [rows, setRows] = useState<ImportRow[]>([])
  const [problems, setProblems] = useState<string[]>([])
  const [preview, setPreview] = useState<PreviewResult | null>(null)
  const [previewError, setPreviewError] = useState<unknown>(null)
  const [checking, setChecking] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const commit = useCommand<CommitResult, { rows: ImportRow[] }>('commit_catalog_import_v1')

  async function onFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    setPreview(null)
    setPreviewError(null)
    commit.reset()
    if (!file) return
    setFileName(file.name)
    const parsed = csvToImportRows(await file.text())
    setRows(parsed.rows)
    setProblems(parsed.problems)
    if (parsed.rows.length === 0) return
    setChecking(true)
    try {
      setPreview(await readRpc<PreviewResult>('preview_catalog_import_v1', { rows: parsed.rows }))
    } catch (err) {
      setPreviewError(err)
    } finally {
      setChecking(false)
    }
  }

  async function confirmCommit() {
    const result = await commit.run({ rows })
    setConfirming(false)
    if (result) await queryClient.invalidateQueries({ queryKey: catalogKeys.all })
  }

  const ready = preview?.ok && rows.length > 0 && !commit.result

  return (
    <section className="narrow-page">
      <PageHeader title="Impor katalog dari berkas" description="Tambah banyak barang sekaligus dari berkas CSV (Excel: Simpan sebagai CSV)."
        actions={<Link className="ui-button ui-button-secondary" to="/katalog">Kembali ke katalog</Link>} />
      <Card title="1. Siapkan berkas">
        <p>Unduh templat, isi satu barang per baris, lalu simpan sebagai CSV. Impor hanya membuat barang baru, tidak menambah stok.</p>
        <button type="button" className="ui-button ui-button-secondary"
          onClick={() => downloadText('templat-impor-katalog.csv', templateCsv())}>Unduh templat</button>
        <details className="details">
          <summary>Arti tiap kolom</summary>
          {IMPORT_COLUMNS.map(c => <SummaryRow key={c} label={<code>{c}</code>} value={COLUMN_HELP[c]} />)}
        </details>
      </Card>
      <Card title="2. Pilih berkas & periksa">
        <div className="ui-field">
          <label htmlFor="catalog-file">Berkas CSV</label>
          <input id="catalog-file" type="file" accept=".csv,text/csv" onChange={e => { void onFile(e) }} />
        </div>
        {checking && <p className="muted">Memeriksa {rows.length} baris…</p>}
        {problems.length > 0 && (
          <div className="ui-alert ui-alert-error" role="alert"><ul>{problems.map(p => <li key={p}>{p}</li>)}</ul></div>
        )}
        <ErrorMessage error={previewError} />
        {preview && (
          <>
            <SummaryRow label="Berkas" value={fileName} />
            <SummaryRow label="Jumlah barang" value={preview.total} />
            <SummaryRow label="Siap disimpan" value={preview.valid} tone={preview.ok ? 'success' : undefined} />
            {preview.errors.length > 0 && (
              <div className="ui-alert ui-alert-error" role="alert">
                <strong>Perbaiki baris berikut di berkas lalu pilih ulang berkasnya</strong>
                <small> (baris 1 = judul kolom)</small>
                <ul>
                  {preview.errors.map((e, i) => (
                    <li key={`${e.line}-${i}`}>Baris {e.line + 1} ({rows[e.line - 1]?.sku || 'tanpa kode'}): {e.message}</li>
                  ))}
                </ul>
              </div>
            )}
          </>
        )}
      </Card>
      <Card title="3. Simpan">
        {commit.result
          ? <Notice tone="success">{commit.result.count} barang baru tersimpan di katalog.</Notice>
          : (
            <button type="button" className="ui-button ui-button-primary ui-button-large" disabled={!ready || commit.busy}
              onClick={() => setConfirming(true)}>
              Simpan {preview?.valid ?? 0} barang
            </button>
          )}
        <ErrorMessage error={commit.error} />
      </Card>
      <ConfirmDialog open={confirming} title="Simpan barang dari berkas?" confirmLabel="Ya, simpan" busy={commit.busy}
        onConfirm={() => { void confirmCommit() }} onCancel={() => setConfirming(false)}>
        <p>{rows.length} barang baru akan ditambahkan ke katalog dengan harga sesuai berkas. Stok tetap nol.</p>
      </ConfirmDialog>
    </section>
  )
}
