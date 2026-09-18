import { describe, expect, it } from 'vitest'
import { testProfile } from '../../test/render'
import { access } from './access'
import { homePath, navGroups, navLabel } from './nav'

const paths = (role: 'OWNER' | 'STAFF' | 'MAINTAINER') =>
  navGroups(testProfile(role)).flatMap(g => g.items.map(i => i.to))

describe('menu per peran', () => {
  it('karyawan: kasir, servis, kas laci, laporan tanpa modal; tanpa pengaturan/koreksi/stok masuk', () => {
    const staff = paths('STAFF')
    expect(staff).toEqual(expect.arrayContaining(['/kasir', '/riwayat', '/servis', '/pelanggan', '/kas', '/laporan']))
    for (const hidden of ['/barang-masuk', '/kas/koreksi', '/kas/riwayat', '/pengaturan', '/kesehatan', '/distributor']) {
      expect(staff).not.toContain(hidden)
    }
    const kas = navGroups(testProfile('STAFF')).flatMap(g => g.items).find(i => i.to === '/kas')
    expect(kas && navLabel(kas, testProfile('STAFF'))).toBe('Kas Laci Toko')
  })
  it('akun teknis tidak bisa menjual atau memproses retur', () => {
    expect(paths('MAINTAINER')).not.toContain('/kasir')
    expect(access.returnSale(testProfile('MAINTAINER'))).toBe(false)
    expect(access.health(testProfile('MAINTAINER'))).toBe(true)
  })
  it('pemilik melihat semua menu', () => {
    expect(paths('OWNER')).toEqual(expect.arrayContaining([
      '/kasir', '/barang-masuk', '/stok', '/distributor/retur', '/kas/koreksi', '/laporan', '/pengaturan', '/kesehatan',
    ]))
  })
  it('halaman awal karyawan adalah kasir', () => {
    expect(homePath(testProfile('STAFF'))).toBe('/kasir')
    expect(homePath(testProfile('OWNER'))).toBe('/beranda')
  })
})
