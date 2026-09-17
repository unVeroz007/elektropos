import { describe, expect, it } from 'vitest'
import { toAppError } from './errors'

describe('toAppError', () => {
  it('memisahkan kode dan kalimat server serta menambah petunjuk', () => {
    const err = toAppError({ message: 'CASH_SESSION_CLOSED: Kas laci toko belum dibuka.' })
    expect(err.code).toBe('CASH_SESSION_CLOSED')
    expect(err.kind).toBe('business')
    expect(err.display).toContain('Kas laci toko belum dibuka.')
    expect(err.display).toContain('Buka kas')
  })
  it('mengenali putus jaringan', () => {
    expect(toAppError(new TypeError('Failed to fetch')).kind).toBe('network')
  })
  it('tidak pernah menampilkan error database mentah', () => {
    const err = toAppError({ message: 'null value in column "total" violates not-null constraint', code: '23502' })
    expect(err.code).toBe('UNKNOWN')
    expect(err.display).not.toContain('constraint')
  })
  it('memetakan penolakan izin', () => {
    expect(toAppError({ message: 'permission denied for function x', code: '42501' }).kind).toBe('auth')
    expect(toAppError({ message: 'ACCOUNT_INACTIVE: Akun tidak aktif' }).kind).toBe('auth')
  })
})
