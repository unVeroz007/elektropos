// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ErrorMessage, RupiahInput } from './ui'

describe('komponen UI bersama', () => {
  it('ErrorMessage menampilkan kalimat awam, bukan kode mentah', () => {
    render(<ErrorMessage error={{ message: 'CASH_SESSION_CLOSED: Kas laci toko belum dibuka.' }} />)
    expect(screen.getByRole('alert')).toHaveTextContent('Kas laci toko belum dibuka.')
    expect(screen.getByRole('alert')).not.toHaveTextContent('CASH_SESSION_CLOSED')
  })
  it('RupiahInput memberi tahu input yang tidak sah', async () => {
    const onChange = vi.fn()
    const { rerender } = render(<RupiahInput label="Uang diterima" value="" onChange={onChange} />)
    await userEvent.type(screen.getByLabelText('Uang diterima'), '5')
    expect(onChange).toHaveBeenCalledWith('5')
    rerender(<RupiahInput label="Uang diterima" value="1000,50" onChange={onChange} />)
    expect(screen.getByLabelText('Uang diterima')).toHaveAttribute('aria-invalid', 'true')
  })
})
