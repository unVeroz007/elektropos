import { lazy, Suspense, type ComponentType, type ReactNode } from 'react'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { ProfileProvider, useProfile } from './lib/session'
import { Loading } from './components/ui'
import { AppShell } from './features/shell/AppShell'
import { LoginPage } from './features/shell/LoginPage'
import { PageBoundary } from './features/shell/PageBoundary'
import { NotFoundPage, RequireAccess } from './features/shell/guards'
import { homePath } from './features/shell/nav'
import type { AccessKey } from './features/shell/access'
import { useAuthSession } from './features/shell/useAuthSession'

/**
 * Halaman dimuat saat dibuka (lazy). Halaman modul lain (penjualan, servis) dianggap
 * tanpa props: profil dibaca lewat `useProfile()`, parameter lewat `useParams()`.
 */
function lazyPage<M>(load: () => Promise<M>, pick: (module: M) => unknown) {
  return lazy(async () => ({ default: pick(await load()) as ComponentType }))
}

const sales = () => import('./features/sales')
const service = () => import('./features/service')
const catalog = () => import('./features/catalog')
const stock = () => import('./features/stock')
const cash = () => import('./features/cash')
const suppliers = () => import('./features/suppliers')
const reports = () => import('./features/reports')
const settings = () => import('./features/settings')

const CashierPage = lazyPage(sales, m => m.CashierPage)
const ReceiptPage = lazyPage(sales, m => m.ReceiptPage)
const HistoryPage = lazyPage(sales, m => m.HistoryPage)
const ReturnPage = lazyPage(sales, m => m.ReturnPage)
const ServicePage = lazyPage(service, m => m.ServicePage)
const CustomersPage = lazyPage(service, m => m.CustomersPage)
const CatalogPage = lazyPage(catalog, m => m.CatalogPage)
const ProductDetailPage = lazyPage(catalog, m => m.ProductDetailPage)
const ProductFormPage = lazyPage(catalog, m => m.ProductFormPage)
const CatalogImportPage = lazyPage(catalog, m => m.CatalogImportPage)
const CategoriesPage = lazyPage(catalog, m => m.CategoriesPage)
const IntakePage = lazyPage(stock, m => m.IntakePage)
const StockPositionsPage = lazyPage(stock, m => m.StockPositionsPage)
const StockAdjustPage = lazyPage(stock, m => m.StockAdjustPage)
const StockCountListPage = lazyPage(stock, m => m.StockCountListPage)
const StockCountPage = lazyPage(stock, m => m.StockCountPage)
const StockMovementsPage = lazyPage(stock, m => m.StockMovementsPage)
const CashPage = lazyPage(cash, m => m.CashPage)
const CashHistoryPage = lazyPage(cash, m => m.CashHistoryPage)
const CorrectPaymentPage = lazyPage(cash, m => m.CorrectPaymentPage)
const SuppliersPage = lazyPage(suppliers, m => m.SuppliersPage)
const SupplierReturnsPage = lazyPage(suppliers, m => m.SupplierReturnsPage)
const DashboardPage = lazyPage(reports, m => m.DashboardPage)
const ReportPage = lazyPage(reports, m => m.ReportPage)
const SettingsPage = lazyPage(settings, m => m.SettingsPage)
const HealthPage = lazyPage(settings, m => m.HealthPage)

type PageRoute = { path: string; page: ComponentType; access: AccessKey }

const PAGES: PageRoute[] = [
  { path: '/beranda', page: DashboardPage, access: 'dashboard' },
  { path: '/kasir', page: CashierPage, access: 'cashier' },
  { path: '/struk/:invoiceId', page: ReceiptPage, access: 'history' },
  { path: '/riwayat', page: HistoryPage, access: 'history' },
  { path: '/retur/:invoiceId', page: ReturnPage, access: 'returnSale' },
  { path: '/servis', page: ServicePage, access: 'service' },
  { path: '/servis/:ticketId', page: ServicePage, access: 'service' },
  { path: '/pelanggan', page: CustomersPage, access: 'customers' },
  { path: '/katalog', page: CatalogPage, access: 'catalog' },
  { path: '/katalog/baru', page: ProductFormPage, access: 'catalogEdit' },
  { path: '/katalog/impor', page: CatalogImportPage, access: 'catalogEdit' },
  { path: '/katalog/kategori', page: CategoriesPage, access: 'catalogEdit' },
  { path: '/katalog/:productId', page: ProductDetailPage, access: 'catalog' },
  { path: '/katalog/:productId/ubah', page: ProductFormPage, access: 'catalogEdit' },
  { path: '/barang-masuk', page: IntakePage, access: 'intake' },
  { path: '/stok', page: StockPositionsPage, access: 'stock' },
  { path: '/stok/koreksi', page: StockAdjustPage, access: 'stockEdit' },
  { path: '/stok/hitung', page: StockCountListPage, access: 'stockCount' },
  { path: '/stok/hitung/:countId', page: StockCountPage, access: 'stockCount' },
  { path: '/stok/riwayat', page: StockMovementsPage, access: 'stock' },
  { path: '/distributor', page: SuppliersPage, access: 'suppliers' },
  { path: '/distributor/retur', page: SupplierReturnsPage, access: 'suppliers' },
  { path: '/kas', page: CashPage, access: 'cash' },
  { path: '/kas/riwayat', page: CashHistoryPage, access: 'cashHistory' },
  { path: '/kas/koreksi', page: CorrectPaymentPage, access: 'cashManage' },
  { path: '/laporan', page: ReportPage, access: 'reports' },
  { path: '/pengaturan', page: SettingsPage, access: 'settings' },
  { path: '/kesehatan', page: HealthPage, access: 'health' },
]

/** Satu halaman: penjaga peran + penangkap error yang direset saat pindah alamat. */
function PageFrame({ children }: { children: ReactNode }) {
  const location = useLocation()
  return (
    <PageBoundary key={location.pathname}>
      <Suspense fallback={<Loading label="Memuat halaman…" />}>{children}</Suspense>
    </PageBoundary>
  )
}

export function AppRoutes() {
  const profile = useProfile()
  return (
    <Routes>
      <Route path="/" element={<Navigate to={homePath(profile)} replace />} />
      {PAGES.map(({ path, page: Page, access }) => (
        <Route key={path} path={path} element={
          <PageFrame><RequireAccess rule={access}><Page /></RequireAccess></PageFrame>
        } />
      ))}
      <Route path="/produk/baru" element={<Navigate to="/katalog/baru" replace />} />
      <Route path="/barcode" element={<Navigate to="/katalog" replace />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}

export default function App() {
  const { state, logout, retry } = useAuthSession()
  const navigate = useNavigate()

  if (state.status === 'loading') return <div className="fullscreen-message"><Loading label="Menghubungkan ElektroPOS…" /></div>
  if (state.status === 'error') {
    return (
      <div className="fullscreen-message">
        <div className="ui-alert ui-alert-error" role="alert">Profil akun belum bisa dibaca. {state.message}</div>
        <button type="button" className="ui-button ui-button-primary" onClick={retry}>Coba lagi</button>
      </div>
    )
  }
  if (state.status === 'signedOut') return <LoginPage notice={state.notice} />

  async function handleLogout() {
    await logout()
    navigate('/', { replace: true })
  }

  return (
    <ProfileProvider profile={state.profile}>
      <AppShell onLogout={handleLogout}>
        <AppRoutes />
      </AppShell>
    </ProfileProvider>
  )
}
