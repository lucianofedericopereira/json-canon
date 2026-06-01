## jsoncanon — canonical JSON normalizer (see ../../SPEC.md).
##
## Independent Nim implementation, byte-identical to the Python reference.

import std/[strutils, algorithm, unicode, sequtils]

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
    E = parseInt(s[eIdx+1..^1])
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

proc err(p: Parser, msg: string) {.noreturn.} =
  raise newException(JsonError, msg & " at position " & $p.i)

proc diag(p: var Parser, pos: int, category, message: string) =
  if p.collectDiags: p.diags.add((pos, category, message))

const WS = {' ', '\t', '\n', '\r', '\x0B', '\x0C'}  # JSON5: + vtab / formfeed
const HexDigits = {'0'..'9', 'a'..'f', 'A'..'F'}

proc isIdentStart(c: char): bool = c in {'A'..'Z', 'a'..'z', '_', '$'}
proc isIdentPart(c: char): bool = c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '$'}

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
  if tok.len == 0 or tok == "+" or tok == "-": p.err("invalid number")
  let body = if tok[0] in {'+', '-'}: tok[1..^1] else: tok
  if tok[0] == '+':
    p.diag(start, "number-syntax", "leading '+' in number '" & tok & "'")
  elif body.len > 1 and body[0] == '0' and body[1] in Digits:
    p.diag(start, "number-syntax", "leading zero in number '" & tok & "'")
  elif body.len > 0 and (body[0] == '.' or body[^1] == '.'):
    p.diag(start, "number-syntax", "missing digit in number '" & tok & "'")
  JNode(kind: jkNum, num: tok)

proc parseIdentKey(p: var Parser): string =
  let start = p.i
  if p.i >= p.s.len or not isIdentStart(p.s[p.i]): p.err("expected string key")
  inc p.i
  while p.i < p.s.len and isIdentPart(p.s[p.i]): inc p.i
  p.diag(start, "unquoted-key",
         "unquoted key '" & p.s[start..<p.i] & "' is JSON5, not JSON")
  p.s[start..<p.i]

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
      p.err("expected ',' or '}'")
  of '[':
    inc p.i
    result = JNode(kind: jkArr)
    p.skipWs()
    if p.peek() == ']': (inc p.i; return)
    while true:
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

proc writeNode(n: JNode, outp: var string, path: string, opts: Options) =
  case n.kind
  of jkNull: outp.add "null"
  of jkBool: outp.add (if n.b: "true" else: "false")
  of jkNum: outp.add canonNumber(n.num, opts.preserveNumberType, opts.numberFormat)
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

# ---------------------------------------------------------------------------
# top-level
# ---------------------------------------------------------------------------

proc canonicalize*(data: string, opts = Options(), encoding = "",
                   ndjson = false, newline = false,
                   outputEncoding = "utf-8", bom = false): string =
  let text = decodeBytes(data, encoding)
  var outp: string
  if ndjson:
    var parts: seq[string]
    for line in text.splitLines:
      if line.strip().len == 0: continue
      parts.add serialize(parse(line, opts), opts)
    outp = parts.join("\n")
  else:
    outp = serialize(parse(text, opts), opts)
  if newline: outp.add "\n"
  encodeOutput(outp, outputEncoding, bom)
