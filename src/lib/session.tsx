import { createContext, useContext, type ReactNode } from 'react'

export type Role = 'OWNER' | 'STAFF' | 'MAINTAINER'

export type Profile = {
  id: string
  display_name: string
  role: Role
  active: boolean
  version?: number
}

export const ROLE_LABEL: Record<Role, string> = {
  OWNER: 'Pemilik',
  STAFF: 'Karyawan',
  MAINTAINER: 'Teknis',
}

const ProfileContext = createContext<Profile | null>(null)

export function ProfileProvider({ profile, children }: { profile: Profile; children: ReactNode }) {
  return <ProfileContext.Provider value={profile}>{children}</ProfileContext.Provider>
}

/** Profil akun yang sedang masuk. Hanya dipakai di dalam halaman setelah login. */
export function useProfile(): Profile {
  const profile = useContext(ProfileContext)
  if (!profile) throw new Error('useProfile dipakai di luar ProfileProvider')
  return profile
}

export function hasRole(profile: Profile, ...roles: Role[]): boolean {
  return roles.includes(profile.role)
}

/**
 * Izin tampilan. Server tetap otoritatif; ini hanya menyembunyikan tombol
 * yang pasti ditolak agar pengguna tidak bingung.
 */
export const permissions = {
  sell: (p: Profile) => hasRole(p, 'OWNER', 'STAFF'),
  giveDiscount: (p: Profile) => hasRole(p, 'OWNER'),
  processReturn: (p: Profile) => hasRole(p, 'OWNER'),
  manageCatalog: (p: Profile) => hasRole(p, 'OWNER'),
  manageStock: (p: Profile) => hasRole(p, 'OWNER'),
  openShopDrawer: (p: Profile) => hasRole(p, 'OWNER', 'STAFF'),
  manageFatherWallet: (p: Profile) => hasRole(p, 'OWNER'),
  manageCash: (p: Profile) => hasRole(p, 'OWNER'),
  viewCost: (p: Profile) => hasRole(p, 'OWNER', 'MAINTAINER'),
  viewReports: (p: Profile) => hasRole(p, 'OWNER', 'STAFF', 'MAINTAINER'),
  manageService: (p: Profile) => hasRole(p, 'OWNER'),
  receiveService: (p: Profile) => hasRole(p, 'OWNER', 'STAFF'),
  manageSettings: (p: Profile) => hasRole(p, 'OWNER'),
  viewHealth: (p: Profile) => hasRole(p, 'OWNER', 'MAINTAINER'),
}
