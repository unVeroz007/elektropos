import { useQuery } from '@tanstack/react-query'
import { readRpc } from '../../lib/rpc'
import type { Category, ProductDetail } from '../../components/productTypes'

export const catalogKeys = {
  all: ['products'] as const,
  detail: (id: string) => ['products', 'detail', id] as const,
  categories: ['categories'] as const,
}

export function useCategories() {
  return useQuery({
    queryKey: catalogKeys.categories,
    queryFn: () => readRpc<Category[]>('list_categories_v1'),
    staleTime: 60_000,
  })
}

export function useProduct(productId: string | undefined) {
  return useQuery({
    queryKey: catalogKeys.detail(productId ?? ''),
    queryFn: () => readRpc<ProductDetail>('get_product_v1', { product_id: productId }),
    enabled: Boolean(productId),
  })
}
