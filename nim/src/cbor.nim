## CBOR (RFC 8949) — decode to the value tree and emit Core Deterministic
## Encoding (§4.2). Mirror of python/jsoncanon/cbor.py; deterministic by
## construction, so the two produce identical bytes.
##
## - Integers: shortest head; beyond 64-bit -> bignum tags (2/3).
## - Non-integer numbers: shortest float (16/32/64) that round-trips (§4.2.2).
## - Map keys sorted by bytewise order of their *encoded* keys (§4.2.1).
## - Decode: byte strings -> base64 text, bignums -> exact integers, floats ->
##   shortest decimal, NaN/Infinity -> NonFinite.

import std/[strutils, algorithm, base64, math, sequtils]
import ./jsoncanon
import ./ryu

# --- IEEE-754 half precision (validated exhaustively against Python struct) --

proc halfToDouble*(h: uint16): float64 =
  let sign = uint64(h shr 15)
  let exp = int((h shr 10) and 0x1F)
  let mant = uint64(h and 0x3FF)
  var d: uint64
  if exp == 0:
    if mant == 0:
      d = sign shl 63
    else:
      var msb = 9
      while (mant and (1'u64 shl msb)) == 0: dec msb
      let de = uint64(msb - 24 + 1023)
      let frac = (mant - (1'u64 shl msb)) shl (52 - msb)
      d = (sign shl 63) or (de shl 52) or frac
  elif exp == 0x1F:
    d = (sign shl 63) or (0x7FF'u64 shl 52) or (if mant != 0: (mant shl 42) else: 0'u64)
  else:
    let de = uint64(exp - 15 + 1023)
    d = (sign shl 63) or (de shl 52) or (mant shl 42)
  cast[float64](d)

proc roundShift(v: uint64, n: int): uint64 =
  ## v >> n, rounded to nearest, ties to even.
  if n <= 0: return v shl (-n)
  if n >= 64: return 0
  let keep = v shr n
  let rem = v and ((1'u64 shl n) - 1)
  let halfbit = 1'u64 shl (n - 1)
  if rem > halfbit: keep + 1
  elif rem < halfbit: keep
  elif (keep and 1) != 0: keep + 1
  else: keep

proc doubleToHalf(value: float64): uint16 =
  let bits = cast[uint64](value)
  let sign = uint16((bits shr 48) and 0x8000'u64)
  let exp = int((bits shr 52) and 0x7FF'u64)
  let mant = bits and 0xFFFFFFFFFFFFF'u64
  if exp == 0x7FF:
    return (if mant != 0: sign or 0x7E00'u16 else: sign or 0x7C00'u16)
  let e = exp - 1023
  if e > 15:
    return sign or 0x7C00'u16
  if e >= -14:
    var m = roundShift(mant, 42)
    var he = e + 15
    if (m and 0x400'u64) != 0:
      m = 0
      inc he
      if he >= 31: return sign or 0x7C00'u16
    return sign or uint16((uint64(he) shl 10) or (m and 0x3FF'u64))
  if e < -25:
    return sign
  let full = mant or 0x10000000000000'u64
  let m = roundShift(full, 28 - e)
  if m == 0: return sign
  if (m and 0x400'u64) != 0: return sign or 0x0400'u16
  return sign or uint16(m and 0x3FF'u64)

# --- big integer <-> bytes / decimal --------------------------------------

proc fitsU64(dec: string): bool =
  if dec.len < 20: return true
  if dec.len > 20: return false
  dec <= "18446744073709551615"

proc decDecr(s: string): string =
  ## s - 1, for s >= 1 (no sign, no leading zeros).
  var d = toSeq(s.items)
  var i = d.high
  while i >= 0:
    if d[i] == '0': d[i] = '9'; dec i
    else: d[i] = char(ord(d[i]) - 1); break
  result = d.join("")
  var k = 0
  while k < result.high and result[k] == '0': inc k
  result = result[k..^1]

proc decIncr(s: string): string =
  ## s + 1 (no sign, no leading zeros).
  var d = toSeq(s.items)
  var i = d.high
  while i >= 0:
    if d[i] == '9': d[i] = '0'; dec i
    else: d[i] = char(ord(d[i]) + 1); break
  result = (if i < 0: "1" else: "") & d.join("")

proc decToBytesBE(dec: string): seq[byte] =
  ## Non-negative decimal string -> minimal big-endian base-256 bytes.
  var cur: seq[int]
  for c in dec: cur.add(ord(c) - ord('0'))
  var le: seq[byte]
  while not (cur.len == 0 or (cur.len == 1 and cur[0] == 0)):
    var rem = 0
    var q: seq[int]
    for d in cur:
      let x = rem * 10 + d
      let qd = x div 256
      rem = x mod 256
      if q.len > 0 or qd > 0: q.add qd
    le.add byte(rem)
    cur = q
  if le.len == 0: le.add 0'u8
  result = newSeq[byte](le.len)
  for i in 0 ..< le.len: result[le.len - 1 - i] = le[i]

proc bytesToDec(b: openArray[byte]): string =
  ## Big-endian base-256 bytes -> decimal string.
  var digits = @[0]
  for by in b:
    var carry = int(by)
    for i in 0 ..< digits.len:
      let cur = digits[i] * 256 + carry
      digits[i] = cur mod 10
      carry = cur div 10
    while carry > 0:
      digits.add(carry mod 10)
      carry = carry div 10
  for i in countdown(digits.high, 0): result.add chr(ord('0') + digits[i])

# --- encode ----------------------------------------------------------------

proc add2BE(outp: var string, n: uint64) =
  outp.add char((n shr 8) and 0xFF); outp.add char(n and 0xFF)
proc add4BE(outp: var string, n: uint64) =
  for sh in [24, 16, 8, 0]: outp.add char((n shr uint64(sh)) and 0xFF)
proc add8BE(outp: var string, n: uint64) =
  for sh in [56, 48, 40, 32, 24, 16, 8, 0]: outp.add char((n shr uint64(sh)) and 0xFF)

proc head(major: int, n: uint64, outp: var string) =
  let mt = byte(major shl 5)
  if n < 24'u64: outp.add char(mt or byte(n))
  elif n < 0x100'u64: (outp.add char(mt or 24); outp.add char(byte(n)))
  elif n < 0x10000'u64: (outp.add char(mt or 25); outp.add2BE(n))
  elif n < 0x100000000'u64: (outp.add char(mt or 26); outp.add4BE(n))
  else: (outp.add char(mt or 27); outp.add8BE(n))

proc encodeBytesBig(tag: int, mag: seq[byte], outp: var string) =
  head(6, uint64(tag), outp)
  head(2, uint64(mag.len), outp)
  for b in mag: outp.add char(b)

proc encodeIntDec(plain: string, outp: var string) =
  let neg = plain[0] == '-'
  let digits = if neg: plain[1..^1] else: plain
  if not neg:
    if fitsU64(digits): head(0, parseBiggestUInt(digits), outp)
    else: encodeBytesBig(2, decToBytesBE(digits), outp)
  else:
    let n = decDecr(digits)             # CBOR negative stores -1 - v = |v| - 1
    if fitsU64(n): head(1, parseBiggestUInt(n), outp)
    else: encodeBytesBig(3, decToBytesBE(n), outp)

proc encodeFloat(f: float64, outp: var string) =
  let hb = doubleToHalf(f)
  if halfToDouble(hb) == f:
    outp.add char(0xf9); outp.add2BE(uint64(hb)); return
  let f32 = float32(f)
  if float64(f32) == f:
    outp.add char(0xfa); outp.add4BE(uint64(cast[uint32](f32))); return
  outp.add char(0xfb); outp.add8BE(cast[uint64](f))

proc encodeText(s: string, outp: var string) =
  head(3, uint64(s.len), outp)
  outp.add s

proc encodeNode(n: JNode, opts: Options, outp: var string)

proc encodeCbor*(n: JNode, opts = Options()): string =
  encodeNode(n, opts, result)

proc encodeNode(n: JNode, opts: Options, outp: var string) =
  case n.kind
  of jkNull: outp.add char(0xf6)
  of jkBool: outp.add char(if n.b: 0xf5 else: 0xf4)
  of jkNum:
    let plain = canonNumber(n.num, false, nfPlain)
    if '.' notin plain: encodeIntDec(plain, outp)
    else: encodeFloat(parseFloat(plain), outp)
  of jkStr: encodeText(n.str, outp)
  of jkNonFinite:
    case opts.nan
    of npNull: outp.add char(0xf6)
    of npString:
      encodeText((case n.nf
        of nfNan: "NaN"
        of nfInf: "Infinity"
        of nfNegInf: "-Infinity"), outp)
    of npError:
      raise newException(JsonError, "non-finite number; choose --nan=null|string")
  of jkArr:
    head(4, uint64(n.arr.len), outp)
    for item in n.arr: encodeNode(item, opts, outp)
  of jkObj:
    # §4.2.1: sort members by the bytewise order of their *encoded* keys.
    var entries: seq[(string, string)]
    for ix in 0 ..< n.keys.len:
      var ek: string
      encodeText(n.keys[ix], ek)
      var ev = ek
      encodeNode(n.vals[ix], opts, ev)
      entries.add((ek, ev))
    entries.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
    head(5, uint64(n.keys.len), outp)
    for e in entries: outp.add e[1]

# --- decode ----------------------------------------------------------------

type Decoder = object
  d: string
  i: int

proc take(dec: var Decoder, n: int): string =
  if dec.i + n > dec.d.len: raise newException(JsonError, "truncated CBOR input")
  result = dec.d[dec.i ..< dec.i + n]
  dec.i += n

proc beToU64(s: string): uint64 =
  for c in s: result = (result shl 8) or uint64(ord(c))

proc argument(dec: var Decoder, info: int): uint64 =
  if info < 24: uint64(info)
  elif info == 24: uint64(ord(dec.take(1)[0]))
  elif info == 25: beToU64(dec.take(2))
  elif info == 26: beToU64(dec.take(4))
  elif info == 27: beToU64(dec.take(8))
  else: raise newException(JsonError, "unsupported CBOR additional info " & $info)

proc decodeValue(dec: var Decoder): JNode

proc floatNode(f: float64): JNode =
  if classify(f) == fcNan: JNode(kind: jkNonFinite, nf: nfNan)
  elif classify(f) == fcInf: JNode(kind: jkNonFinite, nf: nfInf)
  elif classify(f) == fcNegInf: JNode(kind: jkNonFinite, nf: nfNegInf)
  else: JNode(kind: jkNum, num: ecmaScriptNumberToString(f))

proc decodeSimple(dec: var Decoder, info: int): JNode =
  case info
  of 20: JNode(kind: jkBool, b: false)
  of 21: JNode(kind: jkBool, b: true)
  of 22, 23: JNode(kind: jkNull)
  of 25: floatNode(halfToDouble(uint16(beToU64(dec.take(2)))))
  of 26: floatNode(float64(cast[float32](uint32(beToU64(dec.take(4))))))
  of 27: floatNode(cast[float64](beToU64(dec.take(8))))
  else: raise newException(JsonError, "unsupported CBOR simple value " & $info)

proc decodeTag(dec: var Decoder, tag: uint64): JNode =
  if tag == 2 or tag == 3:
    let ib = ord(dec.take(1)[0])
    if (ib shr 5) != 2: raise newException(JsonError, "CBOR bignum payload is not a byte string")
    let n = dec.argument(ib and 0x1F)
    let payload = dec.take(int(n))
    var bytes = newSeq[byte](payload.len)
    for k in 0 ..< payload.len: bytes[k] = byte(ord(payload[k]))
    let mag = bytesToDec(bytes)
    JNode(kind: jkNum, num: (if tag == 2: mag else: "-" & decIncr(mag)))
  else:
    dec.decodeValue()    # unknown tag: use the enclosed value

proc decodeValue(dec: var Decoder): JNode =
  let ib = ord(dec.take(1)[0])
  let major = ib shr 5
  let info = ib and 0x1F
  case major
  of 0: result = JNode(kind: jkNum, num: $dec.argument(info))
  of 1:
    let n = dec.argument(info)
    result = JNode(kind: jkNum, num: "-" & $(n + 1))
  of 2:
    let n = dec.argument(info)
    result = JNode(kind: jkStr, str: base64.encode(dec.take(int(n))))
  of 3:
    let n = dec.argument(info)
    result = JNode(kind: jkStr, str: dec.take(int(n)))
  of 4:
    let n = dec.argument(info)
    result = JNode(kind: jkArr)
    for _ in 0 ..< int(n): result.arr.add dec.decodeValue()
  of 5:
    let n = dec.argument(info)
    result = JNode(kind: jkObj)
    for _ in 0 ..< int(n):
      let k = dec.decodeValue()
      if k.kind != jkStr: raise newException(JsonError, "CBOR map key is not a text string")
      let v = dec.decodeValue()
      let existing = result.keys.find(k.str)
      if existing >= 0: result.vals[existing] = v
      else: (result.keys.add k.str; result.vals.add v)
  of 6: result = dec.decodeTag(dec.argument(info))
  else: result = dec.decodeSimple(info)

proc decodeCbor*(data: string): JNode =
  var dec = Decoder(d: data, i: 0)
  result = dec.decodeValue()
  if dec.i != data.len: raise newException(JsonError, "trailing bytes after CBOR value")
