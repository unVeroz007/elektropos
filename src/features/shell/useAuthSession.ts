import { useCallback, useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../../lib/supabase'
import { readRpc } from '../../lib/rpc'
import { toAppError } from '../../lib/errors'
import type { Profile } from '../../lib/session'

export type AuthState =
  | { status: 'loading' }
  | { status: 'signedOut'; notice?: string }
  | { status: 'error'; message: string }
  | { status: 'signedIn'; profile: Profile }

export const INACTIVE_NOTICE = 'Akun Anda sedang tidak aktif atau belum didaftarkan untuk toko ini. Hubungi pemilik toko untuk mengaktifkannya.'

/**
 * Sesi login + profil (FR-AUTH-01). Akun nonaktif langsung dikeluarkan dengan pesan jelas.
 * Keluar selalu membersihkan cache data agar akun berikutnya tidak melihat data lama (S13).
 */
export function useAuthSession() {
  const queryClient = useQueryClient()
  const [state, setState] = useState<AuthState>(() => supabase ? { status: 'loading' } : { status: 'signedOut' })
  const userId = useRef<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    const client = supabase
    if (!client) return
    let alive = true

    const apply = async (session: Session | null) => {
      if (!session) {
        if (userId.current !== null) queryClient.clear()
        userId.current = null
        if (alive) setState(s => s.status === 'signedOut' ? s : { status: 'signedOut' })
        return
      }
      if (userId.current === session.user.id) return
      if (userId.current !== null) queryClient.clear()
      userId.current = session.user.id
      try {
        const profile = await readRpc<Profile>('get_current_profile_v1')
        if (!profile.active) throw new Error('ACCOUNT_INACTIVE: Akun tidak aktif')
        if (alive) setState({ status: 'signedIn', profile })
      } catch (err) {
        const error = toAppError(err as Error)
        userId.current = null
        if (error.kind === 'auth') {
          await client.auth.signOut({ scope: 'local' })
          queryClient.clear()
          if (alive) setState({ status: 'signedOut', notice: INACTIVE_NOTICE })
        } else if (alive) {
          setState({ status: 'error', message: error.display })
        }
      }
    }

    const { data } = client.auth.onAuthStateChange((_event, session) => {
      // Jangan memanggil Supabase langsung di dalam callback (dapat mengunci sesi).
      setTimeout(() => { void apply(session) }, 0)
    })
    return () => {
      alive = false
      data.subscription.unsubscribe()
    }
  }, [queryClient, attempt])

  const logout = useCallback(async () => {
    try {
      await supabase?.auth.signOut({ scope: 'local' })
    } finally {
      userId.current = null
      queryClient.clear()
      setState({ status: 'signedOut' })
    }
  }, [queryClient])

  const retry = useCallback(() => {
    userId.current = null
    setState({ status: 'loading' })
    setAttempt(n => n + 1)
  }, [])

  return { state, logout, retry }
}
