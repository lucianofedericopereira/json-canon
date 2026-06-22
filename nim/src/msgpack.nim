## MessagePack — decode to the value tree and emit a deterministic encoding.
## Mirror of python/jsoncanon/msgpack.py. MessagePack has no official canonical
## form, so we define one in the spirit of CBOR §4.2: smallest int/float/header
## encodings, map members ordered by bytewise order of their encoded keys.

import std/[strutils, algorithm, base64, math]
import ./jsoncanon
import ./ryu

# --- encode ----------------------------------------------------------------

proc beU(v: uint64, n: int, outp: var string) =
  for sh in countdown((n-1)*8, 0, 8): outp.add char(int((v shr uint64(sh)) and 0xFF))

proc encUint(v: uint64, outp: var string) =
  if v < 0x80'u64: outp.add char(int(v))
  elif v <= 0xFF'u64: (outp.add char(0xcc); outp.add char(int(v)))
  elif v <= 0xFFFF'u64: (outp.add char(0xcd); beU(v, 2, outp))
  elif v <= 0xFFFFFFFF'u64: (outp.add char(0xce); beU(v, 4, outp))
  else: (outp.add char(0xcf); beU(v, 8, outp))

proc encNegInt(v: int64, outp: var string) =
  let u = cast[uint64](v)
  if v >= -32: outp.add char(int(v) and 0xFF)
  elif v >= -128: (outp.add char(0xd0); beU(u, 1, outp))
  elif v >= -32768: (outp.add char(0xd1); beU(u, 2, outp))
  elif v >= -2147483648'i64: (outp.add char(0xd2); beU(u, 4, outp))
  else: (outp.add char(0xd3); beU(u, 8, outp))

proc encFloat(f: float64, outp: var string) =
  let f32 = float32(f)
  if float64(f32) == f:
    outp.add char(0xca); beU(uint64(cast[uint32](f32)), 4, outp)
  else:
    outp.add char(0xcb); beU(cast[uint64](f), 8, outp)

proc fitsU64(digits: string): bool =
  if digits.len < 20: true
  elif digits.len > 20: false
  else: digits <= "18446744073709551615"

proc fitsI64Neg(absDigits: string): bool =
  if absDigits.len < 19: true
  elif absDigits.len > 19: false
  else: absDigits <= "9223372036854775808"

proc encNumber(text: string, outp: var string) =
  let plain = canonNumber(text, false, nfPlain)
  if '.' in plain: (encFloat(parseFloat(plain), outp); return)
  if plain[0] == '-':
    if fitsI64Neg(plain[1..^1]): encNegInt(parseBiggestInt(plain), outp)
    else: encFloat(parseFloat(plain), outp)
  else:
    if fitsU64(plain): encUint(parseBiggestUInt(plain), outp)
    else: encFloat(parseFloat(plain), outp)

proc encStr(s: string, outp: var string) =
  let n = s.len
  if n < 32: outp.add char(0xA0 or n)
  elif n <= 0xFF: (outp.add char(0xd9); outp.add char(n))
  elif n <= 0xFFFF: (outp.add char(0xda); beU(uint64(n), 2, outp))
  else: (outp.add char(0xdb); beU(uint64(n), 4, outp))
  outp.add s

proc arrHead(n: int, outp: var string) =
  if n < 16: outp.add char(0x90 or n)
  elif n <= 0xFFFF: (outp.add char(0xdc); beU(uint64(n), 2, outp))
  else: (outp.add char(0xdd); beU(uint64(n), 4, outp))

proc mapHead(n: int, outp: var string) =
  if n < 16: outp.add char(0x80 or n)
  elif n <= 0xFFFF: (outp.add char(0xde); beU(uint64(n), 2, outp))
  else: (outp.add char(0xdf); beU(uint64(n), 4, outp))

proc encodeNode(n: JNode, opts: Options, outp: var string)

proc encodeMsgpack*(n: JNode, opts = Options()): string =
  encodeNode(n, opts, result)

proc encodeNode(n: JNode, opts: Options, outp: var string) =
  case n.kind
  of jkNull: outp.add char(0xc0)
  of jkBool: outp.add char(if n.b: 0xc3 else: 0xc2)
  of jkNum: encNumber(n.num, outp)
  of jkStr: encStr(n.str, outp)
  of jkNonFinite:
    case opts.nan
    of npNull: outp.add char(0xc0)
    of npString:
      encStr((case n.nf
        of nfNan: "NaN"
        of nfInf: "Infinity"
        of nfNegInf: "-Infinity"), outp)
    of npError:
      raise newException(JsonError, "non-finite number; choose --nan=null|string")
  of jkArr:
    arrHead(n.arr.len, outp)
    for item in n.arr: encodeNode(item, opts, outp)
  of jkObj:
    var entries: seq[(string, string)]
    for ix in 0 ..< n.keys.len:
      var ek: string
      encStr(n.keys[ix], ek)
      var ev = ek
      encodeNode(n.vals[ix], opts, ev)
      entries.add((ek, ev))
    entries.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
    mapHead(n.keys.len, outp)
    for e in entries: outp.add e[1]

# --- decode ----------------------------------------------------------------

type Decoder = object
  d: string
  i: int

proc take(dec: var Decoder, n: int): string =
  if dec.i + n > dec.d.len: raise newException(JsonError, "truncated MessagePack input")
  result = dec.d[dec.i ..< dec.i + n]
  dec.i += n

proc beToU(s: string): uint64 =
  for c in s: result = (result shl 8) or uint64(ord(c))

proc beToI(s: string): int64 =
  ## big-endian two's complement
  var u = beToU(s)
  let bits = s.len * 8
  if bits < 64 and (u shr uint64(bits - 1)) != 0:
    u = u or (not ((1'u64 shl bits) - 1))
  cast[int64](u)

proc floatNode(f: float64): JNode =
  case classify(f)
  of fcNan: JNode(kind: jkNonFinite, nf: nfNan)
  of fcInf: JNode(kind: jkNonFinite, nf: nfInf)
  of fcNegInf: JNode(kind: jkNonFinite, nf: nfNegInf)
  else: JNode(kind: jkNum, num: ecmaScriptNumberToString(f))

proc decodeValue(dec: var Decoder): JNode

proc decodeArray(dec: var Decoder, n: int): JNode =
  result = JNode(kind: jkArr)
  for _ in 0 ..< n: result.arr.add dec.decodeValue()

proc decodeMap(dec: var Decoder, n: int): JNode =
  result = JNode(kind: jkObj)
  for _ in 0 ..< n:
    let k = dec.decodeValue()
    if k.kind != jkStr: raise newException(JsonError, "MessagePack map key is not a string")
    let v = dec.decodeValue()
    let existing = result.keys.find(k.str)
    if existing >= 0: result.vals[existing] = v
    else: (result.keys.add k.str; result.vals.add v)

proc decodeValue(dec: var Decoder): JNode =
  let c = ord(dec.take(1)[0])
  if c < 0x80: return JNode(kind: jkNum, num: $c)
  if c >= 0xE0: return JNode(kind: jkNum, num: $(c - 0x100))
  if c >= 0x80 and c <= 0x8F: return decodeMap(dec, c and 0x0F)
  if c >= 0x90 and c <= 0x9F: return decodeArray(dec, c and 0x0F)
  if c >= 0xA0 and c <= 0xBF: return JNode(kind: jkStr, str: dec.take(c and 0x1F))
  case c
  of 0xC0: JNode(kind: jkNull)
  of 0xC2: JNode(kind: jkBool, b: false)
  of 0xC3: JNode(kind: jkBool, b: true)
  of 0xC4: JNode(kind: jkStr, str: base64.encode(dec.take(int(beToU(dec.take(1))))))
  of 0xC5: JNode(kind: jkStr, str: base64.encode(dec.take(int(beToU(dec.take(2))))))
  of 0xC6: JNode(kind: jkStr, str: base64.encode(dec.take(int(beToU(dec.take(4))))))
  of 0xCA: floatNode(float64(cast[float32](uint32(beToU(dec.take(4))))))
  of 0xCB: floatNode(cast[float64](beToU(dec.take(8))))
  of 0xCC: JNode(kind: jkNum, num: $beToU(dec.take(1)))
  of 0xCD: JNode(kind: jkNum, num: $beToU(dec.take(2)))
  of 0xCE: JNode(kind: jkNum, num: $beToU(dec.take(4)))
  of 0xCF: JNode(kind: jkNum, num: $beToU(dec.take(8)))
  of 0xD0: JNode(kind: jkNum, num: $beToI(dec.take(1)))
  of 0xD1: JNode(kind: jkNum, num: $beToI(dec.take(2)))
  of 0xD2: JNode(kind: jkNum, num: $beToI(dec.take(4)))
  of 0xD3: JNode(kind: jkNum, num: $beToI(dec.take(8)))
  of 0xD9: JNode(kind: jkStr, str: dec.take(int(beToU(dec.take(1)))))
  of 0xDA: JNode(kind: jkStr, str: dec.take(int(beToU(dec.take(2)))))
  of 0xDB: JNode(kind: jkStr, str: dec.take(int(beToU(dec.take(4)))))
  of 0xDC: decodeArray(dec, int(beToU(dec.take(2))))
  of 0xDD: decodeArray(dec, int(beToU(dec.take(4))))
  of 0xDE: decodeMap(dec, int(beToU(dec.take(2))))
  of 0xDF: decodeMap(dec, int(beToU(dec.take(4))))
  else: raise newException(JsonError, "unsupported MessagePack byte 0x" & toHex(c, 2))

proc decodeMsgpack*(data: string): JNode =
  var dec = Decoder(d: data, i: 0)
  result = dec.decodeValue()
  if dec.i != data.len: raise newException(JsonError, "trailing bytes after MessagePack value")
