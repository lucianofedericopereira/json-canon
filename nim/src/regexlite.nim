## Small regex-subset engine — the mirror of python/jsoncanon/_regex.py, used by
## the JSON Schema validator's `pattern` keyword. Identical backtracking
## semantics so the two stay byte-parity. Operates on Unicode code points (like
## Python's per-character str indexing). NOT a general regex library.

import std/[unicode, strutils]
import ./jsoncanon  # for JsonError

type
  ReKind = enum rkAlt, rkSeq, rkRep, rkLit, rkDot, rkClass, rkBol, rkEol
  ReNode = ref object
    case kind: ReKind
    of rkAlt, rkSeq: kids: seq[ReNode]
    of rkRep:
      sub: ReNode
      lo, hi: int            # hi == -1 means unbounded
    of rkLit: cp: int
    of rkClass:
      neg: bool
      ranges: seq[(int, int)]
    of rkDot, rkBol, rkEol: discard

const
  DIGIT = @[(int('0'), int('9'))]
  WORD = @[(int('0'), int('9')), (int('A'), int('Z')), (int('a'), int('z')), (int('_'), int('_'))]
  SPACE = @[(0x20, 0x20), (0x09, 0x09), (0x0A, 0x0A), (0x0D, 0x0D), (0x0C, 0x0C), (0x0B, 0x0B)]

# --- parser ----------------------------------------------------------------

type ReParser = object
  s: seq[int]      # pattern as code points
  i: int

proc cps(s: string): seq[int] =
  for r in s.runes: result.add int(r)

proc reAlt(p: var ReParser): ReNode
proc reClassChar(p: var ReParser): int =
  if p.s[p.i] == int('\\'):
    inc p.i
    let e = p.s[p.i]
    inc p.i
    result = case char(e)
      of 'n': int('\n')
      of 't': int('\t')
      of 'r': int('\r')
      of 'f': int('\f')
      of 'v': int('\v')
      else: e
  else:
    result = p.s[p.i]
    inc p.i

proc reClass(p: var ReParser): ReNode =
  inc p.i  # [
  result = ReNode(kind: rkClass)
  if p.i < p.s.len and p.s[p.i] == int('^'):
    result.neg = true; inc p.i
  while p.i < p.s.len and p.s[p.i] != int(']'):
    let lo = reClassChar(p)
    if p.i + 1 < p.s.len and p.s[p.i] == int('-') and p.s[p.i+1] != int(']'):
      inc p.i
      result.ranges.add((lo, reClassChar(p)))
    else:
      result.ranges.add((lo, lo))
  if p.i >= p.s.len: raise newException(JsonError, "regex: unterminated [")
  inc p.i  # ]

proc reEscape(p: var ReParser): ReNode =
  inc p.i
  if p.i >= p.s.len: raise newException(JsonError, "regex: trailing backslash")
  let e = p.s[p.i]
  inc p.i
  case char(e)
  of 'd': ReNode(kind: rkClass, neg: false, ranges: DIGIT)
  of 'D': ReNode(kind: rkClass, neg: true, ranges: DIGIT)
  of 'w': ReNode(kind: rkClass, neg: false, ranges: WORD)
  of 'W': ReNode(kind: rkClass, neg: true, ranges: WORD)
  of 's': ReNode(kind: rkClass, neg: false, ranges: SPACE)
  of 'S': ReNode(kind: rkClass, neg: true, ranges: SPACE)
  of 'n': ReNode(kind: rkLit, cp: int('\n'))
  of 't': ReNode(kind: rkLit, cp: int('\t'))
  of 'r': ReNode(kind: rkLit, cp: int('\r'))
  of 'f': ReNode(kind: rkLit, cp: int('\f'))
  of 'v': ReNode(kind: rkLit, cp: int('\v'))
  else: ReNode(kind: rkLit, cp: e)

proc reAtom(p: var ReParser): ReNode =
  let c = p.s[p.i]
  if c == int('('):
    inc p.i
    if p.i + 1 < p.s.len and p.s[p.i] == int('?') and p.s[p.i+1] == int(':'):
      p.i += 2
    result = reAlt(p)
    if p.i >= p.s.len or p.s[p.i] != int(')'): raise newException(JsonError, "regex: unterminated (")
    inc p.i
  elif c == int('['): result = reClass(p)
  elif c == int('.'): (inc p.i; result = ReNode(kind: rkDot))
  elif c == int('^'): (inc p.i; result = ReNode(kind: rkBol))
  elif c == int('$'): (inc p.i; result = ReNode(kind: rkEol))
  elif c == int('\\'): result = reEscape(p)
  else: (inc p.i; result = ReNode(kind: rkLit, cp: c))

proc reQuantified(p: var ReParser): ReNode =
  let atom = reAtom(p)
  if p.i < p.s.len and p.s[p.i] in [int('*'), int('+'), int('?')]:
    let q = char(p.s[p.i])
    inc p.i
    case q
    of '*': ReNode(kind: rkRep, sub: atom, lo: 0, hi: -1)
    of '+': ReNode(kind: rkRep, sub: atom, lo: 1, hi: -1)
    else: ReNode(kind: rkRep, sub: atom, lo: 0, hi: 1)
  elif p.i < p.s.len and p.s[p.i] == int('{'):
    var j = p.i + 1
    var body = ""
    while j < p.s.len and p.s[j] != int('}'): (body.add char(p.s[j]); inc j)
    if j >= p.s.len: raise newException(JsonError, "regex: unterminated {")
    p.i = j + 1
    var lo, hi: int
    let comma = body.find(',')
    if comma >= 0:
      let a = body[0 ..< comma]
      let b = body[comma+1 .. ^1]
      lo = if a.len > 0: parseInt(a) else: 0
      hi = if b.len > 0: parseInt(b) else: -1
    else:
      lo = parseInt(body); hi = lo
    ReNode(kind: rkRep, sub: atom, lo: lo, hi: hi)
  else: atom

proc reSeq(p: var ReParser): ReNode =
  result = ReNode(kind: rkSeq)
  while p.i < p.s.len and p.s[p.i] != int('|') and p.s[p.i] != int(')'):
    result.kids.add reQuantified(p)

proc reAlt(p: var ReParser): ReNode =
  var branches = @[reSeq(p)]
  while p.i < p.s.len and p.s[p.i] == int('|'):
    inc p.i
    branches.add reSeq(p)
  if branches.len > 1: ReNode(kind: rkAlt, kids: branches) else: branches[0]

proc parseRegex(pattern: string): ReNode =
  var p = ReParser(s: cps(pattern), i: 0)
  result = reAlt(p)
  if p.i != p.s.len: raise newException(JsonError, "regex: unexpected character")

# --- matcher ---------------------------------------------------------------

proc inRanges(cp: int, ranges: seq[(int, int)]): bool =
  for (lo, hi) in ranges:
    if lo <= cp and cp <= hi: return true
  false

proc matchNode(node: ReNode, s: seq[int], i: int, k: proc(j: int): bool): bool =
  case node.kind
  of rkSeq:
    proc run(idx, j: int): bool =
      if idx == node.kids.len: return k(j)
      matchNode(node.kids[idx], s, j, proc(j2: int): bool = run(idx + 1, j2))
    run(0, i)
  of rkAlt:
    for b in node.kids:
      if matchNode(b, s, i, k): return true
    false
  of rkRep:
    proc rec(count, j: int, prevEmpty: bool): bool =
      if node.hi == -1 or count < node.hi:
        let after = proc(j2: int): bool =
          if j2 == j and prevEmpty: return false
          rec(count + 1, j2, j2 == j)
        if matchNode(node.sub, s, j, after): return true
      if count >= node.lo: return k(j)
      # below minimum with only empty matches left: empties satisfy the minimum.
      if matchNode(node.sub, s, j, proc(j2: int): bool = j2 == j): return k(j)
      false
    rec(0, i, false)
  of rkLit: i < s.len and s[i] == node.cp and k(i + 1)
  of rkDot: i < s.len and s[i] != int('\n') and k(i + 1)
  of rkClass:
    if i >= s.len: false
    else: (inRanges(s[i], node.ranges) != node.neg) and k(i + 1)
  of rkBol: i == 0 and k(i)
  of rkEol: i == s.len and k(i)

proc reSearch*(pattern, text: string): bool =
  ## True if `pattern` matches anywhere in `text` (unanchored).
  let ast = parseRegex(pattern)
  let t = cps(text)
  let accept = proc(j: int): bool = true
  for start in 0 .. t.len:
    if matchNode(ast, t, start, accept): return true
  false
