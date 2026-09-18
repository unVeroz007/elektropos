import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { ROLE_LABEL, useProfile } from '../../lib/session'
import { OFFLINE_MESSAGES, useOnlineStatus } from '../../lib/online'
import { navGroups, navLabel, type NavGroup } from './nav'

export function OnlineIndicator() {
  const online = useOnlineStatus()
  return (
    <span className={`online-indicator ${online ? 'is-online' : 'is-offline'}`} role="status">
      <span className="online-dot" aria-hidden="true" />
      {online ? 'Terhubung' : 'Internet terputus'}
    </span>
  )
}

function NavList({ groups, onNavigate }: { groups: NavGroup[]; onNavigate?: () => void }) {
  const profile = useProfile()
  return (
    <>
      {groups.map(group => (
        <div className="nav-group" key={group.label}>
          <span className="nav-group-label">{group.label}</span>
          {group.items.map(item => (
            <NavLink key={item.to} to={item.to} end={item.exact ?? false} onClick={onNavigate}
              className={({ isActive }) => `nav-link${isActive ? ' is-active' : ''}`}>
              {navLabel(item, profile)}
            </NavLink>
          ))}
        </div>
      ))}
    </>
  )
}

function LogoutButton({ onLogout }: { onLogout: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  return (
    <button type="button" className="ui-button ui-button-secondary shell-logout" disabled={busy}
      onClick={async () => { setBusy(true); try { await onLogout() } finally { setBusy(false) } }}>
      {busy ? 'Keluar…' : 'Keluar'}
    </button>
  )
}

/** Menu laci untuk layar HP (≤768px): tombol besar, tertutup saat pindah halaman atau Escape. */
function MobileMenu({ groups, onClose, onLogout }: { groups: NavGroup[]; onClose: () => void; onLogout: () => Promise<void> }) {
  const panel = useRef<HTMLDivElement>(null)
  useEffect(() => {
    panel.current?.querySelector<HTMLElement>('a, button')?.focus()
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])
  return (
    <div className="mobile-menu-backdrop" onClick={onClose}>
      <div ref={panel} className="mobile-menu" role="dialog" aria-modal="true" aria-label="Menu"
        onClick={e => e.stopPropagation()}>
        <div className="mobile-menu-head">
          <strong>Menu</strong>
          <button type="button" className="ui-button ui-button-secondary" onClick={onClose}>Tutup</button>
        </div>
        <nav aria-label="Menu utama">
          <NavList groups={groups} onNavigate={onClose} />
        </nav>
        <LogoutButton onLogout={onLogout} />
      </div>
    </div>
  )
}

export function AppShell({ children, onLogout }: { children: ReactNode; onLogout: () => Promise<void> }) {
  const profile = useProfile()
  const groups = navGroups(profile)
  const online = useOnlineStatus()
  const location = useLocation()
  const [menuOpen, setMenuOpen] = useState(false)
  const closeMenu = useCallback(() => setMenuOpen(false), [])
  const [menuPath, setMenuPath] = useState(location.pathname)
  if (menuPath !== location.pathname) {
    setMenuPath(location.pathname)
    setMenuOpen(false)
  }

  return (
    <div className="shell">
      <aside className="shell-sidebar no-print">
        <div className="shell-brand">
          <span className="shell-brand-mark" aria-hidden="true">E</span>
          <div><strong>ElektroPOS</strong><small>Toko listrik &amp; servis</small></div>
        </div>
        <nav aria-label="Menu utama" className="shell-nav">
          <NavList groups={groups} />
        </nav>
      </aside>

      <div className="shell-main">
        <header className="shell-header no-print">
          <button type="button" className="ui-button ui-button-secondary shell-menu-button" aria-expanded={menuOpen}
            onClick={() => setMenuOpen(true)}>
            Menu
          </button>
          <div className="shell-user">
            <strong>{profile.display_name}</strong>
            <span className="shell-role">{ROLE_LABEL[profile.role]}</span>
          </div>
          <OnlineIndicator />
          <div className="shell-header-logout"><LogoutButton onLogout={onLogout} /></div>
        </header>
        {!online && <div className="offline-banner no-print" role="alert">{OFFLINE_MESSAGES.banner}</div>}
        <main className="shell-content">{children}</main>
      </div>

      {menuOpen && <MobileMenu groups={groups} onClose={closeMenu} onLogout={onLogout} />}
    </div>
  )
}
