/**
 * Label awam untuk kode teknis server. Kode tidak pernah ditampilkan mentah;
 * kode yang belum dikenal ditampilkan sebagai "Lainnya".
 */

export type Labels = Record<string, string>

export function labelOf(labels: Labels, code: string | null | undefined, fallback = 'Lainnya'): string {
  if (!code) return fallback
  return labels[code] ?? fallback
}

export const PAYMENT_METHOD_LABEL: Labels = {
  CASH: 'Tunai',
  TRANSFER: 'Transfer bank',
  QRIS: 'QRIS',
  SUPPLIER_CREDIT: 'Potong saldo kredit distributor',
}

export const CASHBOX_LABEL: Labels = {
  SHOP_DRAWER: 'Laci toko',
  FATHER_WALLET: 'Dompet ayah',
}

export const LOCATION_LABEL: Labels = {
  SHOP: 'Di toko',
  FIELD_FATHER: 'Dibawa ayah',
}

export const CONDITION_LABEL: Labels = {
  SALEABLE: 'Layak jual',
  DAMAGED: 'Rusak',
}

export const STOCK_MOVEMENT_LABEL: Labels = {
  RECEIPT: 'Barang masuk',
  OPENING: 'Stok awal',
  TRANSFER_OUT: 'Dipindah keluar',
  TRANSFER_IN: 'Dipindah masuk',
  ADJUST_OUT: 'Koreksi kurang',
  ADJUST_IN: 'Koreksi tambah',
  COUNT_OUT: 'Hitung stok: kurang',
  COUNT_IN: 'Hitung stok: lebih',
  DISPOSAL: 'Dibuang (rusak)',
  SALE_OUT: 'Terjual / dipakai servis',
  RETURN_IN: 'Kembali dari retur',
  SUPPLIER_RETURN_OUT: 'Dikembalikan ke distributor',
  SUPPLIER_REPLACEMENT_IN: 'Barang pengganti distributor',
}

export const SERVICE_STATUS_LABEL: Labels = {
  NEW: 'Baru masuk',
  INSPECTING: 'Sedang dicek',
  AWAITING_APPROVAL: 'Menunggu persetujuan biaya',
  WAITING_PARTS: 'Menunggu suku cadang',
  WORKING: 'Sedang dikerjakan',
  READY: 'Selesai / siap diambil',
  UNREPAIRABLE: 'Tidak bisa diperbaiki',
  CANCELLED: 'Dibatalkan',
  ONSITE_DONE: 'Selesai di rumah pelanggan',
}

export const CUSTODY_LABEL: Labels = {
  SHOP: 'Di toko',
  FATHER: 'Dibawa ayah',
  CUSTOMER: 'Di pelanggan',
}

export const BACKUP_STATUS_LABEL: Labels = {
  RUNNING: 'Sedang berjalan',
  SUCCEEDED: 'Berhasil',
  FAILED: 'Gagal',
}

export const SUPPLIER_RETURN_STATUS_LABEL: Labels = {
  PENDING: 'Menunggu penyelesaian',
  SETTLED: 'Selesai',
}

export const SUPPLIER_RETURN_OUTCOME_LABEL: Labels = {
  REFUND: 'Uang kembali',
  CREDIT: 'Jadi saldo kredit (potong tagihan)',
  REPLACEMENT: 'Diganti barang',
  REJECTED: 'Ditolak distributor',
}
