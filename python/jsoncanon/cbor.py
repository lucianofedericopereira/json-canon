"""CBOR (RFC 8949) — decode to the value tree (`--from cbor`) and emit Core
Deterministic Encoding (`--to cbor`, RFC 8949 §4.2).

Bridges CBOR and the JSON value model:
- Integers use the shortest head; integers beyond 64-bit use bignum tags (2/3).
- Non-integer numbers use the shortest float (16/32/64) that round-trips (§4.2.2).
- Map keys are sorted by the bytewise lexicographic order of their *encoded*
  keys (§4.2.1) — CBOR's own ordering, distinct from the JSON code-point/JCS sort.
- On decode, byte strings become base64 (standard, padded) text, bignums become
  exact integer Numbers, floats become their shortest decimal, and NaN/Infinity
  become NonFinite (subject to the caller's --nan policy on re-emit).

Deterministic by construction, so the Nim port produces identical bytes; the
test suite round-trips JSON -> CBOR -> JSON and cross-checks Nim == Python.
"""

from __future__ import annotations

import base64
import math
import struct

from .numbers import canon_number
from .parser import JValue, Number, NonFinite, JSONError


# --- encode ----------------------------------------------------------------

def _head(major: int, n: int) -> bytes:
    mt = major << 5
    if n < 24:
        return bytes([mt | n])
    if n < 0x100:
        return bytes([mt | 24, n])
    if n < 0x10000:
        return bytes([mt | 25]) + n.to_bytes(2, "big")
    if n < 0x100000000:
        return bytes([mt | 26]) + n.to_bytes(4, "big")
    return bytes([mt | 27]) + n.to_bytes(8, "big")


def _encode_int(v: int) -> bytes:
    if v >= 0:
        if v < 2**64:
            return _head(0, v)
        mag = v
        tag = 2
    else:
        n = -1 - v
        if n < 2**64:
            return _head(1, n)
        mag = n
        tag = 3
    b = mag.to_bytes((mag.bit_length() + 7) // 8, "big")
    return _head(6, tag) + _head(2, len(b)) + b


def _encode_float(f: float) -> bytes:
    if f == f:  # not NaN
        try:
            h = struct.pack(">e", f)
            if struct.unpack(">e", h)[0] == f:
                return b"\xf9" + h
        except (OverflowError, struct.error):
            pass
        s = struct.pack(">f", f)
        if struct.unpack(">f", s)[0] == f:
            return b"\xfa" + s
    return b"\xfb" + struct.pack(">d", f)


def _encode_number(text: str) -> bytes:
    plain = canon_number(text, number_format="plain")
    if "." not in plain:
        return _encode_int(int(plain))
    return _encode_float(float(plain))


def _encode_text(s: str) -> bytes:
    b = s.encode("utf-8")
    return _head(3, len(b)) + b


def encode_cbor(value: JValue, *, nan: str = "error") -> bytes:
    if value is True:
        return b"\xf5"
    if value is False:
        return b"\xf4"
    if value is None:
        return b"\xf6"
    if isinstance(value, Number):
        return _encode_number(value.text)
    if isinstance(value, NonFinite):
        if nan == "null":
            return b"\xf6"
        if nan == "string":
            return _encode_text({"nan": "NaN", "inf": "Infinity",
                                 "-inf": "-Infinity"}[value.kind])
        raise JSONError(f"non-finite number ({value.kind}); choose --nan=null|string")
    if isinstance(value, str):
        return _encode_text(value)
    if isinstance(value, list):
        return _head(4, len(value)) + b"".join(encode_cbor(v, nan=nan) for v in value)
    if isinstance(value, dict):
        items = []
        for k, v in value.items():
            ek = _encode_text(k)
            items.append((ek, ek + encode_cbor(v, nan=nan)))
        items.sort(key=lambda t: t[0])  # §4.2.1 bytewise on encoded key
        return _head(5, len(value)) + b"".join(t[1] for t in items)
    raise JSONError(f"cannot CBOR-encode {type(value).__name__}")


# --- decode ----------------------------------------------------------------

class _Dec:
    def __init__(self, data: bytes) -> None:
        self.d = data
        self.i = 0

    def _take(self, n: int) -> bytes:
        if self.i + n > len(self.d):
            raise JSONError("truncated CBOR input")
        b = self.d[self.i:self.i + n]
        self.i += n
        return b

    def _argument(self, info: int) -> int:
        if info < 24:
            return info
        if info == 24:
            return self._take(1)[0]
        if info == 25:
            return int.from_bytes(self._take(2), "big")
        if info == 26:
            return int.from_bytes(self._take(4), "big")
        if info == 27:
            return int.from_bytes(self._take(8), "big")
        raise JSONError(f"unsupported CBOR additional info {info}")

    def value(self) -> JValue:
        ib = self._take(1)[0]
        major, info = ib >> 5, ib & 0x1F
        if major == 0:
            return Number(str(self._argument(info)))
        if major == 1:
            return Number(str(-1 - self._argument(info)))
        if major == 2:
            n = self._argument(info)
            return base64.b64encode(self._take(n)).decode("ascii")
        if major == 3:
            n = self._argument(info)
            return self._take(n).decode("utf-8")
        if major == 4:
            n = self._argument(info)
            return [self.value() for _ in range(n)]
        if major == 5:
            n = self._argument(info)
            obj: dict[str, JValue] = {}
            for _ in range(n):
                k = self.value()
                if not isinstance(k, str):
                    raise JSONError("CBOR map key is not a text string")
                obj[k] = self.value()
            return obj
        if major == 6:
            return self._tag(self._argument(info))
        return self._simple(info)

    def _tag(self, tag: int) -> JValue:
        if tag in (2, 3):  # bignum
            ib = self._take(1)[0]
            if ib >> 5 != 2:
                raise JSONError("CBOR bignum payload is not a byte string")
            mag = int.from_bytes(self._take(self._argument(ib & 0x1F)), "big")
            return Number(str(mag if tag == 2 else -1 - mag))
        return self.value()  # unknown tag: use the enclosed value

    def _simple(self, info: int) -> JValue:
        if info == 20:
            return False
        if info == 21:
            return True
        if info in (22, 23):
            return None
        if info == 25:
            f = struct.unpack(">e", self._take(2))[0]
        elif info == 26:
            f = struct.unpack(">f", self._take(4))[0]
        elif info == 27:
            f = struct.unpack(">d", self._take(8))[0]
        else:
            raise JSONError(f"unsupported CBOR simple value {info}")
        if math.isnan(f):
            return NonFinite("nan")
        if math.isinf(f):
            return NonFinite("inf" if f > 0 else "-inf")
        from .ecma import ecmascript_number_to_string
        return Number(ecmascript_number_to_string(f))


def decode_cbor(data: bytes) -> JValue:
    dec = _Dec(data)
    val = dec.value()
    if dec.i != len(data):
        raise JSONError("trailing bytes after CBOR value")
    return val
