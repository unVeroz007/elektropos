import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useQuery, useQueryClient } from '@tanstack/react-query'

type Customer = {
  id: string
  name: string
  phone: string | null
  alternate_contact: string | null
  address: string | null
}

export function Customers() {
  const qc = useQueryClient()
  const [query, setQuery] = useState('')
  const [editing, setEditing] = useState<Customer | null>(null)
  const [showForm, setShowForm] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const { data: customers } = useQuery({
    queryKey: ['customers', query],
    queryFn: async () => {
      if (!supabase) return []
      const { data } = await supabase.rpc('search_customers_v1', { p_input: { query, limit: 50 } })
      return (data as Customer[]) ?? []
    }
  })

  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!supabase) return
    setBusy(true); setError('')
    const fd = new FormData(e.currentTarget)
    const input: Record<string, string> = Object.fromEntries(fd.entries()) as Record<string, string>
    const { data, error: err } = await supabase.rpc('upsert_customer_v1', {
      p_input: {
        operation_id: crypto.randomUUID(),
        customer_id: editing?.id,
        name: input.name,
        phone: input.phone || undefined,
        alternate_contact: input.alternate_contact || undefined,
        address: input.address || undefined
      }
    })
    setBusy(false)
    if (err) { setError(err.message); return }
    const res = data as { ok?: boolean }
    if (res?.ok) {
      setShowForm(false); setEditing(null)
      qc.invalidateQueries({ queryKey: ['customers'] })
    }
  }

  return (
    <section>
      <div className="section-head">
        <div>
          <div className="eyebrow">PELANGGAN</div>
          <h2>Daftar Pelanggan</h2>
          <p>Servis memerlukan nama dan cara kontak.</p>
        </div>
        <button onClick={() => { setEditing(null); setShowForm(true) }}>+ Pelanggan Baru</button>
      </div>

      {(showForm || editing) && (
        <form onSubmit={submit} className="editor" key={editing?.id ?? 'new'}>
          <h3>{editing ? 'Ubah Pelanggan' : 'Pelanggan Baru'}</h3>
          <label>Nama<input name="name" defaultValue={editing?.name || ''} required maxLength={120} /></label>
          <label>No. HP<input name="phone" defaultValue={editing?.phone || ''} placeholder="08xxxxxxxxxx" /></label>
          <label>Kontak alternatif<input name="alternate_contact" defaultValue={editing?.alternate_contact || ''} /></label>
          <label>Alamat<input name="address" defaultValue={editing?.address || ''} /></label>
          {error && <div className="error" role="alert">{error}</div>}
          <div className="form-actions">
            <button disabled={busy}>{busy ? 'Menyimpan…' : 'Simpan'}</button>
            <button type="button" className="ghost" onClick={() => { setShowForm(false); setEditing(null); setError('') }}>Batal</button>
          </div>
        </form>
      )}

      <label className="search-label">Cari nama atau nomor HP
        <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Contoh: Budi / 0812…" maxLength={120} />
      </label>

      <div className="invoice-list">
        {(customers ?? []).map(c => (
          <article key={c.id} className="invoice-card" onClick={() => { setEditing(c); setShowForm(true) }}>
            <div className="invoice-header">
              <strong>{c.name}</strong>
              <span>{c.phone || c.alternate_contact || '-'}</span>
            </div>
            {c.address && <div className="invoice-footer"><span>{c.address}</span></div>}
          </article>
        ))}
        {(customers ?? []).length === 0 && <div className="empty">Belum ada pelanggan.</div>}
      </div>
    </section>
  )
}

export function Settings() {
  const qc = useQueryClient()
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [busy, setBusy] = useState(false)

  const { data: settings } = useQuery({
    queryKey: ['settings'],
    queryFn: async () => {
      if (!supabase) return null
      const { data } = await supabase.rpc('get_shop_settings_v1')
      return data as { name: string; address: string; phone: string; receipt_width: number; configured: boolean; version: number }
    }
  })

  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!supabase || !settings) return
    setBusy(true); setError(''); setSuccess('')
    const fd = new FormData(e.currentTarget)
    const input: Record<string, string> = Object.fromEntries(fd.entries()) as Record<string, string>
    const { data, error: err } = await supabase.rpc('update_shop_settings_v1', {
      p_input: {
        operation_id: crypto.randomUUID(),
        expected_version: settings.version,
        name: input.name,
        address: input.address,
        phone: input.phone,
        receipt_width: Number(input.receipt_width)
      }
    })
    setBusy(false)
    if (err) { setError(err.message); return }
    const res = data as { ok?: boolean }
    if (res?.ok) {
      setSuccess('Pengaturan tersimpan.')
      qc.invalidateQueries({ queryKey: ['settings'] })
    }
  }

  if (!settings) return <p>Memuat pengaturan…</p>

  return (
    <section className="form-page">
      <div className="section-head"><div>
        <div className="eyebrow">PENGATURAN</div>
        <h2>Identitas Toko</h2>
        <p>Dipakai pada struk dan laporan.</p>
      </div></div>

      {!settings.configured && (
        <div className="notice">Identitas toko belum lengkap. Isi nama toko sebelum mencetak struk.</div>
      )}
      {success && <div className="success">{success}</div>}
      {error && <div className="error" role="alert">{error}</div>}

      <form onSubmit={submit} className="editor" key={settings.version}>
        <label>Nama toko<input name="name" defaultValue={settings.name} required maxLength={120} /></label>
        <label>Alamat<input name="address" defaultValue={settings.address} maxLength={200} /></label>
        <label>Telepon<input name="phone" defaultValue={settings.phone} maxLength={30} /></label>
        <label>Lebar struk
          <select name="receipt_width" defaultValue={String(settings.receipt_width)}>
            <option value="58">58 mm</option>
            <option value="80">80 mm</option>
          </select>
        </label>
        <button disabled={busy}>{busy ? 'Menyimpan…' : 'Simpan Pengaturan'}</button>
      </form>
    </section>
  )
}

export function Health() {
  const { data } = useQuery({
    queryKey: ['health'],
    queryFn: async () => {
      if (!supabase) return null
      const { data } = await supabase.rpc('get_health_v1')
      return data as {
        server_time: string; db_size_mb: number;
        last_backup: { status: string; started_at: string; restore_verified_at: string | null } | null;
        detail: { products: number; invoices: number; tickets: number; attachments: number; pending_attachments: number } | null
      }
    },
    refetchInterval: 60000,
  })

  if (!data) return <p>Memuat kesehatan sistem…</p>

  return (
    <section>
      <div className="section-head"><div>
        <div className="eyebrow">SISTEM</div>
        <h2>Kesehatan Operasional</h2>
        <p>Diperiksa: {new Date(data.server_time).toLocaleString('id-ID')}</p>
      </div></div>

      <div className="dashboard-grid">
        <article className="dash-card">
          <div className="dash-label">Ukuran Database</div>
          <div className="dash-value">{data.db_size_mb} MB</div>
          <div className="dash-sub">Batas paket: 500 MB</div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Backup Terakhir</div>
          <div className={`dash-value ${data.last_backup?.status === 'SUCCEEDED' ? 'open' : 'warn'}`}>
            {data.last_backup?.status || 'Belum ada'}
          </div>
          {data.last_backup && <div className="dash-sub">{new Date(data.last_backup.started_at).toLocaleString('id-ID')}</div>}
        </article>
        {data.detail && <>
          <article className="dash-card"><div className="dash-label">Produk Aktif</div><div className="dash-value">{data.detail.products}</div></article>
          <article className="dash-card"><div className="dash-label">Total Nota</div><div className="dash-value">{data.detail.invoices}</div></article>
          <article className="dash-card"><div className="dash-label">Total Tiket</div><div className="dash-value">{data.detail.tickets}</div></article>
          <article className="dash-card">
            <div className="dash-label">Lampiran</div>
            <div className={`dash-value ${data.detail.pending_attachments > 0 ? 'warn' : ''}`}>{data.detail.attachments}</div>
            <div className="dash-sub">{data.detail.pending_attachments} menunggu</div>
          </article>
        </>}
      </div>
    </section>
  )
}
