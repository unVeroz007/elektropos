import { readRpc } from '../../lib/rpc'
import type {
  BarcodeLookup, CashDrawerStatus, CustomerSummary, Invoice, InvoiceListItem, ProductDetail, ProductSearchItem,
  SaleInput, SalePreview, SellablePositions, ShopSettings,
} from './types'

/** Bacaan server untuk modul penjualan. Error dilempar sebagai AppError oleh readRpc. */

export const searchProducts = (query: string) =>
  readRpc<ProductSearchItem[]>('search_products_v1', { query, limit: 20 })

export const findByBarcode = (code: string) =>
  readRpc<BarcodeLookup>('find_by_barcode_v1', { code })

export const getProduct = (productId: string) =>
  readRpc<ProductDetail>('get_product_v1', { product_id: productId })

export const listSellablePositions = (productId: string) =>
  readRpc<SellablePositions>('list_sellable_positions_v1', { product_id: productId })

export const previewSale = (input: SaleInput) =>
  readRpc<SalePreview>('preview_sale_v1', input)

export const searchCustomers = (query: string) =>
  readRpc<CustomerSummary[]>('search_customers_v1', { query, limit: 8 })

export const getShopDrawer = () =>
  readRpc<CashDrawerStatus>('get_cash_session_v1', {})

export const getInvoice = (invoiceId: string) =>
  readRpc<Invoice>('get_invoice_v1', { invoice_id: invoiceId })

export const getShopSettings = () =>
  readRpc<ShopSettings>('get_shop_settings_v1')

export type InvoiceFilter = {
  startDate: string
  endDate: string
  query: string
  limit: number
  offset: number
}

export const listInvoices = (filter: InvoiceFilter) =>
  readRpc<InvoiceListItem[]>('list_invoices_v1', {
    start_date: filter.startDate,
    end_date: filter.endDate,
    ...(filter.query.trim() ? { query: filter.query.trim() } : {}),
    limit: filter.limit,
    offset: filter.offset,
  })
