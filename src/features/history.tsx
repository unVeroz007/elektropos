import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useQuery } from '@tanstack/react-query'

type Invoice = {
  id: string
  number: string
  kind: 'SALE' | 'SERVICE'
  posted_at: string
  subtotal_net_lines: string
  discount_total: string
  total: string
  payment_status?: string
}

export function History() {
  const navigate = useNavigate()

  const [startDate, setStartDate] = useState(() => {
    const d = new Date()
    d.setDate(d.getDate() - 7)
    return d.toISOString().slice(0, 10)
  })
  const [endDate, setEndDate] = useState(() => new Date().toISOString().slice(0, 10))
  const [page, setPage] = useState(0)
  const limit = 25

  const { data: invoices, error, isLoading } = useQuery({
    queryKey: ['invoices', startDate, endDate, page],
    queryFn: async () => {
      if (!supabase) return []
      const { data } = await supabase.rpc('list_invoices_v1', {
        p_input: {
          start_date: startDate,
          end_date: endDate,
          offset: page * limit,
          limit
        }
      })
      return (data as Invoice[]) ?? []
    }
  })

  if (error) return <div className="error">Gagal memuat riwayat</div>

  return (
    <section>
      <div className="section-head">
        <div>
          <div className="eyebrow">RIWAYAT</div>
          <h2>Transaksi</h2>
          <p>Riwayat penjualan, servis, dan refund.</p>
        </div>
      </div>

      <div className="filter-group">
        <label>Tanggal mulai
          <input
            type="date"
            value={startDate}
            onChange={e => { setStartDate(e.target.value); setPage(0) }}
          />
        </label>
        <label>Tanggal akhir
          <input
            type="date"
            value={endDate}
            onChange={e => { setEndDate(e.target.value); setPage(0) }}
          />
        </label>
        <button onClick={() => setPage(Math.max(0, page - 1))} disabled={page === 0}>Sebelumnya</button>
        <button onClick={() => setPage(page + 1)}>Berikutnya</button>
      </div>

      {isLoading && <p>Memuat…</p>}

      {!isLoading && invoices && invoices.length === 0 && (
        <div className="empty">Tidak ada transaksi pada periode ini.</div>
      )}

      {invoices && (
        <div className="invoice-list">
          {invoices.map(inv => (
            <article key={inv.id} className="invoice-card" onClick={() => navigate('/struk/' + inv.id)}>
              <div className="invoice-header">
                <strong>{inv.number}</strong>
                <span className={`payment-badge ${inv.payment_status?.toLowerCase()}`}>
                  {inv.payment_status || '-'}
                </span>
              </div>
              <div className="invoice-details">
                <span>{new Date(inv.posted_at).toLocaleString('id-ID')}</span>
                <span className="total">Rp{Number(inv.total).toLocaleString('id-ID')}</span>
              </div>
              <div className="invoice-footer">
                <span>{inv.kind === 'SALE' ? 'Penjualan' : 'Servis'}</span>
                <span>Diskon: Rp{Number(inv.discount_total).toLocaleString('id-ID')}</span>
              </div>
            </article>
          ))}
        </div>
      )}

      {invoices && invoices.length === limit && (
        <div className="pagination">
          <span>Halaman {page + 1}</span>
        </div>
      )}
    </section>
  )
}
