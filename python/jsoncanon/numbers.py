"""Decimal-string number canonicalization (see SPEC.md §2.3).

Pure string/integer operations. A number token is NEVER converted to a binary
float, so big integers and high-precision decimals survive intact and the
result is identical to the Nim implementation byte-for-byte.
"""

import re

# Lenient number token: optional sign, optional leading zeros, optional
# fraction (either side may be empty: ".5" or "5."), optional exponent.
_NUM_RE = re.compile(
    r"^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$"
)


def is_number_token(tok: str) -> bool:
    return bool(_NUM_RE.match(tok))


def canon_number(tok: str, preserve_type: bool = False,
                 number_format: str = "plain") -> str:
    """Normalize a JSON number token to its canonical string.

    number_format:
      "plain"      always plain decimal (default): 1000, 0.0015
      "scientific" always scientific: 4 -> 4e+0, 0.1 -> 1e-1
      "auto"       scientific only for very large/small magnitudes
                   (ECMAScript thresholds: sci when exp >= 21 or < -6)
    """
    s = tok.strip()
    neg = s[0] == "-"
    if s[0] in "+-":
        s = s[1:]

    # Split mantissa / exponent.
    mant, _e, exp_s = s.replace("E", "e").partition("e")
    E = int(exp_s) if exp_s else 0

    # Split integer / fraction digits.
    if "." in mant:
        I, _, F = mant.partition(".")
    else:
        I, F = mant, ""

    was_float = ("." in tok) or ("e" in tok) or ("E" in tok)

    combined = I + F
    point_exp = E - len(F)

    # Strip leading zeros (high order — doesn't affect point_exp).
    combined = combined.lstrip("0")
    if combined == "":
        return "0"

    # Strip trailing zeros (low order — each bumps point_exp).
    stripped = combined.rstrip("0")
    point_exp += len(combined) - len(stripped)
    combined = stripped

    sign = "-" if neg else ""

    # scientific exponent if we placed the point after the first digit
    sci_exp = point_exp + (len(combined) - 1)
    use_sci = number_format == "scientific" or (
        number_format == "auto" and not (-6 <= sci_exp < 21))
    if use_sci:
        mant = combined if len(combined) == 1 else combined[0] + "." + combined[1:]
        esign = "+" if sci_exp >= 0 else "-"
        return sign + mant + "e" + esign + str(abs(sci_exp))

    if point_exp >= 0:
        out = sign + combined + "0" * point_exp
        if preserve_type and was_float:
            out += ".0"
        return out

    k = -point_exp
    if k < len(combined):
        return sign + combined[:-k] + "." + combined[-k:]
    return sign + "0." + "0" * (k - len(combined)) + combined
