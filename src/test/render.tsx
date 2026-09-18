import type { ReactElement } from 'react'
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { ProfileProvider, type Profile, type Role } from '../lib/session'

export const testProfile = (role: Role = 'OWNER'): Profile => ({
  id: `${role.toLowerCase()}-id`, display_name: `Uji ${role}`, role, active: true, version: 1,
})

/**
 * Render halaman dalam lingkungan aplikasi (query client tanpa retry, router,
 * profil). `path` memungkinkan pengujian route berparameter.
 */
export function renderPage(ui: ReactElement, options: { role?: Role; url?: string; path?: string } = {}) {
  const { role = 'OWNER', url = '/', path = '*' } = options
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const result = render(
    <QueryClientProvider client={queryClient}>
      <ProfileProvider profile={testProfile(role)}>
        <MemoryRouter initialEntries={[url]}>
          <Routes>
            <Route path={path} element={ui} />
          </Routes>
        </MemoryRouter>
      </ProfileProvider>
    </QueryClientProvider>,
  )
  return { ...result, queryClient }
}
