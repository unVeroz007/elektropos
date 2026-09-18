import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useCommand } from '../../lib/useCommand'
import { Card, EmptyState, ErrorMessage, Loading, Notice, PageHeader, TextInput } from '../../components/ui'
import type { Category } from '../../components/productTypes'
import { catalogKeys, useCategories } from './api'

type UpsertResult = { ok: boolean; entity_id: string }

function CategoryRow({ category }: { category: Category }) {
  const queryClient = useQueryClient()
  const [name, setName] = useState(category.name)
  const [editing, setEditing] = useState(false)
  const save = useCommand<UpsertResult, Record<string, unknown>>('upsert_category_v1')

  async function run(payload: Record<string, unknown>) {
    const result = await save.run({ category_id: category.id, ...payload })
    if (result) {
      setEditing(false)
      await queryClient.invalidateQueries({ queryKey: catalogKeys.categories })
    }
  }

  if (!editing) {
    return (
      <li className="row-between">
        <span>{category.name}</span>
        <span className="button-row">
          <button type="button" className="ui-button ui-button-secondary" onClick={() => { save.reset(); setEditing(true) }}>Ganti nama</button>
          <button type="button" className="ui-button ui-button-secondary" disabled={save.busy}
            onClick={() => { void run({ name: category.name, active: false }) }}>Sembunyikan</button>
        </span>
        <ErrorMessage error={save.error} />
      </li>
    )
  }
  return (
    <li>
      <form onSubmit={e => { e.preventDefault(); void run({ name: name.trim() }) }}>
        <TextInput label="Nama kategori" value={name} onChange={v => { setName(v); save.reset() }} maxLength={80} />
        <div className="button-row">
          <button type="submit" className="ui-button ui-button-primary" disabled={save.busy || !name.trim()}>Simpan</button>
          <button type="button" className="ui-button ui-button-secondary" onClick={() => setEditing(false)}>Batal</button>
        </div>
        <ErrorMessage error={save.error} />
      </form>
    </li>
  )
}

export function CategoriesPage() {
  const queryClient = useQueryClient()
  const categories = useCategories()
  const [name, setName] = useState('')
  const [saved, setSaved] = useState<string | null>(null)
  const create = useCommand<UpsertResult, { name: string }>('upsert_category_v1')

  async function submit(event: FormEvent) {
    event.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) return
    const result = await create.run({ name: trimmed })
    if (result) {
      setSaved(trimmed)
      setName('')
      await queryClient.invalidateQueries({ queryKey: catalogKeys.categories })
    }
  }

  return (
    <section className="narrow-page">
      <PageHeader title="Kategori barang" description="Kategori memudahkan mencari barang di katalog."
        actions={<Link className="ui-button ui-button-secondary" to="/katalog">Kembali ke katalog</Link>} />
      <Card title="Tambah kategori">
        <form onSubmit={submit}>
          <TextInput label="Nama kategori" value={name} onChange={v => { setName(v); create.reset(); setSaved(null) }}
            maxLength={80} placeholder="Contoh: Lampu, Kabel, Saklar" />
          <button type="submit" className="ui-button ui-button-primary" disabled={create.busy || !name.trim()}>Tambah</button>
        </form>
        {saved && <Notice tone="success">Kategori {saved} tersimpan.</Notice>}
        <ErrorMessage error={create.error} />
      </Card>
      <Card title="Daftar kategori">
        {categories.isLoading && <Loading />}
        <ErrorMessage error={categories.error} />
        {categories.data?.length === 0 && <EmptyState>Belum ada kategori.</EmptyState>}
        <ul className="plain-list">{categories.data?.map(c => <CategoryRow key={c.id} category={c} />)}</ul>
      </Card>
    </section>
  )
}
