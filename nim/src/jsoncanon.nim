## jsoncanon — canonical JSON normalizer (see ../../SPEC.md).
##
## Independent Nim implementation, byte-identical to the Python reference.

import std/[strutils, algorithm, unicode, sequtils, math]
import ./ryu
import ./json5_ident

type
  JKind* = enum jkNull, jkBool, jkNum, jkStr, jkArr, jkObj, jkNonFinite
  NFKind* = enum nfNan, nfInf, nfNegInf
  JNode* = ref object
    case kind*: JKind
    of jkNull: discard
    of jkBool: b*: bool
    of jkNum: num*: string          ## raw token text, normalized at serialize
    of jkStr: str*: string
    of jkArr: arr*: seq[JNode]
    of jkObj:
      keys*: seq[string]
      vals*: seq[JNode]             ## parallel to keys; duplicates deduped last-wins
    of jkNonFinite: nf*: NFKind

  NanPolicy* = enum npError, npNull, npString
  NumberFormat* = enum nfPlain, nfAuto, nfScientific

  Options* = object
    preserveNumberType*: bool
    nan*: NanPolicy
    numberFormat*: NumberFormat
    strictDupes*: bool
    jcs*: bool                      ## RFC 8785 mode: Ryu numbers + UTF-16 key sort

  JsonError* = object of ValueError

# ---------------------------------------------------------------------------
# §1.1  byte decoding
# ---------------------------------------------------------------------------

proc fromUtf16(data: string, start: int, le: bool): string =
  var i = start
  while i + 1 < data.len:
    let a = ord(data[i]); let b = ord(data[i+1])
    var unit = if le: a or (b shl 8) else: (a shl 8) or b
    i += 2
    if unit >= 0xD800 and unit <= 0xDBFF and i + 1 < data.len:
      let c = ord(data[i]); let d = ord(data[i+1])
      let lo = if le: c or (d shl 8) else: (c shl 8) or d
      if lo >= 0xDC00 and lo <= 0xDFFF:
        unit = 0x10000 + ((unit - 0xD800) shl 10) + (lo - 0xDC00)
        i += 2
    result.add $Rune(unit)

proc fromUtf32(data: string, start: int, le: bool): string =
  var i = start
  while i + 3 < data.len:
    let bytes = [ord(data[i]), ord(data[i+1]), ord(data[i+2]), ord(data[i+3])]
    let cp = if le: bytes[0] or (bytes[1] shl 8) or (bytes[2] shl 16) or (bytes[3] shl 24)
             else: (bytes[0] shl 24) or (bytes[1] shl 16) or (bytes[2] shl 8) or bytes[3]
    i += 4
    result.add $Rune(cp)

proc decodeBytes*(data: string, encoding = ""): string =
  if encoding.len > 0:
    case encoding.toLowerAscii
    of "utf-8", "utf8": return data
    of "utf-16-le", "utf-16le", "utf16le": return fromUtf16(data, 0, true)
    of "utf-16-be", "utf-16be", "utf16be": return fromUtf16(data, 0, false)
    of "utf-32-le", "utf-32le": return fromUtf32(data, 0, true)
    of "utf-32-be", "utf-32be": return fromUtf32(data, 0, false)
    of "latin-1", "latin1", "iso-8859-1":
      for c in data: result.add $Rune(ord(c))
      return result
    else: raise newException(JsonError, "unsupported encoding: " & encoding)
  if data.startsWith("\xFF\xFE\x00\x00"): return fromUtf32(data, 4, true)
  if data.startsWith("\x00\x00\xFE\xFF"): return fromUtf32(data, 4, false)
  if data.startsWith("\xEF\xBB\xBF"): return data[3..^1]
  if data.startsWith("\xFF\xFE"): return fromUtf16(data, 2, true)
  if data.startsWith("\xFE\xFF"): return fromUtf16(data, 2, false)
  return data

proc putU16(s: var string, unit: int, le: bool) =
  if le: (s.add chr(unit and 0xFF); s.add chr((unit shr 8) and 0xFF))
  else: (s.add chr((unit shr 8) and 0xFF); s.add chr(unit and 0xFF))

proc encodeOutput*(text: string, encoding = "utf-8", bom = false): string =
  ## Re-encode canonical UTF-8 text into a target charset (+ optional BOM).
  let enc = encoding.toLowerAscii
  case enc
  of "utf-8", "utf8":
    if bom: result.add "\xEF\xBB\xBF"
    result.add text
  of "utf-16-le", "utf-16be", "utf-16-be", "utf-16le":
    let le = enc in ["utf-16-le", "utf-16le"]
    if bom: (if le: result.add "\xFF\xFE" else: result.add "\xFE\xFF")
    for r in text.runes:
      let cp = int(r)
      if cp <= 0xFFFF: result.putU16(cp, le)
      else:
        let c = cp - 0x10000
        result.putU16(0xD800 + (c shr 10), le)
        result.putU16(0xDC00 + (c and 0x3FF), le)
  of "utf-32-le", "utf-32be", "utf-32-be", "utf-32le":
    let le = enc in ["utf-32-le", "utf-32le"]
    if bom: (if le: result.add "\xFF\xFE\x00\x00" else: result.add "\x00\x00\xFE\xFF")
    for r in text.runes:
      let cp = int(r)
      if le:
        for sh in [0, 8, 16, 24]: result.add chr((cp shr sh) and 0xFF)
      else:
        for sh in [24, 16, 8, 0]: result.add chr((cp shr sh) and 0xFF)
  of "latin-1", "latin1", "iso-8859-1":
    for r in text.runes:
      if int(r) > 255:
        raise newException(JsonError, "code point U+" & toHex(int(r), 4) &
          " is not representable in latin-1")
      result.add chr(int(r))
  else:
    raise newException(JsonError, "unsupported output encoding: " & encoding)

# ---------------------------------------------------------------------------
# §2.3  number canonicalization (pure string ops)
# ---------------------------------------------------------------------------

proc canonNumber*(tok: string, preserveType = false,
                  numberFormat = nfPlain): string =
  var s = tok.strip()
  let neg = s.len > 0 and s[0] == '-'
  if s.len > 0 and (s[0] == '+' or s[0] == '-'): s = s[1..^1]

  var eIdx = -1
  for i, c in s:
    if c == 'e' or c == 'E': eIdx = i; break
  var mant: string
  var E = 0
  if eIdx >= 0:
    mant = s[0..<eIdx]
    let es = s[eIdx+1..^1]
    E = if es.len == 0: 0 else: parseInt(es)   # empty exponent -> 0 (matches Python)
  else:
    mant = s

  var I, F: string
  let dotIdx = mant.find('.')
  if dotIdx >= 0:
    I = mant[0..<dotIdx]; F = mant[dotIdx+1..^1]
  else:
    I = mant; F = ""

  let wasFloat = ('.' in tok) or ('e' in tok) or ('E' in tok)
  var combined = I & F
  var pointExp = E - F.len

  var lead = 0
  while lead < combined.len and combined[lead] == '0': inc lead
  combined = combined[lead..^1]
  if combined.len == 0: return "0"

  var endi = combined.len
  while endi > 0 and combined[endi-1] == '0':
    dec endi; inc pointExp
  combined = combined[0..<endi]

  let sign = if neg: "-" else: ""

  let sciExp = pointExp + (combined.len - 1)
  let useSci = numberFormat == nfScientific or
    (numberFormat == nfAuto and not (sciExp >= -6 and sciExp < 21))
  if useSci:
    let mant = if combined.len == 1: combined
               else: combined[0..0] & "." & combined[1..^1]
    let esign = if sciExp >= 0: "+" else: "-"
    return sign & mant & "e" & esign & $abs(sciExp)

  if pointExp >= 0:
    result = sign & combined & repeat('0', pointExp)
    if preserveType and wasFloat: result.add ".0"
    return result

  let k = -pointExp
  if k < combined.len:
    return sign & combined[0..<(combined.len - k)] & "." & combined[(combined.len - k)..^1]
  return sign & "0." & repeat('0', k - combined.len) & combined

# ---------------------------------------------------------------------------
# §1  lenient parser
# ---------------------------------------------------------------------------

type
  Diag* = tuple[pos: int, category: string, message: string]
  Parser = object
    s: string
    i: int
    opts: Options
    collectDiags: bool
    diags: seq[Diag]
    force: bool                 ## --force: salvage malformed input
    fwarn: seq[Diag]            ## recovery warnings (pos, "recover", message)

proc err(p: Parser, msg: string) {.noreturn.} =
  raise newException(JsonError, msg & " at position " & $p.i)

proc diag(p: var Parser, pos: int, category, message: string) =
  if p.collectDiags: p.diags.add((pos, category, message))

proc recover(p: var Parser, pos: int, message: string) =
  p.fwarn.add((pos, "recover", message))

proc skipToDelim(p: var Parser) =
  ## Force-mode resync: advance to the next ',' '}' or ']' at the current depth,
  ## skipping nested containers and strings. Leaves p.i at the delimiter (or EOF).
  var depth = 0
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c == '"' or c == '\'':
      inc p.i
      while p.i < p.s.len and p.s[p.i] != c:
        if p.s[p.i] == '\\': inc p.i
        inc p.i
      if p.i < p.s.len: inc p.i
    elif c == '[' or c == '{': (inc depth; inc p.i)
    elif c == ']' or c == '}':
      if depth == 0: return
      dec depth; inc p.i
    elif c == ',' and depth == 0: return
    else: inc p.i

const WS = {' ', '\t', '\n', '\r', '\x0B', '\x0C'}  # JSON5: + vtab / formfeed
const HexDigits = {'0'..'9', 'a'..'f', 'A'..'F'}

proc isIdStartCp(cp: uint32): bool =
  if cp < 0x80'u32: char(cp) in {'A'..'Z', 'a'..'z', '_', '$'}
  else: isJson5IdStart(cp)

proc isIdContinueCp(cp: uint32): bool =
  if cp < 0x80'u32: char(cp) in {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}
  else: isJson5IdContinue(cp)

proc hexToDec(hex: string): string =
  ## Arbitrary-precision hex digit string -> canonical decimal string.
  ## Same decimal output as Python's int(h, 16), so the two stay byte-identical.
  var digits = @[0]  # little-endian base-10
  for hc in hex:
    var carry = parseHexInt($hc)
    for i in 0 ..< digits.len:
      let cur = digits[i] * 16 + carry
      digits[i] = cur mod 10
      carry = cur div 10
    while carry > 0:
      digits.add(carry mod 10)
      carry = carry div 10
  for i in countdown(digits.high, 0): result.add chr(ord('0') + digits[i])

proc skipComment(p: var Parser) =
  p.diag(p.i, "comment", "comment is not valid JSON")
  if p.s[p.i+1] == '/':
    p.i += 2
    while p.i < p.s.len and p.s[p.i] != '\n': inc p.i
  else:
    p.i += 2
    while p.i < p.s.len and not (p.s[p.i] == '*' and p.i+1 < p.s.len and p.s[p.i+1] == '/'):
      inc p.i
    if p.i >= p.s.len: p.err("unterminated block comment")
    p.i += 2

proc skipWs(p: var Parser) =
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c in WS: inc p.i
    elif c == '/' and p.i+1 < p.s.len and (p.s[p.i+1] == '/' or p.s[p.i+1] == '*'):
      p.skipComment()
    else: break

proc peek(p: Parser): char = (if p.i < p.s.len: p.s[p.i] else: '\0')

proc parseValue(p: var Parser): JNode

proc parseString(p: var Parser, quote: char): string =
  if quote == '\'':
    p.diag(p.i, "single-quote", "single-quoted string is not valid JSON")
  inc p.i
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c == quote:
      inc p.i
      return
    if c == '\\':
      inc p.i
      if p.i >= p.s.len: p.err("unterminated escape")
      let e = p.s[p.i]
      case e
      of 'u':
        var cp = parseHexInt(p.s[p.i+1..p.i+4])
        p.i += 5
        if cp >= 0xD800 and cp <= 0xDBFF and p.i+1 < p.s.len and
           p.s[p.i] == '\\' and p.s[p.i+1] == 'u':
          let lo = parseHexInt(p.s[p.i+2..p.i+5])
          if lo >= 0xDC00 and lo <= 0xDFFF:
            cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
            p.i += 6
        result.add $Rune(cp)
        continue
      of 'x':  # JSON5 \xHH byte escape
        p.diag(p.i-1, "hex-escape", "\\xHH escape is JSON5, not JSON")
        result.add $Rune(parseHexInt(p.s[p.i+1..p.i+2]))
        p.i += 3
        continue
      of '\x0A':  # \ + LF  (line continuation)
        p.diag(p.i-1, "line-continuation", "escaped newline is JSON5, not JSON")
        inc p.i; continue
      of '\x0D':  # \ + CR (or CRLF)
        p.diag(p.i-1, "line-continuation", "escaped newline is JSON5, not JSON")
        inc p.i
        if p.i < p.s.len and p.s[p.i] == '\x0A': inc p.i
        continue
      of '\xE2':  # possible \ + U+2028 / U+2029 line separator
        if p.i+2 < p.s.len and p.s[p.i+1] == '\x80' and p.s[p.i+2] in {'\xA8', '\xA9'}:
          p.diag(p.i-1, "line-continuation", "escaped newline is JSON5, not JSON")
          p.i += 3; continue
        result.add e; inc p.i
      of 'b': result.add '\x08'
      of 'f': result.add '\x0C'
      of 'n': result.add '\x0A'
      of 'r': result.add '\x0D'
      of 't': result.add '\x09'
      of 'v': result.add '\x0B'
      of '0': result.add '\x00'
      else: result.add e
      inc p.i
    else:
      result.add c
      inc p.i
  p.err("unterminated string")

proc validNumberToken(tok: string): bool =
  ## Matches ^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$ — the lenient number grammar
  ## (numbers.py _NUM_RE). Rejects tokens like "1e", "1.2.3", "1e30.5" so they are
  ## a clean parse error (and --force drops them) rather than crashing canonNumber.
  var i = 0
  let n = tok.len
  if i < n and tok[i] in {'+', '-'}: inc i
  let mstart = i
  if i < n and tok[i] == '.':
    inc i
    let ds = i
    while i < n and tok[i] in Digits: inc i
    if i == ds: return false
  else:
    let ds = i
    while i < n and tok[i] in Digits: inc i
    if i == ds: return false
    if i < n and tok[i] == '.':
      inc i
      while i < n and tok[i] in Digits: inc i
  if i == mstart: return false
  if i < n and tok[i] in {'e', 'E'}:
    inc i
    if i < n and tok[i] in {'+', '-'}: inc i
    let es = i
    while i < n and tok[i] in Digits: inc i
    if i == es: return false
  i == n

proc parseNumber(p: var Parser): JNode =
  let start = p.i
  if p.s[p.i] in {'+', '-'}: inc p.i
  if p.i+1 < p.s.len and p.s[p.i] == '0' and p.s[p.i+1] in {'x', 'X'}:  # JSON5 hex
    p.i += 2
    let hstart = p.i
    while p.i < p.s.len and p.s[p.i] in HexDigits: inc p.i
    if p.i == hstart: p.err("invalid hex number")
    p.diag(start, "hex-number", "hex number '" & p.s[start..<p.i] & "' is JSON5, not JSON")
    let sign = if p.s[start] == '-': "-" else: ""
    return JNode(kind: jkNum, num: sign & hexToDec(p.s[hstart..<p.i]))
  while p.i < p.s.len and (p.s[p.i] in Digits or p.s[p.i] in {'.', 'e', 'E', '+', '-'}):
    if p.s[p.i] in {'+', '-'} and not (p.s[p.i-1] in {'e', 'E'}): break
    inc p.i
  let tok = p.s[start..<p.i]
  if not validNumberToken(tok): p.err("invalid number '" & tok & "'")
  let body = if tok[0] in {'+', '-'}: tok[1..^1] else: tok
  if tok[0] == '+':
    p.diag(start, "number-syntax", "leading '+' in number '" & tok & "'")
  elif body.len > 1 and body[0] == '0' and body[1] in Digits:
    p.diag(start, "number-syntax", "leading zero in number '" & tok & "'")
  elif body.len > 0 and (body[0] == '.' or body[^1] == '.'):
    p.diag(start, "number-syntax", "missing digit in number '" & tok & "'")
  JNode(kind: jkNum, num: tok)

proc identCodepoint(p: var Parser): uint32 =
  ## Consume one JSON5 identifier unit — either a `\uXXXX` escape (with optional
  ## surrogate pairing) or a raw UTF-8 rune — and return its code point.
  if p.s[p.i] == '\\':
    if p.i + 1 >= p.s.len or p.s[p.i+1] != 'u': p.err("invalid identifier escape")
    var cp = uint32(parseHexInt(p.s[p.i+2 .. p.i+5]))
    p.i += 6
    if cp >= 0xD800'u32 and cp <= 0xDBFF'u32 and p.i + 1 < p.s.len and
       p.s[p.i] == '\\' and p.s[p.i+1] == 'u':
      let lo = uint32(parseHexInt(p.s[p.i+2 .. p.i+5]))
      if lo >= 0xDC00'u32 and lo <= 0xDFFF'u32:
        cp = 0x10000'u32 + ((cp - 0xD800'u32) shl 10) + (lo - 0xDC00'u32)
        p.i += 6
    return cp
  var r: Rune
  fastRuneAt(p.s, p.i, r, true)
  uint32(r)

proc parseIdentKey(p: var Parser): string =
  ## JSON5 unquoted key: ASCII identifier, Unicode identifier (ID_Start /
  ## ID_Continue, §1.2), or `\u`-escaped identifier.
  let start = p.i
  if p.i >= p.s.len: p.err("expected string key")
  var cp = p.identCodepoint()
  if not isIdStartCp(cp): (p.i = start; p.err("expected string key"))
  result.add $Rune(cp)
  while p.i < p.s.len:
    let save = p.i
    if p.s[p.i] == '\\':
      if p.i + 1 >= p.s.len or p.s[p.i+1] != 'u': break
      cp = p.identCodepoint()
      if not isIdContinueCp(cp): (p.i = save; break)
      result.add $Rune(cp)
    else:
      var j = save
      var r: Rune
      fastRuneAt(p.s, j, r, true)
      if not isIdContinueCp(uint32(r)): break
      p.i = j
      result.add $Rune(r)
  p.diag(start, "unquoted-key", "unquoted key '" & result & "' is JSON5, not JSON")

proc startsAt(p: Parser, lit: string): bool =
  p.i + lit.len <= p.s.len and p.s[p.i ..< p.i + lit.len] == lit

proc parseValue(p: var Parser): JNode =
  p.skipWs()
  let c = p.peek()
  case c
  of '\0': p.err("unexpected end of input")
  of '{':
    inc p.i
    result = JNode(kind: jkObj)
    p.skipWs()
    if p.peek() == '}': (inc p.i; return)
    while true:
      p.skipWs()
      if p.force:
        let memStart = p.i
        var key: string
        var v: JNode
        var okMem = true
        try:
          let q = p.peek()
          key = if q == '"' or q == '\'': p.parseString(q) else: p.parseIdentKey()
          p.skipWs()
          if p.peek() != ':': p.err("expected ':'")
          inc p.i
          v = p.parseValue()
        except JsonError:
          okMem = false
        if okMem:
          let existing = result.keys.find(key)
          if existing >= 0: result.vals[existing] = v
          else: (result.keys.add key; result.vals.add v)
        else:
          p.recover(memStart, "dropped malformed object member")
          p.skipToDelim()
      else:
        let q = p.peek()
        let key = if q == '"' or q == '\'': p.parseString(q) else: p.parseIdentKey()
        p.skipWs()
        if p.peek() != ':': p.err("expected ':'")
        inc p.i
        let v = p.parseValue()
        let existing = result.keys.find(key)
        if existing >= 0:
          if p.opts.strictDupes: p.err("duplicate key")
          p.diag(p.i, "duplicate-key", "duplicate key '" & key & "' (last value wins)")
          result.vals[existing] = v
        else:
          result.keys.add key; result.vals.add v
      p.skipWs()
      let d = p.peek()
      if d == ',':
        inc p.i; p.skipWs()
        if p.peek() == '}':
          p.diag(p.i, "trailing-comma", "trailing comma in object")
          inc p.i; return
        continue
      if d == '}': (inc p.i; return)
      if p.force:
        if d == '\0': (p.recover(p.i, "unterminated object at end of input"); return)
        p.recover(p.i, "unexpected token in object"); p.skipToDelim()
        if p.peek() == '}': (inc p.i; return)
        if p.peek() == ',': (inc p.i; continue)
        return
      p.err("expected ',' or '}'")
  of '[':
    inc p.i
    result = JNode(kind: jkArr)
    p.skipWs()
    if p.peek() == ']': (inc p.i; return)
    while true:
      if p.force:
        let elemStart = p.i
        try:
          result.arr.add p.parseValue()
        except JsonError:
          p.recover(elemStart, "dropped malformed array element")
          p.skipToDelim()
      else:
        result.arr.add p.parseValue()
      p.skipWs()
      let d = p.peek()
      if d == ',':
        inc p.i; p.skipWs()
        if p.peek() == ']':
          p.diag(p.i, "trailing-comma", "trailing comma in array")
          inc p.i; return
        continue
      if d == ']': (inc p.i; return)
      if p.force:
        if d == '\0': (p.recover(p.i, "unterminated array at end of input"); return)
        p.recover(p.i, "unexpected token in array"); p.skipToDelim()
        if p.peek() == ']': (inc p.i; return)
        if p.peek() == ',': (inc p.i; continue)
        return
      p.err("expected ',' or ']'")
  of '"', '\'':
    return JNode(kind: jkStr, str: p.parseString(c))
  else:
    # numbers, non-finite, and keywords
    template nonfin(word: string, len: int, k: NFKind): untyped =
      p.diag(p.i, "non-finite", word & " has no JSON representation")
      p.i += len
      return JNode(kind: jkNonFinite, nf: k)
    if p.startsAt("Infinity"): nonfin("Infinity", 8, nfInf)
    if p.startsAt("+Infinity"): nonfin("+Infinity", 9, nfInf)
    if p.startsAt("-Infinity"): nonfin("-Infinity", 9, nfNegInf)
    if p.startsAt("-inf") or p.startsAt("-Inf"): nonfin("-inf", 4, nfNegInf)
    if p.startsAt("inf") or p.startsAt("Inf"): nonfin("inf", 3, nfInf)
    if p.startsAt("NaN") or p.startsAt("nan"): nonfin("NaN", 3, nfNan)
    if p.startsAt("true"): (p.i += 4; return JNode(kind: jkBool, b: true))
    if p.startsAt("True"):
      p.diag(p.i, "python-literal", "True is Python, not JSON")
      p.i += 4; return JNode(kind: jkBool, b: true)
    if p.startsAt("false"): (p.i += 5; return JNode(kind: jkBool, b: false))
    if p.startsAt("False"):
      p.diag(p.i, "python-literal", "False is Python, not JSON")
      p.i += 5; return JNode(kind: jkBool, b: false)
    if p.startsAt("null"): (p.i += 4; return JNode(kind: jkNull))
    if p.startsAt("None"):
      p.diag(p.i, "python-literal", "None is Python, not JSON")
      p.i += 4; return JNode(kind: jkNull)
    if c in {'+', '-', '.'} or c in Digits: return p.parseNumber()
    p.err("unexpected token")

proc parse*(text: string, opts = Options()): JNode =
  var p = Parser(s: text, i: 0, opts: opts)
  p.skipWs()
  result = p.parseValue()
  p.skipWs()
  if p.i != p.s.len: p.err("trailing data")

proc parseWithDiags*(text: string, opts = Options()): (JNode, seq[Diag]) =
  var p = Parser(s: text, i: 0, opts: opts, collectDiags: true)
  p.skipWs()
  let v = p.parseValue()
  p.skipWs()
  if p.i != p.s.len: p.err("trailing data")
  (v, p.diags)

proc parseForce*(text: string, opts = Options()): (JNode, seq[Diag]) =
  ## Best-effort recovery parse (--force): salvage as much as parses, dropping
  ## malformed members/elements and trailing garbage, recording warnings.
  var p = Parser(s: text, i: 0, opts: opts, force: true)
  p.skipWs()
  var val: JNode
  try:
    val = p.parseValue()
  except JsonError:
    p.recover(p.i, "could not parse a value; using null")
    val = JNode(kind: jkNull)
  p.skipWs()
  if p.i != p.s.len:
    p.recover(p.i, "dropped trailing data after the value")
  (val, p.fwarn)

proc parseStream*(text: string, opts = Options()): seq[JNode] =
  ## Parse a sequence of top-level values: RFC 7464 JSON Text Sequences
  ## (RS-prefixed, LF-terminated records), whitespace-separated values, and
  ## directly concatenated values — all handled by one lenient reader.
  var p = Parser(s: text, i: 0, opts: opts)
  while true:
    while true:                                  # skip ws / comments / RS framing
      p.skipWs()
      if p.i < p.s.len and p.s[p.i] == '\x1E': inc p.i
      else: break
    if p.i >= p.s.len: break
    result.add p.parseValue()

# ---------------------------------------------------------------------------
# §2  canonical serializer
# ---------------------------------------------------------------------------

proc encString(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\x08': result.add "\\b"
    of '\x09': result.add "\\t"
    of '\x0A': result.add "\\n"
    of '\x0C': result.add "\\f"
    of '\x0D': result.add "\\r"
    else:
      if ord(c) < 0x20: result.add "\\u" & toHex(ord(c), 4).toLowerAscii
      else: result.add c
  result.add "\""

proc utf16Key(s: string): seq[uint16] =
  ## UTF-16 code-unit sequence of `s`, used for RFC 8785 (JCS) key ordering.
  ## Differs from code-point order only for astral characters (surrogate pairs).
  for r in s.runes:
    let cp = int(r)
    if cp <= 0xFFFF: result.add uint16(cp)
    else:
      let c = cp - 0x10000
      result.add uint16(0xD800 + (c shr 10))
      result.add uint16(0xDC00 + (c and 0x3FF))

proc cmpUtf16(a, b: string): int =
  let ka = utf16Key(a)
  let kb = utf16Key(b)
  let n = min(ka.len, kb.len)
  for i in 0 ..< n:
    if ka[i] != kb[i]: return (if ka[i] < kb[i]: -1 else: 1)
  cmp(ka.len, kb.len)

proc nonFinite(nf: NFKind, path: string, opts: Options): string =
  case opts.nan
  of npNull: "null"
  of npString:
    case nf
    of nfNan: "\"NaN\""
    of nfInf: "\"Infinity\""
    of nfNegInf: "\"-Infinity\""
  of npError:
    raise newException(JsonError,
      "non-finite number at " & (if path.len > 0: path else: "<root>") &
      "; choose a policy with --nan=null|string")

proc jcsNumber(tok, path: string, opts: Options): string =
  ## RFC 8785 number: parse the token to an IEEE-754 double and emit via the
  ## ECMAScript Number::toString algorithm (Ryu). Lenient token forms (+, leading
  ## zeros, hex-derived decimals) are first reduced to a clean decimal string.
  let f = parseFloat(canonNumber(tok, false, nfPlain))
  case classify(f)
  of fcNan: nonFinite(nfNan, path, opts)
  of fcInf: nonFinite(nfInf, path, opts)
  of fcNegInf: nonFinite(nfNegInf, path, opts)
  else: ecmaScriptNumberToString(f)

proc writeNode(n: JNode, outp: var string, path: string, opts: Options) =
  case n.kind
  of jkNull: outp.add "null"
  of jkBool: outp.add (if n.b: "true" else: "false")
  of jkNum:
    if opts.jcs: outp.add jcsNumber(n.num, path, opts)
    else: outp.add canonNumber(n.num, opts.preserveNumberType, opts.numberFormat)
  of jkStr: outp.add encString(n.str)
  of jkNonFinite: outp.add nonFinite(n.nf, path, opts)
  of jkArr:
    outp.add "["
    for i, item in n.arr:
      if i > 0: outp.add ","
      writeNode(item, outp, path & "[" & $i & "]", opts)
    outp.add "]"
  of jkObj:
    outp.add "{"
    var idx = toSeq(0 ..< n.keys.len)
    if opts.jcs:
      idx.sort(proc(a, b: int): int = cmpUtf16(n.keys[a], n.keys[b]))
    else:
      idx.sort(proc(a, b: int): int = cmp(n.keys[a], n.keys[b]))
    for j, ix in idx:
      if j > 0: outp.add ","
      outp.add encString(n.keys[ix])
      outp.add ":"
      writeNode(n.vals[ix], outp, path & "." & n.keys[ix], opts)
    outp.add "}"

proc serialize*(n: JNode, opts = Options()): string =
  writeNode(n, result, "", opts)

# ---------------------------------------------------------------------------
# lint  (see README)
# ---------------------------------------------------------------------------

type Issue* = tuple[loc, category, message: string]

proc lineCol(text: string, pos: int): string =
  var line = 1
  var lastNl = -1
  for i in 0 ..< pos:
    if i < text.len and text[i] == '\n': (inc line; lastNl = i)
  $line & ":" & $(pos - lastNl)

proc structural(n: JNode, path: string, fmt: NumberFormat, outp: var seq[Issue]) =
  let here = if path.len > 0: path else: "$"
  case n.kind
  of jkNum:
    let canon = canonNumber(n.num, false, fmt)
    if canon != n.num: outp.add((here, "number", n.num & " → " & canon))
  of jkArr:
    for i, item in n.arr: structural(item, path & "[" & $i & "]", fmt, outp)
  of jkObj:
    var sorted = n.keys
    sort(sorted)
    if sorted != n.keys: outp.add((here, "key-order", "object keys are not sorted"))
    for ix in 0 ..< n.keys.len:
      structural(n.vals[ix], path & "." & n.keys[ix], fmt, outp)
  else: discard

proc lint*(raw: string, encoding = "", numberFormat = nfPlain): seq[Issue] =
  for pair in [("\xEF\xBB\xBF", "UTF-8"), ("\xFF\xFE\x00\x00", "UTF-32-LE"),
               ("\x00\x00\xFE\xFF", "UTF-32-BE"), ("\xFF\xFE", "UTF-16-LE"),
               ("\xFE\xFF", "UTF-16-BE")]:
    if raw.startsWith(pair[0]):
      result.add(("1:1", "bom", pair[1] & " BOM present")); break
  let text = decodeBytes(raw, encoding)
  let (val, diags) = parseWithDiags(text, Options())
  for d in diags:
    result.add((lineCol(text, d.pos), d.category, d.message))
  structural(val, "$", numberFormat, result)

# --- I-JSON conformance (RFC 7493) -----------------------------------------

const SafeInt = "9007199254740991"  # 2^53 - 1

proc ijsonNumber(tok: string): string =
  ## I-JSON number rule: integers within ±(2^53-1), every number exactly
  ## representable as binary64. Returns a violation message, or "" if fine.
  let plain = canonNumber(tok, false, nfPlain)
  let digits = if plain.len > 0 and plain[0] == '-': plain[1..^1] else: plain
  if '.' notin plain and
     (digits.len > SafeInt.len or (digits.len == SafeInt.len and digits > SafeInt)):
    return plain & " is an integer outside the I-JSON safe range ±(2^53-1)"
  let f = parseFloat(plain)
  case classify(f)
  of fcInf, fcNegInf: return plain & " is outside binary64 range"
  else:
    if canonNumber(ecmaScriptNumberToString(f), false, nfPlain) != plain:
      return plain & " is not exactly representable as binary64 (loses precision)"
  ""

proc hasLoneSurrogate(s: string): bool =
  for r in s.runes:
    if int(r) >= 0xD800 and int(r) <= 0xDFFF: return true
  false

proc ijsonWalk(n: JNode, path: string, outp: var seq[Issue]) =
  let here = if path.len > 0: path else: "$"
  case n.kind
  of jkNum:
    let msg = ijsonNumber(n.num)
    if msg.len > 0: outp.add((here, "number", msg))
  of jkStr:
    if hasLoneSurrogate(n.str):
      outp.add((here, "surrogate", "string contains an unpaired surrogate"))
  of jkArr:
    for i, item in n.arr: ijsonWalk(item, path & "[" & $i & "]", outp)
  of jkObj:
    for ix in 0 ..< n.keys.len:
      if hasLoneSurrogate(n.keys[ix]):
        outp.add((path & "." & n.keys[ix], "surrogate", "key contains an unpaired surrogate"))
      ijsonWalk(n.vals[ix], path & "." & n.keys[ix], outp)
  else: discard

proc ijson*(raw: string, encoding = ""): seq[Issue] =
  ## I-JSON (RFC 7493) conformance violations; empty == conformant. I-JSON is a
  ## strict subset of RFC 8259, so every non-JSON lexical feature the parser
  ## reports is also a violation; plus the semantic rules (number range/precision,
  ## unpaired surrogates).
  for pair in [("\xEF\xBB\xBF", "UTF-8"), ("\xFF\xFE\x00\x00", "UTF-32-LE"),
               ("\x00\x00\xFE\xFF", "UTF-32-BE"), ("\xFF\xFE", "UTF-16-LE"),
               ("\xFE\xFF", "UTF-16-BE")]:
    if raw.startsWith(pair[0]):
      result.add(("1:1", "bom", pair[1] & " BOM present (I-JSON requires UTF-8, no BOM)")); break
  let text = decodeBytes(raw, encoding)
  let (val, diags) = parseWithDiags(text, Options())
  for d in diags:
    result.add((lineCol(text, d.pos), d.category, d.message))
  ijsonWalk(val, "$", result)

# --- GeoJSON conformance (RFC 7946) ----------------------------------------

const GeojsonTypes = ["Point", "MultiPoint", "LineString", "MultiLineString",
                      "Polygon", "MultiPolygon", "GeometryCollection",
                      "Feature", "FeatureCollection"]
const GeometryTypes = ["Point", "MultiPoint", "LineString", "MultiLineString",
                       "Polygon", "MultiPolygon", "GeometryCollection"]

proc gjMember(n: JNode, key: string): JNode =
  if n.kind != jkObj: return nil
  let i = n.keys.find(key)
  if i >= 0: n.vals[i] else: nil

proc gjHasKey(n: JNode, key: string): bool =
  n.kind == jkObj and n.keys.find(key) >= 0

proc gjFloat(n: JNode): float = parseFloat(canonNumber(n.num, false, nfPlain))

proc gjPosition(pos: JNode, path: string, outp: var seq[Issue]): bool =
  if pos.kind != jkArr or pos.arr.len < 2:
    outp.add((path, "geojson-coordinates", "position must have at least two numbers"))
    return false
  result = true
  for i, c in pos.arr:
    if c.kind != jkNum:
      outp.add((path & "[" & $i & "]", "geojson-coordinates", "coordinate is not a number"))
      result = false

proc gjPosEq(a, b: JNode): bool =
  if a.kind != jkArr or b.kind != jkArr or a.arr.len != b.arr.len: return false
  for i in 0 ..< a.arr.len:
    if a.arr[i].kind != jkNum or b.arr[i].kind != jkNum: return false
    if canonNumber(a.arr[i].num) != canonNumber(b.arr[i].num): return false
  true

proc gjRingArea(ring: JNode): float =
  for i in 0 ..< ring.arr.len - 1:
    let p = ring.arr[i]
    let q = ring.arr[i+1]
    result += gjFloat(p.arr[0]) * gjFloat(q.arr[1]) - gjFloat(q.arr[0]) * gjFloat(p.arr[1])
  result = result / 2

proc gjPolygon(coords: JNode, path: string, outp: var seq[Issue]) =
  if coords.kind != jkArr:
    outp.add((path, "geojson-coordinates", "Polygon coordinates must be an array of rings")); return
  for r, ring in coords.arr:
    let rp = path & "[" & $r & "]"
    if ring.kind != jkArr or ring.arr.len < 4:
      outp.add((rp, "geojson-ring", "linear ring must have at least four positions")); continue
    var valid = true
    for i, p in ring.arr:
      if not gjPosition(p, rp & "[" & $i & "]", outp): valid = false
    if not gjPosEq(ring.arr[0], ring.arr[^1]):
      outp.add((rp, "geojson-ring", "linear ring is not closed (first != last position)")); continue
    if valid:
      let area = gjRingArea(ring)
      if r == 0 and area < 0:
        outp.add((rp, "geojson-winding", "exterior ring should be counterclockwise (RFC 7946 §3.1.6)"))
      elif r > 0 and area > 0:
        outp.add((rp, "geojson-winding", "interior ring (hole) should be clockwise (RFC 7946 §3.1.6)"))

proc gjGeometry(obj: JNode, path: string, outp: var seq[Issue]) =
  if obj.kind != jkObj:
    outp.add((path, "geojson-type", "geometry must be an object")); return
  let t = gjMember(obj, "type")
  if t == nil or t.kind != jkStr or t.str notin GeometryTypes:
    outp.add((path, "geojson-type", "invalid or missing geometry type")); return
  if t.str == "GeometryCollection":
    let geoms = gjMember(obj, "geometries")
    if geoms == nil or geoms.kind != jkArr:
      outp.add((path, "geojson-member", "GeometryCollection requires a 'geometries' array"))
    else:
      for i, g in geoms.arr: gjGeometry(g, path & ".geometries[" & $i & "]", outp)
    return
  let coords = gjMember(obj, "coordinates")
  if coords == nil:
    outp.add((path, "geojson-member", t.str & " requires a 'coordinates' member")); return
  let cp = path & ".coordinates"
  case t.str
  of "Point": discard gjPosition(coords, cp, outp)
  of "MultiPoint", "LineString":
    if coords.kind == jkArr:
      for i, p in coords.arr: discard gjPosition(p, cp & "[" & $i & "]", outp)
      if t.str == "LineString" and coords.arr.len < 2:
        outp.add((cp, "geojson-coordinates", "LineString needs at least two positions"))
  of "MultiLineString":
    if coords.kind == jkArr:
      for i, line in coords.arr:
        if line.kind == jkArr:
          for j, p in line.arr: discard gjPosition(p, cp & "[" & $i & "][" & $j & "]", outp)
  of "Polygon": gjPolygon(coords, cp, outp)
  of "MultiPolygon":
    if coords.kind == jkArr:
      for i, poly in coords.arr: gjPolygon(poly, cp & "[" & $i & "]", outp)
  else: discard

proc gjObject(obj: JNode, path: string, outp: var seq[Issue]) =
  let here = if path.len > 0: path else: "$"
  if obj.kind != jkObj:
    outp.add((here, "geojson-type", "GeoJSON value must be an object")); return
  if gjMember(obj, "crs") != nil:
    outp.add((here, "geojson-crs", "'crs' member was removed in RFC 7946 (assume WGS 84)"))
  let bbox = gjMember(obj, "bbox")
  if bbox != nil:
    var okb = bbox.kind == jkArr and bbox.arr.len >= 4 and bbox.arr.len mod 2 == 0
    if okb:
      for x in bbox.arr:
        if x.kind != jkNum: okb = false
    if not okb:
      outp.add((here & ".bbox", "geojson-bbox", "bbox must be an array of 2*n numbers (n>=2)"))
  let t = gjMember(obj, "type")
  if t == nil or t.kind != jkStr or t.str notin GeojsonTypes:
    outp.add((here, "geojson-type", "invalid or missing GeoJSON 'type'")); return
  if t.str == "FeatureCollection":
    let feats = gjMember(obj, "features")
    if feats == nil or feats.kind != jkArr:
      outp.add((here, "geojson-member", "FeatureCollection requires a 'features' array"))
    else:
      for i, f in feats.arr: gjObject(f, path & ".features[" & $i & "]", outp)
  elif t.str == "Feature":
    let geom = gjMember(obj, "geometry")
    if not gjHasKey(obj, "geometry"):
      outp.add((here, "geojson-member", "Feature requires a 'geometry' member (may be null)"))
    elif geom.kind != jkNull:
      gjGeometry(geom, path & ".geometry", outp)
    if not gjHasKey(obj, "properties"):
      outp.add((here, "geojson-member", "Feature requires a 'properties' member (object or null)"))
  else:
    gjGeometry(obj, path, outp)

proc geojson*(raw: string, encoding = ""): seq[Issue] =
  ## GeoJSON (RFC 7946) conformance violations; empty == conformant.
  let val = parse(decodeBytes(raw, encoding))
  gjObject(val, "$", result)

# --- JData / NeuroJSON N-D array decoding ----------------------------------

proc jdDim(n: JNode): int = parseInt(canonNumber(n.num, false, nfPlain))

proc reshapeJ(data: seq[JNode], dims: seq[int], di, lo, hi: int): JNode =
  result = JNode(kind: jkArr)
  if di == dims.high:
    for i in lo ..< hi: result.arr.add data[i]
  else:
    var step = 1
    for d in dims[di+1 .. ^1]: step *= d
    for k in 0 ..< dims[di]:
      result.arr.add reshapeJ(data, dims, di + 1, lo + k * step, lo + (k + 1) * step)

proc decodeJdata*(n: JNode): JNode =
  ## Expand JData annotated arrays into nested JSON arrays (row-major). Other
  ## objects/arrays are walked transparently. See python/jsoncanon/jdata.py.
  case n.kind
  of jkObj:
    if gjHasKey(n, "_ArrayZipData_"):
      raise newException(JsonError, "JData: compressed arrays (_ArrayZipData_) are not supported")
    if gjHasKey(n, "_ArrayType_") and gjHasKey(n, "_ArraySize_") and gjHasKey(n, "_ArrayData_"):
      let sizeN = gjMember(n, "_ArraySize_")
      var dims: seq[int]
      if sizeN.kind == jkArr:
        for x in sizeN.arr: dims.add jdDim(x)
      elif sizeN.kind == jkNum: dims.add jdDim(sizeN)
      else: raise newException(JsonError, "JData: _ArraySize_ must be a number or array of numbers")
      let dataN = gjMember(n, "_ArrayData_")
      if dataN.kind != jkArr: raise newException(JsonError, "JData: _ArrayData_ must be an array")
      var flat: seq[JNode]
      for e in dataN.arr: flat.add decodeJdata(e)
      var prod = 1
      for d in dims: prod *= d
      if dims.len == 0 or prod != flat.len:
        raise newException(JsonError, "JData: _ArrayData_ length does not match _ArraySize_")
      return reshapeJ(flat, dims, 0, 0, flat.len)
    result = JNode(kind: jkObj)
    for ix in 0 ..< n.keys.len:
      result.keys.add n.keys[ix]
      result.vals.add decodeJdata(n.vals[ix])
  of jkArr:
    result = JNode(kind: jkArr)
    for e in n.arr: result.arr.add decodeJdata(e)
  else: result = n

# ---------------------------------------------------------------------------
# §5  JCS precision warnings
# ---------------------------------------------------------------------------

proc collectJcsWarnings*(n: JNode, path: string, acc: var seq[string]) =
  ## Record every number whose value *changes* under JCS — i.e. the IEEE-754
  ## double cannot represent the input decimal exactly, so the canonical output
  ## no longer round-trips to the original. The default decimal engine is the
  ## lossless arbiter: a change happened iff the exact decimal value of the token
  ## differs from the exact decimal value of the Ryu output.
  case n.kind
  of jkNum:
    let plain = canonNumber(n.num, false, nfPlain)   # exact value of the token
    let here = if path.len > 0: path else: "<root>"
    let f = parseFloat(plain)
    case classify(f)
    of fcNan, fcInf, fcNegInf:
      acc.add here & ": " & n.num.strip() & " exceeds binary64 range (no JCS parity)"
    else:
      let jcsOut = ecmaScriptNumberToString(f)
      if canonNumber(jcsOut, false, nfPlain) != plain:
        acc.add here & ": " & plain & " → " & jcsOut &
                " (IEEE-754 rounding; not reversible)"
  of jkArr:
    for i, item in n.arr: collectJcsWarnings(item, path & "[" & $i & "]", acc)
  of jkObj:
    for ix in 0 ..< n.keys.len:
      collectJcsWarnings(n.vals[ix], path & "." & n.keys[ix], acc)
  else: discard

# ---------------------------------------------------------------------------
# top-level
# ---------------------------------------------------------------------------

proc canonicalize*(data: string, opts = Options(), encoding = "",
                   ndjson = false, newline = false,
                   outputEncoding = "utf-8", bom = false,
                   warnings: ptr seq[string] = nil, jsonSeq = false,
                   force = false, forceWarn: ptr seq[string] = nil,
                   transform: proc(n: JNode): JNode = nil): string =
  ## When `opts.jcs` and `warnings != nil`, value-changing numbers (§5) are
  ## appended to `warnings[]`. When `force`, malformed input is salvaged and
  ## recovery notes appended to `forceWarn[]`. Output bytes unaffected by either.
  let text = decodeBytes(data, encoding)
  let warn = opts.jcs and warnings != nil

  proc parseOne(t: string): JNode =
    if force:
      let (n, ws) = parseForce(t, opts)
      if forceWarn != nil:
        for (pos, _, msg) in ws: forceWarn[].add(lineCol(t, pos) & "  " & msg)
      result = n
    else: result = parse(t, opts)
    if transform != nil: result = transform(result)

  var outp: string
  if ndjson or jsonSeq:
    var parts: seq[string]
    let nodes = if jsonSeq and not force: parseStream(text, opts)
                else: (block:
                  var ns: seq[JNode]
                  for line in text.splitLines:
                    if line.strip().len != 0: ns.add parseOne(line)
                  ns)
    let label = if jsonSeq: "value " else: "line "
    for idx, node in nodes:
      if warn: collectJcsWarnings(node, label & $(idx + 1), warnings[])
      parts.add serialize(node, opts)
    outp = parts.join("\n")
  else:
    let node = parseOne(text)
    if warn: collectJcsWarnings(node, "", warnings[])
    outp = serialize(node, opts)
  if newline: outp.add "\n"
  encodeOutput(outp, outputEncoding, bom)

# ---------------------------------------------------------------------------
# structural diff (--diff)
# ---------------------------------------------------------------------------

proc sortedUnionKeys(a, b: JNode, opts: Options): seq[string] =
  for k in a.keys: result.add k
  for k in b.keys:
    if k notin result: result.add k
  if opts.jcs: result.sort(cmpUtf16) else: result.sort()

proc diffNodes(a, b: JNode, path: string, opts: Options, outp: var seq[string]) =
  let here = if path.len > 0: path else: "$"
  if a.kind != b.kind:
    outp.add("~ " & here & ": " & serialize(a, opts) & " => " & serialize(b, opts))
    return
  case a.kind
  of jkObj:
    for key in sortedUnionKeys(a, b, opts):
      let ia = a.keys.find(key)
      let ib = b.keys.find(key)
      let cp = path & "." & key
      if ia < 0: outp.add("+ " & cp & ": " & serialize(b.vals[ib], opts))
      elif ib < 0: outp.add("- " & cp & ": " & serialize(a.vals[ia], opts))
      else: diffNodes(a.vals[ia], b.vals[ib], cp, opts, outp)
  of jkArr:
    for i in 0 ..< max(a.arr.len, b.arr.len):
      let cp = path & "[" & $i & "]"
      if i >= a.arr.len: outp.add("+ " & cp & ": " & serialize(b.arr[i], opts))
      elif i >= b.arr.len: outp.add("- " & cp & ": " & serialize(a.arr[i], opts))
      else: diffNodes(a.arr[i], b.arr[i], cp, opts, outp)
  else:
    let sa = serialize(a, opts)
    let sb = serialize(b, opts)
    if sa != sb: outp.add("~ " & here & ": " & sa & " => " & sb)

proc diff*(rawA, rawB: string, opts = Options(), encoding = ""): seq[string] =
  ## Structural difference between two inputs *after* canonicalization, so
  ## whitespace / key-order / number-spelling noise is gone. Lines:
  ##   `~ PATH: old => new` (changed),  `+ PATH: val` (only in B),
  ##   `- PATH: val` (only in A). Empty == canonically identical.
  let a = parse(decodeBytes(rawA, encoding), opts)
  let b = parse(decodeBytes(rawB, encoding), opts)
  diffNodes(a, b, "$", opts, result)
