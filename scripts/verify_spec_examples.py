"""Verify arithmetic examples in the specifications, not application code.

Uses exact rational arithmetic independently of the planned Decimal.js/SQL code.
No database, external service or business data is accessed.
"""

from fractions import Fraction
from random import Random


def half_up(value: Fraction) -> int:
    sign = -1 if value < 0 else 1
    value = abs(value)
    quotient, remainder = divmod(value.numerator, value.denominator)
    return sign * (quotient + (2 * remainder >= value.denominator))


def allocate_discount(lines: list[int], discount: int) -> list[int]:
    total = sum(lines)
    assert 0 <= discount <= total
    if total == 0:
        return [0] * len(lines)
    quotients = [divmod(discount * line, total) for line in lines]
    result = [q for q, _ in quotients]
    order = sorted(range(len(lines)), key=lambda i: (-quotients[i][1], i))
    for index in order[: discount - sum(result)]:
        result[index] += 1
    return result


checks = {
    "cable quantity remaining": Fraction(100) - Fraction("2.5") == Fraction("97.5"),
    "cable sales amount": Fraction("2.5") * 7500 == 18750,
    "cable cost allocation": Fraction(500000) * Fraction("2.5") / 100 == 12500,
    "cable gross profit": 18750 - 12500 == 6250,
    "ten decimal deductions": Fraction(1) - 10 * Fraction("0.1") == 0,
    "item discount half up": half_up(Fraction(10001) * Fraction("0.9")) == 9001,
    "invoice discount tie": allocate_discount([100, 100, 100], 1) == [1, 0, 0],
    "refund installments": [half_up(Fraction(100 * x, 3)) - half_up(Fraction(100 * (x - 1), 3)) for x in (1, 2, 3)] == [33, 34, 33],
    "FIFO COGS": 2 * 10000 + 15000 == 35000,
    "service outstanding": 150000 - 50000 == 100000,
    "excess deposit refund": 100000 - 80000 == 20000,
    "drawer total": 200000 + 50000 - 20000 + 60000 == 290000,
    "wallet remaining": 100000 - 60000 == 40000,
    "drawer variance": 289000 - 290000 == -1000,
}
for label, passed in checks.items():
    assert passed, label

rng = Random(20260915)
for _ in range(1000):
    lines = [rng.randrange(0, 10**12) for _ in range(rng.randrange(1, 101))]
    discount = rng.randrange(sum(lines) + 1)
    allocations = allocate_discount(lines, discount)
    assert sum(allocations) == discount
    assert all(0 <= part <= line for part, line in zip(allocations, lines))
    assert sum(line - part for part, line in zip(allocations, lines)) == sum(lines) - discount

for _ in range(1000):
    quantity = rng.randrange(1, 1001)
    amount = rng.randrange(0, 10**15)
    returned = 0
    refunded = 0
    while returned < quantity:
        delta = rng.randrange(1, quantity - returned + 1)
        entitlement_before = half_up(Fraction(amount * returned, quantity))
        returned += delta
        entitlement_after = half_up(Fraction(amount * returned, quantity))
        current_refund = entitlement_after - entitlement_before
        assert current_refund >= 0
        refunded += current_refund
        assert refunded <= amount
    assert refunded == amount

print(f"PASS: {len(checks)} documented arithmetic examples")
print("PASS: 1000 discount allocation and 1000 cumulative refund invariant scenarios (fixed seed)")
print("Scope: specification arithmetic only; no application, database, security or hardware tests were run.")
