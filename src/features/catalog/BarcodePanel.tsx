import { useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useCommand } from '../../lib/useCommand'
import { BarcodeScanner } from '../scanner'
import { Card, ConfirmDialog, EmptyState, ErrorMessage, Notice, Select } from '../../components/ui'
import type { ProductDetail } from '../../components/productTypes'
import { catalogKeys } from './api'

type AddResult = { ok: boolean; code: string; already: boolean }

/** Daftar barcode produk. Pemilik mendaftarkan barcode baru dengan scan/ketik (FR-CAT-02). */
export function BarcodePanel({ product, canEdit }: { product: ProductDetail; canEdit: boolean }) {
  const queryClient = useQueryClient()
  const activeUnits = product.units.filter(u => u.active !== false)
  const [unitId, setUnitId] = useState(activeUnits.find(u => u.is_default)?.id ?? activeUnits[0]?.id ?? '')
  const [removing, setRemoving] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const lastCode = useRef<string | null>(null)
  const add = useCommand<AddResult, Record<string, unknown>>('add_product_barcode_v1')
  const remove = useCommand<{ ok: boolean }, Record<string, unknown>>('remove_product_barcode_v1')

  const unitLabel = (id: string | null) => product.units.find(u => u.id === id)?.label ?? 'satuan utama'

  async function register(code: string) {
    if (add.busy) return
    // Kode berbeda = niat baru: jangan memakai ulang nomor operasi kode sebelumnya.
    if (lastCode.current !== code) add.reset()
    lastCode.current = code
    setMessage(null)
    const result = await add.run({ product_id: product.id, product_unit_id: unitId || undefined, code })
    if (result) {
      setMessage(result.already ? `Barcode ${code} sudah terdaftar pada barang ini.` : `Barcode ${code} tersimpan.`)
      await queryClient.invalidateQueries({ queryKey: catalogKeys.all })
    }
  }

  async function confirmRemove() {
    if (!removing) return
    const result = await remove.run({ code: removing })
    if (result) {
      setMessage(`Barcode ${removing} dihapus dari barang ini.`)
      setRemoving(null)
      await queryClient.invalidateQueries({ queryKey: catalogKeys.all })
    }
  }

  return (
    <Card title="Barcode">
      {product.barcodes.length === 0
        ? <EmptyState>Belum ada barcode untuk barang ini.</EmptyState>
        : (
          <ul className="plain-list">
            {product.barcodes.map(b => (
              <li key={b.code} className="row-between">
                <span><code className="code">{b.code}</code> · {unitLabel(b.unit_id)}</span>
                {canEdit && (
                  <button type="button" className="ui-button ui-button-secondary" onClick={() => { remove.reset(); setRemoving(b.code) }}>
                    Hapus
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      {message && <Notice tone="success">{message}</Notice>}
      <ErrorMessage error={add.error} />
      {canEdit && (
        <>
          {activeUnits.length > 1 && (
            <Select label="Barcode baru untuk satuan" value={unitId} onChange={setUnitId}
              options={activeUnits.map(u => ({ value: u.id, label: u.label }))} />
          )}
          <BarcodeScanner onScan={code => { void register(code) }} title="Daftarkan barcode"
            description="Scan barcode pada kemasan barang ini, atau ketik kodenya." />
          {add.busy && <p className="muted">Menyimpan barcode…</p>}
        </>
      )}
      <ConfirmDialog open={removing !== null} title="Hapus barcode?" confirmLabel="Ya, hapus barcode" danger
        busy={remove.busy} onConfirm={() => { void confirmRemove() }} onCancel={() => setRemoving(null)}>
        <p>Barcode <code className="code">{removing}</code> tidak akan dikenali lagi saat scan. Barang dan stoknya tidak berubah.</p>
        <ErrorMessage error={remove.error} />
      </ConfirmDialog>
    </Card>
  )
}
