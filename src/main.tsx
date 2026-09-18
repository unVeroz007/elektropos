import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import App from './App'
import { toAppError } from './lib/errors'
import './styles/tokens.css'
import './style.css'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      refetchOnWindowFocus: true,
      // Penolakan izin/aturan bisnis tidak akan berubah bila diulang; hanya gangguan jaringan yang dicoba lagi.
      retry: (failureCount, error) => toAppError(error).kind === 'network' && failureCount < 2,
    },
  },
})

const root = document.getElementById('root')
if (!root) throw new Error('Elemen #root tidak ditemukan di index.html')

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
)
