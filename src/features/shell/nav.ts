import type { Profile } from '../../lib/session'
import { access, type AccessKey } from './access'

/** `exact`: hanya aktif pada alamat persis (menu yang punya submenu sendiri). */
export type NavItem = { to: string; label: string; access: AccessKey; exact?: boolean }
export type NavGroup = { label: string; items: NavItem[] }

/** Menu berkelompok dengan label awam (UX-01). Urutan = prioritas pemakaian harian. */
const NAV: NavGroup[] = [
  {
    label: 'Harian',
    items: [
      { to: '/beranda', label: 'Beranda', access: 'dashboard' },
      { to: '/kasir', label: 'Kasir', access: 'cashier' },
      { to: '/riwayat', label: 'Riwayat Nota', access: 'history' },
    ],
  },
  {
    label: 'Servis',
    items: [
      { to: '/servis', label: 'Servis', access: 'service' },
      { to: '/pelanggan', label: 'Pelanggan', access: 'customers' },
    ],
  },
  {
    label: 'Barang',
    items: [
      { to: '/katalog', label: 'Katalog', access: 'catalog' },
      { to: '/barang-masuk', label: 'Barang Masuk', access: 'intake' },
      { to: '/stok', label: 'Stok', access: 'stock' },
      { to: '/distributor', label: 'Distributor', access: 'suppliers', exact: true },
      { to: '/distributor/retur', label: 'Retur ke Distributor', access: 'suppliers' },
    ],
  },
  {
    label: 'Uang',
    items: [
      { to: '/kas', label: 'Kas', access: 'cash', exact: true },
      { to: '/kas/riwayat', label: 'Riwayat Kas', access: 'cashHistory' },
      { to: '/kas/koreksi', label: 'Koreksi Cara Bayar', access: 'cashManage' },
      { to: '/laporan', label: 'Laporan', access: 'reports' },
    ],
  },
  {
    label: 'Toko',
    items: [
      { to: '/pengaturan', label: 'Pengaturan', access: 'settings' },
      { to: '/kesehatan', label: 'Kesehatan & Backup', access: 'health' },
    ],
  },
]

/** Menu yang boleh dilihat profil ini; kelompok kosong dibuang. */
export function navGroups(profile: Profile): NavGroup[] {
  return NAV
    .map(group => ({ ...group, items: group.items.filter(item => access[item.access](profile)) }))
    .filter(group => group.items.length > 0)
}

/** Label menu Kas sesuai peran: karyawan hanya memegang laci toko (D1). */
export function navLabel(item: NavItem, profile: Profile): string {
  if (item.to === '/kas' && profile.role === 'STAFF') return 'Kas Laci Toko'
  return item.label
}

/** Halaman awal: karyawan langsung ke kasir, lainnya ke beranda (UX-01). */
export function homePath(profile: Profile): string {
  return profile.role === 'STAFF' ? '/kasir' : '/beranda'
}
