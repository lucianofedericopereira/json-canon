"""Canonical serializer (see SPEC.md §2)."""

from __future__ import annotations

import math

from .ecma import ecmascript_number_to_string
from .numbers import canon_number
from .parser import JValue, Number, NonFinite, JSONError


def collect_jcs_warnings(val: JValue, path: str, acc: list[str]) -> None:
    """Record every number whose value *changes* under JCS — the IEEE-754 double
    cannot represent the input decimal exactly, so the canonical output no longer
    round-trips to the original. The lossless decimal engine is the arbiter: a
    change happened iff the exact value of the token differs from that of the Ryu
    output. (See SPEC.md §5; mirrors Nim's collectJcsWarnings.)"""
    if isinstance(val, Number):
        plain = canon_number(val.text, False, "plain")   # exact value of the token
        here = path or "<root>"
        f = float(plain)
        if math.isnan(f) or math.isinf(f):
            acc.append(f"{here}: {val.text.strip()} exceeds binary64 range (no JCS parity)")
        elif canon_number(ecmascript_number_to_string(f), False, "plain") != plain:
            acc.append(f"{here}: {plain} → {ecmascript_number_to_string(f)} "
                       f"(IEEE-754 rounding; not reversible)")
    elif isinstance(val, list):
        for i, item in enumerate(val):
            collect_jcs_warnings(item, f"{path}[{i}]", acc)
    elif isinstance(val, dict):
        for k, v in val.items():
            collect_jcs_warnings(v, f"{path}.{k}", acc)


def _utf16_key(s: str) -> list[int]:
    """UTF-16 code-unit sequence — RFC 8785 (JCS) key ordering. Differs from
    code-point order only for astral characters (encoded as surrogate pairs)."""
    units: list[int] = []
    for ch in s:
        cp = ord(ch)
        if cp <= 0xFFFF:
            units.append(cp)
        else:
            c = cp - 0x10000
            units.append(0xD800 + (c >> 10))
            units.append(0xDC00 + (c & 0x3FF))
    return units

_ESCAPES = {
    '"': '\\"', "\\": "\\\\",
    "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r",
}


def _enc_string(s: str) -> str:
    out = ['"']
    for ch in s:
        e = _ESCAPES.get(ch)
        if e is not None:
            out.append(e)
        elif ch < "\x20":
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


class Serializer:
    def __init__(self, *, preserve_number_type: bool = False, nan: str = "error",
                 number_format: str = "plain", jcs: bool = False) -> None:
        self.preserve = preserve_number_type
        self.nan = nan
        self.number_format = number_format
        self.jcs = jcs

    def dumps(self, val: JValue) -> str:
        out: list[str] = []
        self._write(val, out, "")
        return "".join(out)

    def _write(self, val: JValue, out: list[str], path: str) -> None:
        if val is True:
            out.append("true")
        elif val is False:
            out.append("false")
        elif val is None:
            out.append("null")
        elif isinstance(val, Number):
            out.append(self._number(val, path))
        elif isinstance(val, NonFinite):
            out.append(self._nonfinite(val, path))
        elif isinstance(val, str):
            out.append(_enc_string(val))
        elif isinstance(val, list):
            out.append("[")
            for i, item in enumerate(val):
                if i:
                    out.append(",")
                self._write(item, out, f"{path}[{i}]")
            out.append("]")
        elif isinstance(val, dict):
            out.append("{")
            keyfn = _utf16_key if self.jcs else None
            for i, key in enumerate(sorted(val.keys(), key=keyfn)):
                if i:
                    out.append(",")
                out.append(_enc_string(key))
                out.append(":")
                self._write(val[key], out, f"{path}.{key}")
            out.append("}")
        else:
            raise JSONError(f"cannot serialize {type(val).__name__} at {path or '<root>'}")

    def _number(self, val: Number, path: str) -> str:
        if not self.jcs:
            return canon_number(val.text, self.preserve, self.number_format)
        # RFC 8785: serialize the IEEE-754 double via ECMAScript Number::toString.
        # Reduce lenient token forms to a clean decimal first, then parse.
        f = float(canon_number(val.text, False, "plain"))
        if math.isnan(f):
            return self._nonfinite(NonFinite("nan"), path)
        if math.isinf(f):
            return self._nonfinite(NonFinite("inf" if f > 0 else "-inf"), path)
        return ecmascript_number_to_string(f)

    def _nonfinite(self, val: NonFinite, path: str) -> str:
        if self.nan == "null":
            return "null"
        if self.nan == "string":
            return {"nan": '"NaN"', "inf": '"Infinity"', "-inf": '"-Infinity"'}[val.kind]
        raise JSONError(
            f"non-finite number ({val.kind}) at {path or '<root>'}; "
            f"choose a policy with --nan=null|string"
        )


def dumps(val: JValue, *, preserve_number_type: bool = False, nan: str = "error",
          number_format: str = "plain", jcs: bool = False) -> str:
    return Serializer(preserve_number_type=preserve_number_type, nan=nan,
                      number_format=number_format, jcs=jcs).dumps(val)


def _kind(v: JValue) -> str:
    if v is None:
        return "null"
    if v is True or v is False:
        return "bool"
    if isinstance(v, Number):
        return "num"
    if isinstance(v, NonFinite):
        return "nonfinite"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "arr"
    return "obj"


def _diff_nodes(a: JValue, b: JValue, path: str, ser: Serializer,
                out: list[str]) -> None:
    here = path or "$"
    if _kind(a) != _kind(b):
        out.append(f"~ {here}: {ser.dumps(a)} => {ser.dumps(b)}")
        return
    if isinstance(a, dict):
        assert isinstance(b, dict)
        keyfn = _utf16_key if ser.jcs else None
        keys = list(a.keys()) + [k for k in b.keys() if k not in a]
        for key in sorted(keys, key=keyfn):
            cp = f"{path}.{key}"
            if key not in a:
                out.append(f"+ {cp}: {ser.dumps(b[key])}")
            elif key not in b:
                out.append(f"- {cp}: {ser.dumps(a[key])}")
            else:
                _diff_nodes(a[key], b[key], cp, ser, out)
    elif isinstance(a, list):
        assert isinstance(b, list)
        for i in range(max(len(a), len(b))):
            cp = f"{path}[{i}]"
            if i >= len(a):
                out.append(f"+ {cp}: {ser.dumps(b[i])}")
            elif i >= len(b):
                out.append(f"- {cp}: {ser.dumps(a[i])}")
            else:
                _diff_nodes(a[i], b[i], cp, ser, out)
    else:
        sa, sb = ser.dumps(a), ser.dumps(b)
        if sa != sb:
            out.append(f"~ {here}: {sa} => {sb}")


def diff_values(a: JValue, b: JValue, *, jcs: bool = False) -> list[str]:
    """Structural difference between two parsed values after canonicalization."""
    out: list[str] = []
    _diff_nodes(a, b, "$", Serializer(jcs=jcs), out)
    return out
