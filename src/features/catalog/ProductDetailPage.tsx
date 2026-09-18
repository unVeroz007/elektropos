import { useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import Decimal from 'decimal.js'
import { useCommand } from '../../lib/useCommand'
import { formatDateTime, formatQuantity, formatRupiah } from '../../lib/numbers'
import { permissions, useProfile } from '../../lib/session'
import {
  Badge, Card, ConfirmDialog, EmptyState, ErrorMessage, Loading, Notice, PageHeader, SummaryRow, TextArea,
} from '../../components/ui'
import { CONDITION_LABEL, LOCATION_LABEL, labelOf } from '../../components/labels'
import type { ProductDetail, ProductPosition } from '../../components/productTypes'
import { catalogKeys, useCategories, useProduct } from './api'
import { BarcodePanel } from './BarcodePanel'

type StockGroup = { key: string; label: string; qty: Decimal }

export function stockByPlace(positions: ProductPosition[]): StockGroup[] {
  const groups = new Map<string, StockGroup>()
  for (const p of positions) {
    const key = `${p.location}|${p.condition}`
    const current = groups.get(key) ?? {
      key, label: `${labelOf(LOCATION_LABEL, p.location)} · ${labelOf(CONDITION_LABEL, p.condition)}`, qty: new Decimal(0),
    }
    current.qty = current.qty.add(p.qty_base)
    groups.set(key, current)
  }
  return [...groups.values()].sort((a, b) => a.key.localeCompare(b.key))
}

function UnitsCard({ product }: { product: ProductDetail }) {
  const active = product.units.filter(u => u.active !== false)
  const old = product.units.filter(u => u.active === false)
  return (
    <Card title="Satuan & harga jual">
      {active.map(u => (
        <SummaryRow key={u.id} strong={u.is_default}
          label={<>{u.label}{u.is_default && <> <Badge tone="info">utama</Badge></>}<br />
            <small className="muted">1 {u.label} = {formatQuantity(u.factor_base, product.base_unit)} · kelipatan jual {formatQuantity(u.sale_step, u.label)}</small></>}
          value={`${formatRupiah(u.sell_price)} / ${u.label}`} />
      ))}
      {old.length > 0 && (
        <details className="details">
          <summary>Riwayat harga/satuan lama ({old.length})</summary>
          {old.map(u => <SummaryRow key={u.id} label={`${u.label} (versi ${u.version})`} value={formatRupiah(u.sell_price)} />)}
        </details>
      )}
    </Card>
  )
}

function StockCard({ product }: { product: ProductDetail }) {
  const groups = stockByPlace(product.positions)
  return (
    <Card title="Stok per tempat">
      {groups.length === 0
        ? <EmptyState>Belum ada stok. Stok bertambah lewat Barang Masuk atau stok awal.</EmptyState>
        : groups.map(g => <SummaryRow key={g.key} label={g.label} value={formatQuantity(g.qty, product.base_unit)} />)}
      <p><Link to="/stok">Pindah, koreksi, atau hitung stok di menu Stok</Link></p>
    </Card>
  )
}

function RollsCard({ product }: { product: ProductDetail }) {
  if (!product.track_segments) return null
  return (
    <Card title="Posisi roll / potongan">
      {product.positions.length === 0 && <EmptyState>Belum ada roll.</EmptyState>}
      <ul className="plain-list">
        {product.positions.map(p => (
          <li key={p.id} className="row-between">
            <span>
              <strong>{p.label ?? 'Tanpa label'}</strong> · {labelOf(LOCATION_LABEL, p.location)} · {labelOf(CONDITION_LABEL, p.condition)}
            </span>
            <span>
              {formatQuantity(p.qty_base, product.base_unit)}
              {p.segment_capacity && ` dari ${formatQuantity(p.segment_capacity, product.base_unit)}`}
              {' '}{p.sealed ? <Badge tone="success">masih segel</Badge> : <Badge>sudah dipotong</Badge>}
            </span>
          </li>
        ))}
      </ul>
    </Card>
  )
}

function CostCard({ product }: { product: ProductDetail }) {
  if (!product.lots) return null
  const open = product.lots.filter(l => new Decimal(l.remaining_qty).greaterThan(0))
  const total = open.reduce((sum, l) => sum.add(l.remaining_cost), new Decimal(0))
  return (
    <Card title="Modal persediaan (hanya pemilik)">
      <SummaryRow strong label="Nilai modal stok tersisa" value={formatRupiah(total)} />
      {open.map(l => (
        <SummaryRow key={l.id} label={`Masuk ${formatDateTime(l.posted_at)}`}
          value={`${formatQuantity(l.remaining_qty, product.base_unit)} · ${formatRupiah(l.remaining_cost)}`} />
      ))}
    </Card>
  )
}

function ArchiveButton({ product }: { product: ProductDetail }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')
  const archive = useCommand<{ ok: boolean }, Record<string, unknown>>('archive_product_v1')

  async function confirm() {
    const result = await archive.run({
      product_id: product.id, expected_version: product.version, ...(reason.trim() ? { reason: reason.trim() } : {}),
    })
    if (result) {
      await queryClient.invalidateQueries({ queryKey: catalogKeys.all })
      navigate('/katalog', { replace: true })
    }
  }

  return (
    <>
      <button type="button" className="ui-button ui-button-danger" onClick={() => { archive.reset(); setOpen(true) }}>
        Arsipkan barang
      </button>
      <ConfirmDialog open={open} title={`Arsipkan ${product.name}?`} confirmLabel="Ya, arsipkan" danger busy={archive.busy}
        onConfirm={() => { void confirm() }} onCancel={() => setOpen(false)}>
        <p>Barang tidak muncul lagi di kasir dan pencarian. Riwayat nota dan stok lama tetap tersimpan.</p>
        <TextArea label="Alasan (boleh kosong)" value={reason} onChange={setReason} maxLength={500} />
        <ErrorMessage error={archive.error} />
      </ConfirmDialog>
    </>
  )
}

export function ProductDetailPage() {
  const { productId } = useParams()
  const profile = useProfile()
  const canEdit = permissions.manageCatalog(profile)
  const product = useProduct(productId)
  const categories = useCategories()
  const notice = (useLocation().state as { notice?: string } | null)?.notice

  if (product.isLoading) return <Loading label="Memuat barang…" />
  if (product.error || !product.data) {
    return (
      <section>
        <PageHeader title="Barang tidak dapat dibuka" />
        <ErrorMessage error={product.error ?? 'Barang tidak ditemukan.'} />
        <Link className="ui-button ui-button-secondary" to="/katalog">Kembali ke katalog</Link>
      </section>
    )
  }
  const p = product.data
  const category = categories.data?.find(c => c.id === p.category_id)?.name

  return (
    <section>
      <PageHeader title={p.name} description={p.specification || undefined}
        actions={canEdit && p.active && (
          <>
            <Link className="ui-button ui-button-primary" to={`/katalog/${p.id}/ubah`}>Ubah barang</Link>
            <ArchiveButton product={p} />
          </>
        )} />
      {notice && <Notice tone="success">{notice}</Notice>}
      {!p.active && <Badge tone="warning">Barang ini sudah diarsipkan</Badge>}
      <Card title="Keterangan">
        <SummaryRow label="Kode barang" value={p.sku} />
        <SummaryRow label="Satuan stok" value={p.base_unit} />
        <SummaryRow label="Rak" value={p.shelf || 'Belum diisi'} />
        <SummaryRow label="Kategori" value={category ?? 'Tanpa kategori'} />
        <SummaryRow label="Dilacak per roll" value={p.track_segments ? 'Ya, tiap roll/potongan punya label' : 'Tidak'} />
      </Card>
      <UnitsCard product={p} />
      <StockCard product={p} />
      <RollsCard product={p} />
      {permissions.viewCost(profile) && <CostCard product={p} />}
      <BarcodePanel product={p} canEdit={canEdit && p.active} />
      <p><Link to="/katalog">Kembali ke katalog</Link></p>
    </section>
  )
}
