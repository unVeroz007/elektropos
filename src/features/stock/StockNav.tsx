import { useProfile } from '../../lib/session'
import { SubNav } from '../../components/SubNav'
import { access } from '../shell/access'

export function StockNav() {
  const profile = useProfile()
  const items = [
    { to: '/stok', label: 'Posisi stok' },
    ...(access.stockEdit(profile) ? [{ to: '/stok/koreksi', label: 'Koreksi stok' }] : []),
    ...(access.stockCount(profile) ? [{ to: '/stok/hitung', label: 'Hitung stok', end: false }] : []),
    { to: '/stok/riwayat', label: 'Riwayat mutasi' },
  ]
  return <SubNav label="Menu stok" items={items} />
}
