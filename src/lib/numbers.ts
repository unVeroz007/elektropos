import Decimal from 'decimal.js'

Decimal.set({ precision: 50, rounding: Decimal.ROUND_HALF_UP })

const canonical = /^(0|[1-9]\d*)(?:\.\d+)?$/

export function parseDecimal(input: string, decimals: number, max: string): Decimal {
  if (!canonical.test(input)) throw new Error('Angka harus berupa desimal kanonik tanpa pemisah ribuan')
  const fractional = input.split('.')[1] ?? ''
  if (fractional.length > decimals) throw new Error(`Maksimal ${decimals} angka desimal`)
  const value = new Decimal(input)
  if (value.greaterThan(max)) throw new Error('Nilai melebihi batas')
  return value
}

export function parseQuantity(input: string): Decimal {
  const normalized = input.trim().replace(',', '.')
  if (input.includes('.') && input.includes(',')) throw new Error('Gunakan koma atau titik desimal, tanpa pemisah ribuan')
  return parseDecimal(normalized, 3, '999999999.999')
}

export function toBaseQuantity(qty: string, factor: string, step: string): string {
  const q = parseDecimal(qty, 3, '999999999.999')
  const f = parseDecimal(factor, 3, '1000000.000')
  const s = parseDecimal(step, 3, '999999999.999')
  if (q.isZero() || f.isZero() || s.isZero() || !q.div(s).isInteger()) throw new Error('Kuantitas di luar langkah jual')
  const base = q.mul(f)
  if (base.decimalPlaces() > 3 || base.greaterThan('999999999.999')) throw new Error('Konversi tidak tepat dalam tiga desimal')
  return base.toFixed(3)
}

export function rupiahHalfUp(value: string): string {
  return new Decimal(value).toDecimalPlaces(0, Decimal.ROUND_HALF_UP).toFixed(0)
}

export function allocateCost(remainingValue: string, quantity: string, remainingQuantity: string): string {
  const q = new Decimal(quantity)
  const Q = new Decimal(remainingQuantity)
  if (q.lte(0) || q.gt(Q)) throw new Error('Kuantitas modal tidak sah')
  if (q.eq(Q)) return new Decimal(remainingValue).toFixed(6)
  return new Decimal(remainingValue).mul(q).div(Q).toDecimalPlaces(6, Decimal.ROUND_HALF_UP).toFixed(6)
}
