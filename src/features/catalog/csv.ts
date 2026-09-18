/**
 * Baca berkas CSV impor katalog (FR-CAT-01). Mendukung pemisah koma atau titik koma
 * (Excel berbahasa Indonesia), sel berkutip, dan BOM. Validasi isi tetap di server.
 */

export const IMPORT_COLUMNS = [
  'sku', 'name', 'specification', 'base_unit', 'quantity_step', 'track_segments',
  'unit_label', 'factor_base', 'sale_step', 'sell_price', 'barcode', 'shelf',
] as const

export const REQUIRED_COLUMNS = ['sku', 'name', 'base_unit', 'quantity_step', 'unit_label', 'factor_base', 'sale_step', 'sell_price']

export const MAX_IMPORT_ROWS = 200

export type ImportRow = Record<string, string>

/** Penjelasan kolom untuk layar impor. */
export const COLUMN_HELP: Record<(typeof IMPORT_COLUMNS)[number], string> = {
  sku: 'Kode barang, unik (wajib)',
  name: 'Nama barang (wajib)',
  specification: 'Spesifikasi pembeda, mis. 10 Watt putih',
  base_unit: 'Satuan stok, mis. pcs atau m (wajib)',
  quantity_step: 'Kelipatan stok, mis. 1 atau 0.1 (wajib)',
  track_segments: 'true bila dilacak per roll, selain itu false',
  unit_label: 'Satuan jual, mis. pcs (wajib)',
  factor_base: 'Isi 1 satuan jual dalam satuan stok, mis. 1 (wajib)',
  sale_step: 'Kelipatan jual, mis. 1 (wajib)',
  sell_price: 'Harga jual Rupiah tanpa titik, mis. 15000 (wajib)',
  barcode: 'Barcode kemasan (boleh kosong)',
  shelf: 'Rak (boleh kosong)',
}

export function templateCsv(): string {
  const example = ['LMP-010', 'Lampu LED', '10 Watt putih', 'pcs', '1', 'false', 'pcs', '1', '1', '15000', '8991234567890', 'A1']
  return `﻿${IMPORT_COLUMNS.join(',')}\r\n${example.join(',')}\r\n`
}

function detectDelimiter(firstLine: string): ',' | ';' {
  let commas = 0
  let semicolons = 0
  let quoted = false
  for (const ch of firstLine) {
    if (ch === '"') quoted = !quoted
    else if (!quoted && ch === ',') commas++
    else if (!quoted && ch === ';') semicolons++
  }
  return semicolons > commas ? ';' : ','
}

/** RFC 4180 sederhana: sel berkutip boleh berisi pemisah, baris baru, dan "" untuk kutip. */
export function parseCsv(text: string): string[][] {
  const source = text.replace(/^﻿/, '')
  const delimiter = detectDelimiter(source.split(/\r?\n/, 1)[0] ?? '')
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  for (let i = 0; i < source.length; i++) {
    const ch = source[i]
    if (quoted) {
      if (ch === '"' && source[i + 1] === '"') { cell += '"'; i++ }
      else if (ch === '"') quoted = false
      else cell += ch
    } else if (ch === '"' && cell === '') {
      quoted = true
    } else if (ch === delimiter) {
      row.push(cell); cell = ''
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && source[i + 1] === '\n') i++
      row.push(cell); rows.push(row); row = []; cell = ''
    } else {
      cell += ch
    }
  }
  if (cell !== '' || row.length > 0) { row.push(cell); rows.push(row) }
  return rows.filter(r => r.some(c => c.trim() !== ''))
}

export type ParsedImport = { rows: ImportRow[]; problems: string[] }

export function csvToImportRows(text: string): ParsedImport {
  const table = parseCsv(text)
  if (table.length === 0) return { rows: [], problems: ['Berkas kosong.'] }
  const header = table[0].map(h => h.trim().toLowerCase())
  const problems: string[] = []
  const unknown = header.filter(h => !(IMPORT_COLUMNS as readonly string[]).includes(h))
  if (unknown.length) problems.push(`Kolom tidak dikenal: ${unknown.join(', ')}. Pakai templat yang disediakan.`)
  const missing = REQUIRED_COLUMNS.filter(c => !header.includes(c))
  if (missing.length) problems.push(`Kolom wajib belum ada: ${missing.join(', ')}.`)
  const body = table.slice(1)
  if (body.length === 0) problems.push('Belum ada baris barang di bawah judul kolom.')
  if (body.length > MAX_IMPORT_ROWS) problems.push(`Maksimal ${MAX_IMPORT_ROWS} barang per impor. Bagi berkas menjadi beberapa bagian.`)
  if (problems.length) return { rows: [], problems }

  const rows = body.map(cells => {
    const row: ImportRow = {}
    header.forEach((column, index) => { row[column] = (cells[index] ?? '').trim() })
    return row
  })
  return { rows, problems }
}
