import { NavLink } from 'react-router-dom'

/** Tautan antar-halaman dalam satu modul (mis. Stok: Posisi, Koreksi, Hitung, Riwayat). */
export function SubNav({ label, items }: { label: string; items: { to: string; label: string; end?: boolean }[] }) {
  if (items.length < 2) return null
  return (
    <nav className="sub-nav" aria-label={label}>
      {items.map(item => (
        <NavLink key={item.to} to={item.to} end={item.end ?? true}
          className={({ isActive }) => `sub-nav-link${isActive ? ' is-active' : ''}`}>
          {item.label}
        </NavLink>
      ))}
    </nav>
  )
}
