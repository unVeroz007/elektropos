import { describe, expect, it, vi } from 'vitest'
import { collectCsv, MAX_CSV_PAGES, type CsvPage } from './csvExport'

const page = (rows: string, count: number, next: string | null): CsvPage => ({
  csv_header: '"number","total"', csv_rows: rows, count, has_more: next !== null, next_cursor: next,
})

describe('ekspor CSV (S03, bukti audit: offset > 0 dulu kosong)', () => {
  it('mengambil semua halaman berurutan memakai cursor server', async () => {
    const fetchPage = vi.fn()
      .mockResolvedValueOnce(page('"A-1","1000"\r\n"A-2","2000"', 2, 'c1'))
      .mockResolvedValueOnce(page('"A-3","3000"', 1, null))
    const { text, rows } = await collectCsv(fetchPage)
    expect(fetchPage.mock.calls.map(c => c[0])).toEqual([null, 'c1'])
    expect(rows).toBe(3)
    expect(text).toBe('﻿"number","total"\r\n"A-1","1000"\r\n"A-2","2000"\r\n"A-3","3000"\r\n')
  })
  it('periode kosong tetap menghasilkan header', async () => {
    const { text, rows } = await collectCsv(async () => page('', 0, null))
    expect(rows).toBe(0)
    expect(text).toBe('﻿"number","total"\r\n')
  })
  it('berhenti dengan pesan jelas bila data terlalu banyak', async () => {
    const fetchPage = vi.fn(async () => page('"x","1"', 1, 'next'))
    await expect(collectCsv(fetchPage)).rejects.toThrow('Persempit')
    expect(fetchPage).toHaveBeenCalledTimes(MAX_CSV_PAGES)
  })
})
