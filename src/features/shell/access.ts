import { hasRole, permissions, type Profile } from '../../lib/session'

/**
 * Siapa yang boleh membuka halaman apa. Dipakai menu dan penjaga route agar
 * keduanya selalu sama. Server tetap otoritatif untuk setiap perintah.
 */
export type AccessRule = (profile: Profile) => boolean

const everyone: AccessRule = () => true

export const access = {
  dashboard: everyone,
  cashier: permissions.sell,
  history: everyone,
  returnSale: permissions.processReturn,
  service: everyone,
  customers: (p: Profile) => hasRole(p, 'OWNER', 'STAFF'),
  catalog: everyone,
  catalogEdit: permissions.manageCatalog,
  intake: permissions.manageStock,
  stock: everyone,
  stockEdit: permissions.manageStock,
  stockCount: (p: Profile) => hasRole(p, 'OWNER', 'MAINTAINER'),
  suppliers: (p: Profile) => hasRole(p, 'OWNER', 'MAINTAINER'),
  suppliersEdit: (p: Profile) => hasRole(p, 'OWNER'),
  cash: everyone,
  cashHistory: (p: Profile) => hasRole(p, 'OWNER', 'MAINTAINER'),
  cashManage: permissions.manageCash,
  reports: permissions.viewReports,
  settings: permissions.manageSettings,
  health: permissions.viewHealth,
} satisfies Record<string, AccessRule>

export type AccessKey = keyof typeof access
