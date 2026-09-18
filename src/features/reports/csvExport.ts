/**
 * Ekspor CSV dari `export_csv_v1` (S03). Server sudah mengutip & menetralkan formula
 * (RFC 4180, `csv_safe`); klien hanya menyambung halaman sampai habis, tanpa mengolah sel.
 */

export type CsvPage = {
  csv_header: string
  csv_rows: string
  count: number
  has_more: boolean
  next_cursor: string | null
}

export type FetchCsvPage = (cursor: string | null) => Promise<CsvPage>

export const MAX_CSV_PAGES = 200

/** Gabungkan semua halaman menjadi satu teks CSV ber-BOM (agar Excel membaca UTF-8). */
export async function collectCsv(fetchPage: FetchCsvPage): Promise<{ text: string; rows: number }> {
  let cursor: string | null = null
  let header = ''
  const chunks: string[] = []
  let rows = 0
  for (let page = 0; page < MAX_CSV_PAGES; page++) {
    const result: CsvPage = await fetchPage(cursor)
    if (!header) header = result.csv_header
    if (result.count > 0 && result.csv_rows) chunks.push(result.csv_rows)
    rows += result.count
    if (!result.has_more || !result.next_cursor) {
      return { text: `\uFEFF${[header, ...chunks].join('\r\n')}\r\n`, rows }
    }
    cursor = result.next_cursor
  }
  throw new Error('Data terlalu banyak untuk satu berkas. Persempit rentang tanggal.')
}
