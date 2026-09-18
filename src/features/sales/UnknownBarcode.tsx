import { Card, ErrorMessage } from '../../components/ui'
import { useCommand } from '../../lib/useCommand'
import { snapshotFromSearch, type ProductSnapshot } from './cart'
import { ProductSearch } from './ProductSearch'
import type { ProductSearchItem, ProductUnit } from './types'

type AddBarcodeInput = { product_id: string; product_unit_id: string; code: string }
type AddBarcodeResult = { ok: true; code: string }

/**
 * Barcode belum terdaftar. Pemilik dapat langsung menautkannya ke barang;
 * karyawan diarahkan mencari manual atau meminta pemilik (tidak membuat produk otomatis).
 */
export function UnknownBarcode({ code, canRegister, onRegistered, onClose }: {
  code: string
  canRegister: boolean
  onRegistered: (snapshot: ProductSnapshot) => void
  onClose: () => void
}) {
  const register = useCommand<AddBarcodeResult, AddBarcodeInput>('add_product_barcode_v1')

  async function link(product: ProductSearchItem, unit: ProductUnit) {
    const result = await register.run({ product_id: product.id, product_unit_id: unit.id, code })
    if (result) onRegistered(snapshotFromSearch(product, unit))
  }

  return (
    <Card title="Barcode belum terdaftar"
      actions={<button type="button" className="ui-button ui-button-secondary" onClick={onClose}>Tutup</button>}>
      <p>Kode <strong className="sl-code">{code}</strong> belum dikenal sistem.</p>
      {canRegister ? (
        <>
          <p>Cari barangnya di bawah, lalu tekan tombol satuannya. Barcode tersimpan dan barang masuk keranjang.</p>
          <ErrorMessage error={register.error} />
          {register.busy && <p role="status">Menyimpan barcode…</p>}
          <ProductSearch label="Barang untuk barcode ini"
            onAdd={(snapshot, product) => {
              const unit = product.units.find(u => u.id === snapshot.unitId)
              if (unit && !register.busy) void link(product, unit)
            }} />
        </>
      ) : (
        <p>
          Cari barang lewat kolom pencarian di atas, atau minta pemilik toko mendaftarkan barcode ini
          di menu <strong>Daftar Barcode</strong>.
        </p>
      )}
    </Card>
  )
}
