import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { useQuery } from '@tanstack/react-query'

export function CashSession() {

  const [counted, setCounted] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const { data: session, refetch, isLoading } = useQuery({
    queryKey: ['cash_session'],
    queryFn: async () => {
      if (!supabase) return null
      const { data } = await supabase.rpc('get_cash_session_v1', { p_input: { cashbox_code: 'SHOP_DRAWER' } })
      return data as {
        open: boolean
        id?: string
        cashbox_code?: string
        opened_at?: string
        opening_amount?: string
        expected?: string
        status?: string
        version?: number
      }
    }
  })

  async function openSession() {
    if (!supabase) return
    setBusy(true); setError('')
    try {
      const { data, error } = await supabase.rpc('open_cash_session_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          cashbox_code: 'SHOP_DRAWER',
          opening_amount: counted || '0'
        }
      })
      if (error) throw new Error(error.message)
      const res = data as { ok?: boolean }
      if (res?.ok) {
        setCounted('')
        refetch()
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal membuka kas')
    } finally {
      setBusy(false)
    }
  }

  async function closeSession() {
    if (!supabase || !session?.id) return
    setBusy(true); setError('')
    try {
      const { data, error } = await supabase.rpc('close_cash_session_v1', {
        p_input: {
          operation_id: crypto.randomUUID(),
          session_id: session.id,
          expected_version: session.version,
          counted_amount: counted,
          note
        }
      })
      if (error) throw new Error(error.message)
      const res = data as { ok?: boolean; variance?: string }
      if (res?.ok) {
        setCounted('')
        setNote('')
        refetch()
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Gagal menutup kas')
    } finally {
      setBusy(false)
    }
  }

  if (isLoading) return <p>Memuat sesi kas…</p>

  return (
    <section className="cash-session-page">
      <div className="section-head">
        <div>
          <div className="eyebrow">KAS LACI</div>
          <h2>Buka / Tutup Sesi Kas</h2>
          <p>Hitung saldo awal dan saldo akhir fisik laci kas.</p>
        </div>
      </div>

      {session?.open ? (
        <div className="session-card open">
          <div className="status-badge open">SESI DIBUKA</div>
          <div className="info-row">
            <span>Waktu buka: {new Date(session.opened_at || '').toLocaleString('id-ID')}</span>
            <span>Saldo awal: Rp{Number(session.opening_amount).toLocaleString('id-ID')}</span>
          </div>
          <div className="info-row highlight">
            <span>Saldo seharusnya (sistem):</span>
            <strong>Rp{Number(session.expected).toLocaleString('id-ID')}</strong>
          </div>

          <div className="close-form">
            <h3>Tutup Sesi Kas</h3>
            <label>Hitungan fisik laci (Rupiah)
              <input
                type="number"
                value={counted}
                onChange={e => setCounted(e.target.value)}
                placeholder="Jumlah uang tunai fisik"
              />
            </label>

            {counted && (
              <div className="variance-preview">
                Selisih: <strong>Rp{(Number(counted) - Number(session.expected)).toLocaleString('id-ID')}</strong>
              </div>
            )}

            <label>Keterangan / Alasan selisih (jika ada)
              <input
                value={note}
                onChange={e => setNote(e.target.value)}
                placeholder="Alasan selisih..."
              />
            </label>

            {error && <div className="error" role="alert">{error}</div>}

            <button onClick={closeSession} disabled={!counted || busy} className="primary">
              {busy ? 'Menutup…' : 'Tutup Sesi Kas'}
            </button>
          </div>
        </div>
      ) : (
        <div className="session-card closed">
          <div className="status-badge closed">SESI DITUTUP</div>
          <p>Sesi kas saat ini belum dibuka. Buka sesi baru untuk memulai penjualan tunai.</p>

          <div className="open-form">
            <label>Saldo awal Laci (Rupiah)
              <input
                type="number"
                value={counted}
                onChange={e => setCounted(e.target.value)}
                placeholder="Saldo awal tunai"
              />
            </label>

            {error && <div className="error" role="alert">{error}</div>}

            <button onClick={openSession} disabled={busy} className="primary">
              {busy ? 'Membuka…' : 'Buka Sesi Kas'}
            </button>
          </div>
        </div>
      )}
    </section>
  )
}
