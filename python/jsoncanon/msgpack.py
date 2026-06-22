"""MessagePack — decode to the value tree (`--from msgpack`) and emit a
deterministic encoding (`--to msgpack`).

MessagePack has no official canonical form, so we define a deterministic one in
the spirit of CBOR §4.2: smallest integer/float encoding, shortest str/array/map
headers, and map members ordered by the bytewise order of their encoded keys.
Mirrors cbor.py; the Nim port produces identical bytes.

- Integers use the shortest of fixint / uint8-64 / int8-64; integers beyond
  64-bit fall back to float64 (msgpack has no bignum). Non-integers use the
  shortest float (32/64) that round-trips. Strings -> str family; arrays/maps ->
  array/map family. On decode, bin -> base64 text; ext is rejected; floats ->
  shortest decimal; non-finite floats -> NonFinite.
"""

from __future__ import annotations

import base64
import math
import struct

from .numbers import canon_number
from .parser import JValue, Number, NonFinite, JSONError


# --- encode ----------------------------------------------------------------

def _enc_uint(v: int) -> bytes:
    if v < 0x80:
        return bytes([v])                      # positive fixint
    if v <= 0xFF:
        return b"\xcc" + bytes([v])
    if v <= 0xFFFF:
        return b"\xcd" + v.to_bytes(2, "big")
    if v <= 0xFFFFFFFF:
        return b"\xce" + v.to_bytes(4, "big")
    return b"\xcf" + v.to_bytes(8, "big")


def _enc_int(v: int) -> bytes:
    if v >= 0:
        if v < 2**64:
            return _enc_uint(v)
        return _enc_float(float(v))            # beyond uint64 -> float64
    if v >= -32:
        return bytes([v & 0xFF])               # negative fixint
    if v >= -128:
        return b"\xd0" + struct.pack(">b", v)
    if v >= -32768:
        return b"\xd1" + struct.pack(">h", v)
    if v >= -(2**31):
        return b"\xd2" + struct.pack(">i", v)
    if v >= -(2**63):
        return b"\xd3" + struct.pack(">q", v)
    return _enc_float(float(v))


def _enc_float(f: float) -> bytes:
    if f == f:  # not NaN
        s = struct.pack(">f", f)
        if struct.unpack(">f", s)[0] == f:
            return b"\xca" + s
    return b"\xcb" + struct.pack(">d", f)


def _enc_number(text: str) -> bytes:
    plain = canon_number(text, number_format="plain")
    if "." not in plain:
        return _enc_int(int(plain))
    return _enc_float(float(plain))


def _enc_str(s: str) -> bytes:
    b = s.encode("utf-8")
    n = len(b)
    if n < 32:
        head = bytes([0xA0 | n])
    elif n <= 0xFF:
        head = b"\xd9" + bytes([n])
    elif n <= 0xFFFF:
        head = b"\xda" + n.to_bytes(2, "big")
    else:
        head = b"\xdb" + n.to_bytes(4, "big")
    return head + b


def _arr_head(n: int) -> bytes:
    if n < 16:
        return bytes([0x90 | n])
    if n <= 0xFFFF:
        return b"\xdc" + n.to_bytes(2, "big")
    return b"\xdd" + n.to_bytes(4, "big")


def _map_head(n: int) -> bytes:
    if n < 16:
        return bytes([0x80 | n])
    if n <= 0xFFFF:
        return b"\xde" + n.to_bytes(2, "big")
    return b"\xdf" + n.to_bytes(4, "big")


def encode_msgpack(value: JValue, *, nan: str = "error") -> bytes:
    if value is True:
        return b"\xc3"
    if value is False:
        return b"\xc2"
    if value is None:
        return b"\xc0"
    if isinstance(value, Number):
        return _enc_number(value.text)
    if isinstance(value, NonFinite):
        if nan == "null":
            return b"\xc0"
        if nan == "string":
            return _enc_str({"nan": "NaN", "inf": "Infinity", "-inf": "-Infinity"}[value.kind])
        raise JSONError(f"non-finite number ({value.kind}); choose --nan=null|string")
    if isinstance(value, str):
        return _enc_str(value)
    if isinstance(value, list):
        return _arr_head(len(value)) + b"".join(encode_msgpack(v, nan=nan) for v in value)
    if isinstance(value, dict):
        items = []
        for k, v in value.items():
            ek = _enc_str(k)
            items.append((ek, ek + encode_msgpack(v, nan=nan)))
        items.sort(key=lambda t: t[0])  # deterministic: bytewise on encoded key
        return _map_head(len(value)) + b"".join(t[1] for t in items)
    raise JSONError(f"cannot MessagePack-encode {type(value).__name__}")


# --- decode ----------------------------------------------------------------

class _Dec:
    def __init__(self, data: bytes) -> None:
        self.d = data
        self.i = 0

    def _take(self, n: int) -> bytes:
        if self.i + n > len(self.d):
            raise JSONError("truncated MessagePack input")
        b = self.d[self.i:self.i + n]
        self.i += n
        return b

    def _u(self, n: int) -> int:
        return int.from_bytes(self._take(n), "big")

    def _float_node(self, f: float) -> JValue:
        if math.isnan(f):
            return NonFinite("nan")
        if math.isinf(f):
            return NonFinite("inf" if f > 0 else "-inf")
        from .ecma import ecmascript_number_to_string
        return Number(ecmascript_number_to_string(f))

    def value(self) -> JValue:
        c = self._take(1)[0]
        if c < 0x80:                            # positive fixint
            return Number(str(c))
        if c >= 0xE0:                           # negative fixint
            return Number(str(c - 0x100))
        if 0x80 <= c <= 0x8F:                   # fixmap
            return self._map(c & 0x0F)
        if 0x90 <= c <= 0x9F:                   # fixarray
            return self._array(c & 0x0F)
        if 0xA0 <= c <= 0xBF:                   # fixstr
            return self._take(c & 0x1F).decode("utf-8")
        if c == 0xC0:
            return None
        if c == 0xC2:
            return False
        if c == 0xC3:
            return True
        if c in (0xC4, 0xC5, 0xC6):             # bin8/16/32
            n = self._u({0xC4: 1, 0xC5: 2, 0xC6: 4}[c])
            return base64.b64encode(self._take(n)).decode("ascii")
        if c == 0xCA:
            return self._float_node(struct.unpack(">f", self._take(4))[0])
        if c == 0xCB:
            return self._float_node(struct.unpack(">d", self._take(8))[0])
        if c in (0xCC, 0xCD, 0xCE, 0xCF):       # uint 8/16/32/64
            return Number(str(self._u({0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8}[c])))
        if c in (0xD0, 0xD1, 0xD2, 0xD3):       # int 8/16/32/64
            n = {0xD0: 1, 0xD1: 2, 0xD2: 4, 0xD3: 8}[c]
            return Number(str(int.from_bytes(self._take(n), "big", signed=True)))
        if c in (0xD9, 0xDA, 0xDB):             # str 8/16/32
            n = self._u({0xD9: 1, 0xDA: 2, 0xDB: 4}[c])
            return self._take(n).decode("utf-8")
        if c in (0xDC, 0xDD):                   # array 16/32
            return self._array(self._u(2 if c == 0xDC else 4))
        if c in (0xDE, 0xDF):                   # map 16/32
            return self._map(self._u(2 if c == 0xDE else 4))
        raise JSONError(f"unsupported MessagePack byte 0x{c:02x}")

    def _array(self, n: int) -> list[JValue]:
        return [self.value() for _ in range(n)]

    def _map(self, n: int) -> dict[str, JValue]:
        obj: dict[str, JValue] = {}
        for _ in range(n):
            k = self.value()
            if not isinstance(k, str):
                raise JSONError("MessagePack map key is not a string")
            obj[k] = self.value()
        return obj


def decode_msgpack(data: bytes) -> JValue:
    dec = _Dec(data)
    val = dec.value()
    if dec.i != len(data):
        raise JSONError("trailing bytes after MessagePack value")
    return val
