"""ECMAScript ``Number.prototype.toString`` — the number serialization RFC 8785
(JCS) mandates (SPEC.md §4).

CPython's ``repr(float)`` already yields the *shortest* decimal that round-trips,
using the same shortest / closest / ties-to-even contract as Ulf Adams' Ryu (the
Nim side). So we take those shortest digits and apply the ECMAScript formatting
case-split (thresholds 21 and -6) — byte-identical to the Nim ``ryu.nim`` output,
which is in turn validated against node's ``String(x)``.
"""

from __future__ import annotations

import math
from decimal import Decimal


def _format(neg: bool, digits: str, n: int) -> str:
    """`digits` is trailing-zero-free; value == digits * 10^(n - len(digits))."""
    k = len(digits)
    sign = "-" if neg else ""
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    mant = digits if k == 1 else digits[0] + "." + digits[1:]
    e = n - 1
    return sign + mant + "e" + ("+" if e >= 0 else "-") + str(abs(e))


def ecmascript_number_to_string(f: float) -> str:
    """The exact string JavaScript's ``String(f)`` produces. ``f`` must be finite
    (NaN/Infinity have no JSON form — the caller applies the NaN policy)."""
    if f == 0.0:                       # covers -0.0 -> "0"
        return "0"
    neg = math.copysign(1.0, f) < 0.0
    _sign, raw_digits, exp = Decimal(repr(abs(f))).as_tuple()
    assert isinstance(exp, int)        # finite Decimal -> integer exponent
    digits = list(raw_digits)
    # Minimal significand: drop trailing zeros (n stays invariant).
    while len(digits) > 1 and digits[-1] == 0:
        digits.pop()
        exp += 1
    s = "".join(str(d) for d in digits)
    return _format(neg, s, exp + len(s))
