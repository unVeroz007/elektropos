import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

export function Dashboard() {
  const { data, error, isLoading } = useQuery({
    queryKey: ['dashboard'],
    queryFn: async () => {
      if (!supabase) return null
      const { data } = await supabase.rpc('get_dashboard_v1', { p_input: {} })
      return data as {
        refreshed_at: string; server_date: string;
        sales_total: string; sales_count: number; refund_total: string;
        receipts_cash: string; receipts_transfer: string;
        cash_session_open: boolean; low_stock: number
      }
    },
    refetchInterval: 30000,
  })

  if (isLoading) return <p>Memuat dashboard…</p>
  if (error || !data) return <div className="error">Gagal memuat dashboard</div>

  return (
    <section>
      <div className="section-head">
        <div>
          <div className="eyebrow">RINGKASAN</div>
          <h2>Beranda</h2>
          <p>Data per {data.server_date}. Diperbarui: {new Date(data.refreshed_at).toLocaleString('id-ID')}</p>
        </div>
      </div>
      <div className="dashboard-grid">
        <article className="dash-card">
          <div className="dash-label">Penjualan Hari Ini</div>
          <div className="dash-value">Rp{Number(data.sales_total).toLocaleString('id-ID')}</div>
          <div className="dash-sub">{data.sales_count} transaksi</div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Refund</div>
          <div className="dash-value neg">Rp{Number(data.refund_total).toLocaleString('id-ID')}</div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Tunai Masuk</div>
          <div className="dash-value">Rp{Number(data.receipts_cash).toLocaleString('id-ID')}</div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Transfer/QRIS</div>
          <div className="dash-value">Rp{Number(data.receipts_transfer).toLocaleString('id-ID')}</div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Status Kas Laci</div>
          <div className={`dash-value ${data.cash_session_open ? 'open' : 'closed'}`}>
            {data.cash_session_open ? 'Terbuka' : 'Tutup'}
          </div>
        </article>
        <article className="dash-card">
          <div className="dash-label">Stok Rendah</div>
          <div className={`dash-value ${data.low_stock > 0 ? 'warn' : ''}`}>
            {data.low_stock} produk
          </div>
        </article>
      </div>
    </section>
  )
}

export function Reports() {
  const today = new Date()
  const weekAgo = new Date(today); weekAgo.setDate(weekAgo.getDate() - 7)
  const [start, setStart] = useState(weekAgo.toISOString().slice(0, 10))
  const [end, setEnd] = useState(today.toISOString().slice(0, 10))

  const { data, refetch } = useQuery({
    queryKey: ['report', start, end],
    queryFn: async () => {
      if (!supabase) return null
      const { data } = await supabase.rpc('get_report_v1', { p_input: { start_date: start, end_date: end } })
      return data as {
        start: string; end: string;
        sales_net: string; service_net: string; credit_total: string;
        receipts: string; refunds: string; cogs: string | null
      }
    },
    enabled: Boolean(start && end),
  })

  if (!data) return <p>Memuat laporan…</p>

  return (
    <section>
      <div className="section-head"><div>
        <div className="eyebrow">LAPORAN</div>
        <h2>Laporan Operasional</h2>
      </div></div>
      <div className="filter-group">
        <label>Dari<input type="date" value={start} onChange={e => setStart(e.target.value)} /></label>
        <label>Sampai<input type="date" value={end} onChange={e => setEnd(e.target.value)} /></label>
        <button onClick={() => refetch()}>Tampilkan</button>
      </div>
      <div className="report-grid">
        <div className="report-row"><span>Penjualan Barang (neto)</span><span>Rp{Number(data.sales_net).toLocaleString('id-ID')}</span></div>
        <div className="report-row"><span>Jasa/Servis (neto)</span><span>Rp{Number(data.service_net).toLocaleString('id-ID')}</span></div>
        <div className="report-row"><span>Kredit/Retur</span><span className="neg">Rp{Number(data.credit_total).toLocaleString('id-ID')}</span></div>
        <div className="report-row"><span>Penerimaan Pelanggan</span><span>Rp{Number(data.receipts).toLocaleString('id-ID')}</span></div>
        <div className="report-row"><span>Refund</span><span className="neg">Rp{Number(data.refunds).toLocaleString('id-ID')}</span></div>
        {data.cogs && <div className="report-row total"><span>COGS</span><span>Rp{Number(data.cogs).toLocaleString('id-ID')}</span></div>}
      </div>

      <div className="report-export">
        <button onClick={async () => {
          if (!supabase) return
          const { data: res } = await supabase.rpc('export_csv_v1', {
            p_input: { dataset: 'invoices', start_date: start, end_date: end, limit: 1000 },
          })
          if (res?.rows && Array.isArray(res.rows) && res.rows.length > 0) {
            const headers = Object.keys(res.rows[0]).join(',')
            const csv = [headers, ...res.rows.map((r: Record<string, string>) =>
              Object.values(r).map(v => String(v)).join(',')
            )].join('\n')
            const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' })
            const url = URL.createObjectURL(blob)
            const a = document.createElement('a')
            a.href = url
            a.download = `elektropos-laporan-${start}-${end}.csv`
            a.click()
            URL.revokeObjectURL(url)
          }
        }}>Ekspor CSV</button>
      </div>
    </section>
  )
}
