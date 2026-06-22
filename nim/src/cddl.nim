## CDDL (RFC 8610) validator — practical subset. Mirror of
## python/jsoncanon/cddl.py; deterministic, so error lists are byte-identical.
## Supported: type rules, choices (`a / b`), primitive types, literals, numeric
## ranges, arrays/maps with occurrences (`? * + n*m`), and rule references.
## Out of scope: groups/sockets/generics, control operators, tags, recursion.

import std/[strutils, tables]
import ./jsoncanon

type
  CddlKind = enum ckChoice, ckRef, ckPrim, ckLit, ckRange, ckArr, ckMap
  LitKind = enum lkStr, lkNum, lkBool
  Occur = tuple[lo, hi: int, unbounded: bool]
  CddlNode = ref object
    case kind: CddlKind
    of ckChoice: alts: seq[CddlNode]
    of ckRef: name: string
    of ckPrim: prim: string
    of ckLit:
      lk: LitKind
      sval: string
      bval: bool
    of ckRange: lo, hi: string
    of ckArr: entries: seq[(Occur, CddlNode)]
    of ckMap: members: seq[(Occur, string, CddlNode)]

const CddlPrims = ["bool", "int", "uint", "nint", "float", "float16", "float32",
                   "float64", "number", "tstr", "text", "bstr", "bytes", "any"]

# --- tokenizer -------------------------------------------------------------

proc cddlTokens(src: string): seq[(string, string)] =
  var i = 0
  let n = src.len
  while i < n:
    let c = src[i]
    if c in {' ', '\t', '\r', '\n'}: inc i
    elif c == ';':
      while i < n and src[i] != '\n': inc i
    elif c == '"':
      var j = i + 1
      var buf = ""
      while j < n and src[j] != '"':
        if src[j] == '\\' and j + 1 < n: (buf.add src[j+1]; j += 2; continue)
        buf.add src[j]; inc j
      result.add ("str", buf); i = j + 1
    elif i + 1 < n and (src[i..i+1] == ".." or src[i..i+1] == "=>"):
      result.add ("op", src[i..i+1]); i += 2
    elif c in {'=', '{', '}', '[', ']', ':', ',', '?', '*', '+', '/', '(', ')'}:
      result.add ("op", $c); inc i
    elif c in {'0'..'9'} or (c == '-' and i + 1 < n and src[i+1] in {'0'..'9'}):
      var j = i + 1
      while j < n and (src[j] in {'0'..'9'} or
            src[j] in {'.', 'e', 'E', 'x', 'X', '+', '-', 'a','b','c','d','f','A','B','C','D','F'}):
        if src[j] == '.' and j + 1 < n and src[j+1] == '.': break
        inc j
      result.add ("num", src[i..<j]); i = j
    elif c in {'a'..'z', 'A'..'Z', '_', '$'}:
      var j = i + 1
      while j < n and src[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '$', '@'}: inc j
      result.add ("id", src[i..<j]); i = j
    else:
      raise newException(JsonError, "CDDL: unexpected character")

# --- parser ----------------------------------------------------------------

type CParser = object
  toks: seq[(string, string)]
  i: int

proc cpeek(p: CParser, k = 0): (string, string) =
  let j = p.i + k
  if j < p.toks.len: p.toks[j] else: ("eof", "")
proc cnext(p: var CParser): (string, string) =
  result = cpeek(p); inc p.i
proc ceat(p: var CParser, tok: (string, string)) =
  if cnext(p) != tok: raise newException(JsonError, "CDDL: expected '" & tok[1] & "'")

proc cType(p: var CParser): CddlNode
proc cArray(p: var CParser): CddlNode
proc cMap(p: var CParser): CddlNode

proc cOccur(p: var CParser): Occur =
  let tk = cpeek(p)
  if tk == ("op", "?"): (discard cnext(p); return (0, 1, false))
  if tk == ("op", "*"): (discard cnext(p); return (0, 0, true))
  if tk == ("op", "+"): (discard cnext(p); return (1, 0, true))
  if tk[0] == "num" and cpeek(p, 1) == ("op", "*"):
    let lo = parseInt(tk[1])
    discard cnext(p); discard cnext(p)
    if cpeek(p)[0] == "num": return (lo, parseInt(cnext(p)[1]), false)
    return (lo, 0, true)
  (1, 1, false)

proc cType1(p: var CParser): CddlNode =
  let tk = cpeek(p)
  if tk == ("op", "{"): return cMap(p)
  if tk == ("op", "["): return cArray(p)
  if tk == ("op", "("):
    discard cnext(p)
    result = cType(p)
    ceat(p, ("op", ")"))
    return result
  if tk[0] == "str": (discard cnext(p); return CddlNode(kind: ckLit, lk: lkStr, sval: tk[1]))
  if tk[0] == "num":
    discard cnext(p)
    if cpeek(p) == ("op", ".."):
      discard cnext(p)
      let hi = cnext(p)
      return CddlNode(kind: ckRange, lo: tk[1], hi: hi[1])
    return CddlNode(kind: ckLit, lk: lkNum, sval: tk[1])
  if tk[0] == "id":
    discard cnext(p)
    let name = tk[1]
    if name == "true" or name == "false":
      return CddlNode(kind: ckLit, lk: lkBool, bval: name == "true")
    if name == "null" or name == "nil":
      return CddlNode(kind: ckPrim, prim: "null")
    return CddlNode(kind: ckRef, name: name)
  raise newException(JsonError, "CDDL: unexpected token '" & tk[1] & "'")

proc cType(p: var CParser): CddlNode =
  var alts = @[cType1(p)]
  while cpeek(p) == ("op", "/"):
    discard cnext(p)
    alts.add cType1(p)
  if alts.len > 1: CddlNode(kind: ckChoice, alts: alts) else: alts[0]

proc cArray(p: var CParser): CddlNode =
  ceat(p, ("op", "["))
  result = CddlNode(kind: ckArr)
  while cpeek(p) != ("op", "]"):
    let occ = cOccur(p)
    result.entries.add((occ, cType(p)))
    if cpeek(p) == ("op", ","): discard cnext(p)
  ceat(p, ("op", "]"))

proc cMap(p: var CParser): CddlNode =
  ceat(p, ("op", "{"))
  result = CddlNode(kind: ckMap)
  while cpeek(p) != ("op", "}"):
    let occ = cOccur(p)
    let key = cnext(p)
    if key[0] notin ["id", "str"]: raise newException(JsonError, "CDDL: expected map member key")
    if cpeek(p) == ("op", ":") or cpeek(p) == ("op", "=>"): discard cnext(p)
    else: raise newException(JsonError, "CDDL: expected ':' in map member")
    result.members.add((occ, key[1], cType(p)))
    if cpeek(p) == ("op", ","): discard cnext(p)
  ceat(p, ("op", "}"))

proc parseCddl(src: string): (Table[string, CddlNode], seq[string]) =
  var p = CParser(toks: cddlTokens(src), i: 0)
  while cpeek(p)[0] != "eof":
    let nm = cnext(p)
    if nm[0] != "id": raise newException(JsonError, "CDDL: expected rule name")
    ceat(p, ("op", "="))
    result[0][nm[1]] = cType(p)
    if nm[1] notin result[1]: result[1].add nm[1]

# --- validator -------------------------------------------------------------

proc cIsInt(num: string): bool = '.' notin canonNumber(num, false, nfPlain)
proc cNumVal(num: string): float = parseFloat(canonNumber(num, false, nfPlain))

proc cPrimMatch(name: string, inst: JNode): bool =
  case name
  of "bool": inst.kind == jkBool
  of "tstr", "text", "bstr", "bytes": inst.kind == jkStr
  of "any": true
  of "float", "float16", "float32", "float64", "number": inst.kind == jkNum
  of "int": inst.kind == jkNum and cIsInt(inst.num)
  of "uint": inst.kind == jkNum and cIsInt(inst.num) and cNumVal(inst.num) >= 0
  of "nint": inst.kind == jkNum and cIsInt(inst.num) and cNumVal(inst.num) < 0
  else: false

proc cDescribe(rules: Table[string, CddlNode], ast: CddlNode): string =
  case ast.kind
  of ckChoice:
    var parts: seq[string]
    for a in ast.alts: parts.add cDescribe(rules, a)
    parts.join(" / ")
  of ckRef: ast.name
  of ckPrim: "null"
  of ckLit:
    case ast.lk
    of lkStr: "\"" & ast.sval & "\""
    of lkBool: (if ast.bval: "true" else: "false")
    of lkNum: ast.sval
  of ckRange: ast.lo & ".." & ast.hi
  of ckArr: "[...]"
  of ckMap: "{...}"

proc cMatches(rules: Table[string, CddlNode], ast: CddlNode, inst: JNode,
              path: string, errors: var seq[(string, string)]): bool

proc cTry(rules: Table[string, CddlNode], ast: CddlNode, inst: JNode, path: string): bool =
  var tmp: seq[(string, string)]
  cMatches(rules, ast, inst, path, tmp)

proc cMatchArray(rules: Table[string, CddlNode], entries: seq[(Occur, CddlNode)],
                 inst: JNode, path: string, errors: var seq[(string, string)]): bool =
  if inst.kind != jkArr: (errors.add((path, "expected array")); return false)
  var idx = 0
  for (occ, t) in entries:
    var count = 0
    while (occ.unbounded or count < occ.hi) and idx < inst.arr.len and
          cTry(rules, t, inst.arr[idx], path & "[" & $idx & "]"):
      inc idx; inc count
    if count < occ.lo:
      let p = if idx < inst.arr.len: path & "[" & $idx & "]" else: path
      errors.add((p, "expected " & cDescribe(rules, t))); return false
  if idx != inst.arr.len:
    errors.add((path & "[" & $idx & "]", "unexpected extra array element")); return false
  true

proc cMatchMap(rules: Table[string, CddlNode], members: seq[(Occur, string, CddlNode)],
               inst: JNode, path: string, errors: var seq[(string, string)]): bool =
  if inst.kind != jkObj: (errors.add((path, "expected object")); return false)
  result = true
  for (occ, key, vt) in members:
    let mi = inst.keys.find(key)
    if mi >= 0:
      if not cMatches(rules, vt, inst.vals[mi], path & "." & key, errors): result = false
    elif occ.lo >= 1:
      errors.add((path, "missing required member '" & key & "'")); result = false
  for k in inst.keys:
    var declared = false
    for (occ, key, vt) in members:
      if key == k: (declared = true; break)
    if not declared:
      errors.add((path & "." & k, "unexpected member")); result = false

proc cMatches(rules: Table[string, CddlNode], ast: CddlNode, inst: JNode,
              path: string, errors: var seq[(string, string)]): bool =
  case ast.kind
  of ckChoice:
    for alt in ast.alts:
      if cTry(rules, alt, inst, path): return true
    errors.add((path, "expected " & cDescribe(rules, ast))); false
  of ckRef:
    if ast.name in CddlPrims:
      if not cPrimMatch(ast.name, inst): (errors.add((path, "expected " & ast.name)); return false)
      true
    elif rules.hasKey(ast.name): cMatches(rules, rules[ast.name], inst, path, errors)
    else: raise newException(JsonError, "CDDL: unknown type '" & ast.name & "'")
  of ckPrim:
    if inst.kind != jkNull: (errors.add((path, "expected null")); false) else: true
  of ckLit:
    var ok: bool
    case ast.lk
    of lkStr: ok = inst.kind == jkStr and inst.str == ast.sval
    of lkBool: ok = inst.kind == jkBool and inst.b == ast.bval
    of lkNum: ok = inst.kind == jkNum and canonNumber(inst.num) == canonNumber(ast.sval)
    if not ok: errors.add((path, "expected " & cDescribe(rules, ast)))
    ok
  of ckRange:
    let ok = inst.kind == jkNum and cNumVal(ast.lo) <= cNumVal(inst.num) and
             cNumVal(inst.num) <= cNumVal(ast.hi)
    if not ok: errors.add((path, "expected " & ast.lo & ".." & ast.hi))
    ok
  of ckArr: cMatchArray(rules, ast.entries, inst, path, errors)
  of ckMap: cMatchMap(rules, ast.members, inst, path, errors)

proc validateCddl*(schemaRaw, instanceRaw: string, encoding = ""): seq[Issue] =
  let (rules, order) = parseCddl(decodeBytes(schemaRaw, encoding))
  if order.len == 0: raise newException(JsonError, "CDDL: no rules in schema")
  let inst = parse(decodeBytes(instanceRaw, encoding))
  var errors: seq[(string, string)]
  discard cMatches(rules, rules[order[0]], inst, "$", errors)
  for (p, m) in errors: result.add((p, "cddl", m))
