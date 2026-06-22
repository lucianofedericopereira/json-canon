## JSON Schema validator (Draft 2020-12 + Draft-07, practical subset) — mirror
## of python/jsoncanon/jsonschema.py. Deterministic; byte-identical error lists.
## `pattern` uses the shared regexlite engine; `format` is annotation-only.

import std/[strutils, math, unicode, tables]
import ./jsoncanon
import ./regexlite

var sAnchors: Table[string, JNode]   # $anchor name -> schema, collected per call

proc smember(o: JNode, key: string): JNode =
  if o.kind != jkObj: return nil
  let i = o.keys.find(key)
  if i >= 0: o.vals[i] else: nil

proc shas(o: JNode, key: string): bool =
  o.kind == jkObj and o.keys.find(key) >= 0

proc sptr(tokens: seq[string]): string =
  for t in tokens:
    result.add "/"
    result.add t.replace("~", "~0").replace("/", "~1")

proc snum(n: JNode): float = parseFloat(canonNumber(n.num, false, nfPlain))
proc isInteger(n: JNode): bool = n.kind == jkNum and '.' notin canonNumber(n.num, false, nfPlain)

proc typeOk(t: string, inst: JNode): bool =
  case t
  of "null": inst.kind == jkNull
  of "boolean": inst.kind == jkBool
  of "object": inst.kind == jkObj
  of "array": inst.kind == jkArr
  of "string": inst.kind == jkStr
  of "integer": isInteger(inst)
  of "number": inst.kind == jkNum
  else: false

proc collectAnchors(node: JNode, outp: var Table[string, JNode]) =
  if node.kind == jkObj:
    let a = smember(node, "$anchor")
    if a != nil and a.kind == jkStr and not outp.hasKey(a.str): outp[a.str] = node
    for v in node.vals: collectAnchors(v, outp)
  elif node.kind == jkArr:
    for v in node.arr: collectAnchors(v, outp)

proc resolveRef(root: JNode, refStr: string): JNode =
  if not refStr.startsWith("#"):
    raise newException(JsonError, "JSON Schema: only local $ref supported")
  if refStr.len > 1 and refStr[1] != '/':            # plain-name $anchor (#name)
    let name = refStr[1 .. ^1]
    if sAnchors.hasKey(name): return sAnchors[name]
    raise newException(JsonError, "JSON Schema: cannot resolve $ref " & refStr)
  result = root
  var frag = refStr[1 .. ^1]
  while frag.len > 0 and frag[0] == '/': frag = frag[1 .. ^1]
  if frag.len > 0:
    for raw in frag.split('/'):
      let tok = raw.replace("~1", "/").replace("~0", "~")
      if result.kind == jkObj and shas(result, tok):
        result = smember(result, tok)
      elif result.kind == jkArr and (block:
             var allDig = tok.len > 0
             for c in tok: (if c notin {'0'..'9'}: allDig = false)
             allDig) and parseInt(tok) < result.arr.len:
        result = result.arr[parseInt(tok)]
      else:
        raise newException(JsonError, "JSON Schema: cannot resolve $ref " & refStr)

# --- format checks (mirror of python/jsoncanon/_format.py) -----------------

var sAssertFormat = false   # set per call by validateJsonSchema (see --format)

proc fDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

proc fDate(s: string): bool =
  if s.len != 10 or s[4] != '-' or s[7] != '-': return false
  if not (fDigits(s[0..3]) and fDigits(s[5..6]) and fDigits(s[8..9])): return false
  let mo = parseInt(s[5..6])
  let da = parseInt(s[8..9])
  mo >= 1 and mo <= 12 and da >= 1 and da <= 31

proc fTime(s: string): bool =
  if s.len < 8 or s[2] != ':' or s[5] != ':': return false
  if not (fDigits(s[0..1]) and fDigits(s[3..4]) and fDigits(s[6..7])): return false
  if parseInt(s[0..1]) > 23 or parseInt(s[3..4]) > 59 or parseInt(s[6..7]) > 59: return false
  var rest = s[8..^1]
  if rest.len > 0 and rest[0] == '.':
    var i = 1
    while i < rest.len and rest[i] in {'0'..'9'}: inc i
    if i == 1: return false
    rest = rest[i..^1]
  if rest.len == 0 or rest == "Z" or rest == "z": return true
  if rest.len == 6 and rest[0] in {'+', '-'} and rest[3] == ':' and
     fDigits(rest[1..2]) and fDigits(rest[4..5]):
    return parseInt(rest[1..2]) <= 23 and parseInt(rest[4..5]) <= 59
  false

proc fDateTime(s: string): bool =
  if s.len < 11 or s[10] notin {'T', 't'}: return false
  fDate(s[0..9]) and fTime(s[11..^1])

proc fIpv4(s: string): bool =
  let parts = s.split('.')
  if parts.len != 4: return false
  for p in parts:
    if not fDigits(p) or p.len > 3 or (p.len > 1 and p[0] == '0') or parseInt(p) > 255:
      return false
  true

proc fHostname(s: string): bool =
  if s.len == 0 or s.len > 253: return false
  for lab in s.split('.'):
    if lab.len == 0 or lab.len > 63 or lab[0] == '-' or lab[^1] == '-': return false
    for c in lab:
      if not ((c in {'A'..'Z', 'a'..'z', '0'..'9'}) or c == '-'): return false
  true

proc fEmail(s: string): bool =
  if s.count('@') != 1: return false
  let parts = s.split('@')
  if parts[0].len == 0 or parts[1].len == 0: return false
  fHostname(parts[1]) and ' ' notin parts[0]

proc fIpv6(s: string): bool =
  if s.count("::") > 1: return false
  let dd = s.find("::")
  let head = if dd >= 0: s[0 ..< dd] else: s
  let tail = if dd >= 0: s[dd+2 .. ^1] else: ""
  var groups: seq[string]
  if head.len > 0: groups.add head.split(':')
  if tail.len > 0: groups.add tail.split(':')
  var tailV4 = false
  if groups.len > 0 and '.' in groups[^1]:
    if not fIpv4(groups[^1]): return false
    tailV4 = true
    groups = groups[0 ..< groups.len - 1]
  for g in groups:
    if g.len == 0 or g.len > 4: return false
    for c in g:
      if c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  let count = groups.len + (if tailV4: 2 else: 0)
  if dd >= 0: count <= (if tailV4: 6 else: 7)
  else: count == (if tailV4: 6 else: 8)

proc fUuid(s: string): bool =
  if s.len != 36: return false
  if not (s[8] == '-' and s[13] == '-' and s[18] == '-' and s[23] == '-'): return false
  for i, c in s:
    if i notin [8, 13, 18, 23] and c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  true

proc fUri(s: string): bool =
  if s.len == 0 or s[0] notin {'A'..'Z', 'a'..'z'}: return false
  var i = 1
  while i < s.len and (s[i] in {'A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.'}): inc i
  i < s.len and s[i] == ':'

proc fJsonPointer(s: string): bool =
  if s.len == 0: return true
  if s[0] != '/': return false
  var i = 0
  while i < s.len:
    if s[i] == '~':
      if i + 1 >= s.len or s[i+1] notin {'0', '1'}: return false
      inc i
    inc i
  true

proc fRegex(s: string): bool =
  try: (discard reSearch(s, ""); true)
  except CatchableError: false

proc formatOk(name, value: string): bool =
  case name
  of "date-time": fDateTime(value)
  of "date": fDate(value)
  of "time": fTime(value)
  of "email", "idn-email": fEmail(value)
  of "hostname", "idn-hostname": fHostname(value)
  of "ipv4": fIpv4(value)
  of "ipv6": fIpv6(value)
  of "uri", "iri", "uri-reference", "iri-reference": fUri(value)
  of "uuid": fUuid(value)
  of "json-pointer": fJsonPointer(value)
  of "regex": fRegex(value)
  else: true

proc schemaValidate(root, schema, inst: JNode, ip: seq[string],
                    errors: var seq[(string, string)], dialect: string)

proc sprobe(root, schema, inst: JNode, dialect: string): bool =
  var tmp: seq[(string, string)]
  schemaValidate(root, schema, inst, @[], tmp, dialect)
  tmp.len > 0

proc evalProps(root, schema, inst: JNode, dialect: string): seq[string] =
  ## Property names of `inst` evaluated by `schema` (for unevaluatedProperties).
  if schema.kind != jkObj: return
  template addk(k: string) = (if k notin result: result.add k)
  let props = smember(schema, "properties")
  if props != nil:
    for k in props.keys:
      if shas(inst, k): addk(k)
  let pat = smember(schema, "patternProperties")
  if pat != nil:
    for p in pat.keys:
      for k in inst.keys:
        if reSearch(p, k): addk(k)
  if shas(schema, "additionalProperties"):
    result = @[]
    for k in inst.keys: result.add k
  if shas(schema, "$ref"):
    for k in evalProps(root, resolveRef(root, smember(schema, "$ref").str), inst, dialect): addk(k)
  let allOf = smember(schema, "allOf")
  if allOf != nil:
    for sub in allOf.arr:
      for k in evalProps(root, sub, inst, dialect): addk(k)
  for kw in ["anyOf", "oneOf"]:
    let a = smember(schema, kw)
    if a != nil:
      for sub in a.arr:
        if not sprobe(root, sub, inst, dialect):
          for k in evalProps(root, sub, inst, dialect): addk(k)
  if shas(schema, "if"):
    if not sprobe(root, smember(schema, "if"), inst, dialect):
      for k in evalProps(root, smember(schema, "if"), inst, dialect): addk(k)
      if shas(schema, "then"):
        for k in evalProps(root, smember(schema, "then"), inst, dialect): addk(k)
    elif shas(schema, "else"):
      for k in evalProps(root, smember(schema, "else"), inst, dialect): addk(k)

proc evalItems(root, schema, inst: JNode, dialect: string): int =
  ## Count of leading items of `inst` evaluated (for unevaluatedItems).
  if schema.kind != jkObj: return 0
  var pre = smember(schema, "prefixItems")
  if pre == nil and dialect == "draft7":
    let it = smember(schema, "items")
    if it != nil and it.kind == jkArr: pre = it
  if pre != nil and pre.kind == jkArr: result = min(pre.arr.len, inst.arr.len)
  let rest = smember(schema, "items")
  if rest != nil and rest.kind != jkArr: result = inst.arr.len
  if dialect == "draft7":
    let it = smember(schema, "items")
    if it != nil and it.kind == jkArr and smember(schema, "additionalItems") != nil:
      result = inst.arr.len
  if shas(schema, "$ref"):
    result = max(result, evalItems(root, resolveRef(root, smember(schema, "$ref").str), inst, dialect))
  let allOf = smember(schema, "allOf")
  if allOf != nil:
    for sub in allOf.arr: result = max(result, evalItems(root, sub, inst, dialect))
  for kw in ["anyOf", "oneOf"]:
    let a = smember(schema, kw)
    if a != nil:
      for sub in a.arr:
        if not sprobe(root, sub, inst, dialect):
          result = max(result, evalItems(root, sub, inst, dialect))
  if shas(schema, "if"):
    if not sprobe(root, smember(schema, "if"), inst, dialect):
      result = max(result, evalItems(root, smember(schema, "if"), inst, dialect))
      if shas(schema, "then"): result = max(result, evalItems(root, smember(schema, "then"), inst, dialect))
    elif shas(schema, "else"):
      result = max(result, evalItems(root, smember(schema, "else"), inst, dialect))

proc validateArray(root, schema, inst: JNode, ip: seq[string],
                   errors: var seq[(string, string)], dialect: string) =
  let here = sptr(ip)
  var prefix = smember(schema, "prefixItems")
  if prefix == nil and dialect == "draft7":
    let it = smember(schema, "items")
    if it != nil and it.kind == jkArr: prefix = it
  var rest = smember(schema, "items")
  if rest != nil and rest.kind == jkArr: rest = smember(schema, "additionalItems")

  var start = 0
  if prefix != nil and prefix.kind == jkArr:
    for i, sub in prefix.arr:
      if i < inst.arr.len:
        schemaValidate(root, sub, inst.arr[i], ip & @[$i], errors, dialect)
    start = prefix.arr.len
  if rest != nil and rest.kind != jkArr:
    for i in start ..< inst.arr.len:
      schemaValidate(root, rest, inst.arr[i], ip & @[$i], errors, dialect)

  if shas(schema, "minItems") and float(inst.arr.len) < snum(smember(schema, "minItems")):
    errors.add((here, "minItems not met"))
  if shas(schema, "maxItems") and float(inst.arr.len) > snum(smember(schema, "maxItems")):
    errors.add((here, "maxItems exceeded"))
  let uniq = smember(schema, "uniqueItems")
  if uniq != nil and uniq.kind == jkBool and uniq.b:
    var seen: seq[string]
    for e in inst.arr:
      let c = serialize(e)
      if c in seen: (errors.add((here, "uniqueItems: duplicate element")); break)
      seen.add c
  if shas(schema, "contains"):
    var matched = 0
    for e in inst.arr:
      if not sprobe(root, smember(schema, "contains"), e, dialect): inc matched
    let lo = if shas(schema, "minContains"): int(snum(smember(schema, "minContains"))) else: 1
    let hasHi = shas(schema, "maxContains")
    let hi = if hasHi: int(snum(smember(schema, "maxContains"))) else: 0
    if matched < lo or (hasHi and matched > hi):
      errors.add((here, "contains: count outside min/maxContains"))
  if shas(schema, "unevaluatedItems"):
    let n = evalItems(root, schema, inst, dialect)
    let ui = smember(schema, "unevaluatedItems")
    for i in n ..< inst.arr.len:
      if ui.kind == jkBool and not ui.b:
        errors.add((sptr(ip & @[$i]), "unevaluatedItems: not allowed"))
      elif not (ui.kind == jkBool and ui.b):
        schemaValidate(root, ui, inst.arr[i], ip & @[$i], errors, dialect)

proc validateObject(root, schema, inst: JNode, ip: seq[string],
                    errors: var seq[(string, string)], dialect: string) =
  let here = sptr(ip)
  let props = smember(schema, "properties")
  let patProps = smember(schema, "patternProperties")
  let addl = smember(schema, "additionalProperties")

  for ix in 0 ..< inst.keys.len:
    let key = inst.keys[ix]
    let val = inst.vals[ix]
    var covered = props != nil and shas(props, key)
    if props != nil and shas(props, key):
      schemaValidate(root, smember(props, key), val, ip & @[key], errors, dialect)
    if patProps != nil:
      for pi in 0 ..< patProps.keys.len:
        if reSearch(patProps.keys[pi], key):
          covered = true
          schemaValidate(root, patProps.vals[pi], val, ip & @[key], errors, dialect)
    if not covered and addl != nil:
      if addl.kind == jkBool and not addl.b:
        errors.add((sptr(ip & @[key]), "additionalProperties: not allowed"))
      elif not (addl.kind == jkBool and addl.b):
        schemaValidate(root, addl, val, ip & @[key], errors, dialect)

  let req = smember(schema, "required")
  if req != nil and req.kind == jkArr:
    for r in req.arr:
      if r.kind == jkStr and not shas(inst, r.str):
        errors.add((here, "required: missing property '" & r.str & "'"))
  if shas(schema, "propertyNames"):
    let pn = smember(schema, "propertyNames")
    for key in inst.keys:
      if sprobe(root, pn, JNode(kind: jkStr, str: key), dialect):
        errors.add((sptr(ip & @[key]), "propertyNames: invalid property name"))
  if shas(schema, "minProperties") and float(inst.keys.len) < snum(smember(schema, "minProperties")):
    errors.add((here, "minProperties not met"))
  if shas(schema, "maxProperties") and float(inst.keys.len) > snum(smember(schema, "maxProperties")):
    errors.add((here, "maxProperties exceeded"))

  let deps = if dialect == "draft7": smember(schema, "dependencies") else: nil
  # Phase A — dependentRequired, then draft-07 array-form dependencies.
  for src in [smember(schema, "dependentRequired"), deps]:
    if src != nil and src.kind == jkObj:
      for di in 0 ..< src.keys.len:
        let k = src.keys[di]
        if shas(inst, k) and src.vals[di].kind == jkArr:
          for rr in src.vals[di].arr:
            if rr.kind == jkStr and not shas(inst, rr.str):
              errors.add((here, "dependentRequired: '" & k & "' needs '" & rr.str & "'"))
  # Phase B — dependentSchemas, then draft-07 schema-form dependencies.
  for src in [smember(schema, "dependentSchemas"), deps]:
    if src != nil and src.kind == jkObj:
      for di in 0 ..< src.keys.len:
        let k = src.keys[di]
        if shas(inst, k) and src.vals[di].kind != jkArr:
          schemaValidate(root, src.vals[di], inst, ip, errors, dialect)

  if shas(schema, "unevaluatedProperties"):
    let ev = evalProps(root, schema, inst, dialect)
    let up = smember(schema, "unevaluatedProperties")
    for ix in 0 ..< inst.keys.len:
      let k = inst.keys[ix]
      if k notin ev:
        if up.kind == jkBool and not up.b:
          errors.add((sptr(ip & @[k]), "unevaluatedProperties: not allowed"))
        elif not (up.kind == jkBool and up.b):
          schemaValidate(root, up, inst.vals[ix], ip & @[k], errors, dialect)

proc schemaValidate(root, schema, inst: JNode, ip: seq[string],
                    errors: var seq[(string, string)], dialect: string) =
  if schema.kind == jkBool:
    if not schema.b: errors.add((sptr(ip), "boolean false schema: nothing is valid"))
    return
  if schema.kind != jkObj: return

  if shas(schema, "$ref"):
    schemaValidate(root, resolveRef(root, smember(schema, "$ref").str), inst, ip, errors, dialect)
    return

  let here = sptr(ip)

  if shas(schema, "type"):
    let t = smember(schema, "type")
    var types: seq[string]
    if t.kind == jkArr:
      for x in t.arr: (if x.kind == jkStr: types.add x.str)
    elif t.kind == jkStr: types.add t.str
    var okt = false
    for ty in types:
      if typeOk(ty, inst): okt = true
    if not okt: errors.add((here, "type: expected " & types.join("/")))
  if shas(schema, "enum"):
    let choices = smember(schema, "enum")
    var found = false
    let ic = serialize(inst)
    for c in choices.arr:
      if serialize(c) == ic: (found = true; break)
    if not found: errors.add((here, "enum: value not in the allowed set"))
  if shas(schema, "const"):
    if serialize(inst) != serialize(smember(schema, "const")):
      errors.add((here, "const: value does not equal the constant"))

  if inst.kind == jkNum:
    let x = snum(inst)
    if shas(schema, "multipleOf"):
      let m = snum(smember(schema, "multipleOf"))
      let q = x / m
      if q - floor(q) != 0: errors.add((here, "multipleOf: not a multiple"))
    if shas(schema, "maximum") and x > snum(smember(schema, "maximum")):
      errors.add((here, "maximum exceeded"))
    if shas(schema, "minimum") and x < snum(smember(schema, "minimum")):
      errors.add((here, "minimum not met"))
    if shas(schema, "exclusiveMaximum") and x >= snum(smember(schema, "exclusiveMaximum")):
      errors.add((here, "exclusiveMaximum reached"))
    if shas(schema, "exclusiveMinimum") and x <= snum(smember(schema, "exclusiveMinimum")):
      errors.add((here, "exclusiveMinimum reached"))

  if inst.kind == jkStr:
    if shas(schema, "minLength") and float(inst.str.runeLen) < snum(smember(schema, "minLength")):
      errors.add((here, "minLength not met"))
    if shas(schema, "maxLength") and float(inst.str.runeLen) > snum(smember(schema, "maxLength")):
      errors.add((here, "maxLength exceeded"))
    if shas(schema, "pattern"):
      if not reSearch(smember(schema, "pattern").str, inst.str):
        errors.add((here, "pattern: does not match"))
    if sAssertFormat and shas(schema, "format"):
      let fmt = smember(schema, "format").str
      if not formatOk(fmt, inst.str):
        errors.add((here, "format: not a valid " & fmt))

  if inst.kind == jkArr: validateArray(root, schema, inst, ip, errors, dialect)
  if inst.kind == jkObj: validateObject(root, schema, inst, ip, errors, dialect)

  if shas(schema, "allOf"):
    for sub in smember(schema, "allOf").arr:
      schemaValidate(root, sub, inst, ip, errors, dialect)
  if shas(schema, "anyOf"):
    var any = false
    for sub in smember(schema, "anyOf").arr:
      if not sprobe(root, sub, inst, dialect): (any = true; break)
    if not any: errors.add((here, "anyOf: no subschema matched"))
  if shas(schema, "oneOf"):
    var n = 0
    for sub in smember(schema, "oneOf").arr:
      if not sprobe(root, sub, inst, dialect): inc n
    if n != 1: errors.add((here, "oneOf: matched " & $n & " subschemas (need exactly 1)"))
  if shas(schema, "not"):
    if not sprobe(root, smember(schema, "not"), inst, dialect):
      errors.add((here, "not: subschema unexpectedly matched"))
  if shas(schema, "if"):
    if not sprobe(root, smember(schema, "if"), inst, dialect):
      if shas(schema, "then"): schemaValidate(root, smember(schema, "then"), inst, ip, errors, dialect)
    else:
      if shas(schema, "else"): schemaValidate(root, smember(schema, "else"), inst, ip, errors, dialect)

proc dialectOf(schema: JNode): string =
  let sid = smember(schema, "$schema")
  if sid != nil and sid.kind == jkStr and "draft-07" in sid.str: "draft7" else: "2020-12"

proc validateJsonSchema*(schemaRaw, instanceRaw: string, encoding = "",
                         assertFormat = false): seq[Issue] =
  let schema = parse(decodeBytes(schemaRaw, encoding))
  let inst = parse(decodeBytes(instanceRaw, encoding))
  var errors: seq[(string, string)]
  sAssertFormat = assertFormat
  sAnchors = initTable[string, JNode]()
  collectAnchors(schema, sAnchors)
  defer: (sAssertFormat = false; sAnchors = initTable[string, JNode]())
  schemaValidate(schema, schema, inst, @[], errors, dialectOf(schema))
  for (p, m) in errors:
    result.add(((if p.len > 0: p else: "(root)"), "schema", m))
