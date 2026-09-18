import { useState, type FormEvent } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useCommand } from '../../lib/useCommand'
import { BarcodeScanner } from '../scanner'
import {
  Card, Checkbox, ChoiceGroup, ErrorMessage, Loading, Notice, PageHeader, QuantityInput, RupiahInput, Select, TextArea, TextInput,
} from '../../components/ui'
import type { ProductDetail } from '../../components/productTypes'
import { catalogKeys, useCategories, useProduct } from './api'
import {
  buildProductPayload, EMPTY_FORM, formErrors, formFromProduct, KIND_PRESETS, unitChanged,
  type ProductFormState, type ProductKind,
} from './productForm'

type UpsertResult = { ok: boolean; entity_id: string; unit_changed: boolean }

function ProductForm({ product, onReload }: { product?: ProductDetail; onReload: () => void }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const categories = useCategories()
  const original = product ? formFromProduct(product) : EMPTY_FORM
  const [form, setForm] = useState<ProductFormState>(original)
  const [kind, setKind] = useState<ProductKind>('PCS')
  const [showErrors, setShowErrors] = useState(false)
  const save = useCommand<UpsertResult, Record<string, unknown>>('upsert_product_v1')
  const editing = Boolean(product)
  const errors = formErrors(form)
  const priceChanged = editing && unitChanged(original, form)

  function update(patch: Partial<ProductFormState>) {
    setForm(f => ({ ...f, ...patch }))
    save.reset()
  }

  function chooseKind(next: ProductKind) {
    setKind(next)
    if (next !== 'OTHER') update(KIND_PRESETS[next])
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setShowErrors(true)
    if (errors.length > 0) return
    const result = await save.run(buildProductPayload(form, product))
    if (!result) return
    await queryClient.invalidateQueries({ queryKey: catalogKeys.all })
    navigate(`/katalog/${result.entity_id}`, {
      replace: true,
      state: { notice: result.unit_changed ? 'Harga/satuan baru berlaku mulai sekarang.' : 'Perubahan tersimpan.' },
    })
  }

  return (
    <form onSubmit={submit} noValidate>
      {!editing && (
        <ChoiceGroup label="Jenis barang" value={kind} onChange={chooseKind} options={[
          { value: 'PCS', label: 'Dijual per buah', description: 'Lampu, stop kontak, saklar' },
          { value: 'METER', label: 'Dijual per meter', description: 'Kabel; stok dilacak per roll' },
          { value: 'OTHER', label: 'Lainnya', description: 'Isi satuan sendiri' },
        ]} />
      )}
      <Card title="Identitas barang">
        <div className="form-grid">
          <TextInput label="Kode barang (SKU)" value={form.sku} onChange={sku => update({ sku })} maxLength={60} required />
          <TextInput label="Nama barang" value={form.name} onChange={name => update({ name })} maxLength={150} required />
          <TextInput label="Spesifikasi pembeda" hint="Contoh: 10 Watt putih, 1,5 mm² merah" value={form.specification}
            onChange={specification => update({ specification })} maxLength={500} />
          <TextInput label="Rak" value={form.shelf} onChange={shelf => update({ shelf })} maxLength={30} />
          <Select label="Kategori" value={form.category_id} onChange={category_id => update({ category_id })}
            options={[{ value: '', label: 'Tanpa kategori' }, ...(categories.data ?? []).map(c => ({ value: c.id, label: c.name }))]} />
        </div>
      </Card>
      <Card title="Satuan & harga">
        <div className="form-grid">
          <TextInput label="Satuan stok" hint={editing ? 'Tidak dapat diubah setelah barang dibuat.' : 'Contoh: pcs atau m'}
            value={form.base_unit} onChange={base_unit => update({ base_unit })} disabled={editing || kind !== 'OTHER'} maxLength={30} />
          <QuantityInput label="Kelipatan stok" unit={form.base_unit} hint="1 untuk barang per buah; 0,1 untuk meteran"
            value={form.quantity_step} onChange={quantity_step => update({ quantity_step })} disabled={editing || kind !== 'OTHER'} />
          <TextInput label="Satuan jual" hint="Contoh: pcs, m, roll 100 m" value={form.unit_label}
            onChange={unit_label => update({ unit_label })} maxLength={40} />
          <QuantityInput label="Isi 1 satuan jual" unit={form.base_unit} value={form.factor_base}
            onChange={factor_base => update({ factor_base })} hint="Contoh: roll 100 m berisi 100" />
          <QuantityInput label="Kelipatan jual" unit={form.unit_label} value={form.sale_step}
            onChange={sale_step => update({ sale_step })} />
          <RupiahInput label={`Harga jual per ${form.unit_label || 'satuan'}`} value={form.sell_price}
            onChange={sell_price => update({ sell_price })} />
        </div>
        <Checkbox label="Lacak stok per roll/potongan (kabel, selang)" checked={form.track_segments}
          onChange={track_segments => update({ track_segments })} disabled={editing || kind !== 'OTHER'} />
        {priceChanged && (
          <Notice tone="warning">
            Harga/satuan berubah. Sistem membuat versi satuan baru; nota lama tetap memakai harga lama, dan
            keranjang kasir yang masih memuat harga lama akan diminta memeriksa ulang.
          </Notice>
        )}
        {editing && priceChanged && (
          <TextArea label="Alasan perubahan harga (boleh kosong)" value={form.reason} onChange={reason => update({ reason })} maxLength={500} />
        )}
      </Card>
      {!editing && (
        <Card title="Barcode (boleh kosong)">
          <TextInput label="Barcode" value={form.barcode} onChange={barcode => update({ barcode })} maxLength={100}
            hint="Scan di bawah atau ketik. Barcode tambahan dapat didaftarkan nanti." />
          <BarcodeScanner onScan={barcode => update({ barcode })} title="Scan barcode kemasan" />
        </Card>
      )}
      {showErrors && errors.length > 0 && (
        <div className="ui-alert ui-alert-error" role="alert">
          <strong>Periksa isian:</strong>
          <ul>{errors.map(e => <li key={e}>{e}</li>)}</ul>
        </div>
      )}
      <ErrorMessage error={save.error} />
      {save.error?.code === 'VERSION_CONFLICT' && (
        <button type="button" className="ui-button ui-button-secondary" onClick={onReload}>Muat ulang data barang</button>
      )}
      <div className="button-row">
        <button type="submit" className="ui-button ui-button-primary ui-button-large" disabled={save.busy}>
          {save.busy ? 'Menyimpan…' : editing ? 'Simpan perubahan' : 'Simpan barang baru'}
        </button>
      </div>
      <p className="muted">Menyimpan barang tidak menambah stok. Stok bertambah lewat Barang Masuk atau stok awal.</p>
    </form>
  )
}

export function ProductFormPage() {
  const { productId } = useParams()
  const product = useProduct(productId)

  if (productId && product.isLoading) return <Loading label="Memuat barang…" />
  if (productId && !product.data) return <ErrorMessage error={product.error ?? 'Barang tidak ditemukan.'} />

  return (
    <section className="narrow-page">
      <PageHeader title={product.data ? `Ubah ${product.data.name}` : 'Tambah barang'}
        actions={<Link className="ui-button ui-button-secondary" to={product.data ? `/katalog/${product.data.id}` : '/katalog'}>Batal</Link>} />
      <ProductForm key={product.data ? `${product.data.id}-${product.data.version}` : 'new'} product={product.data}
        onReload={() => { void product.refetch() }} />
    </section>
  )
}
