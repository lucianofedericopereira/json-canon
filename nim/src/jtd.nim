## JSON Type Definition (RFC 8927) validator — mirror of python/jsoncanon/jtd.py.
## Produces standard error indicators (instancePath / schemaPath) as JSON
## Pointers, in a fixed depth-first order, so it is byte-identical to Python.

import std/strutils
import ./jsoncanon

proc jtdGet(o: JNode, key: string): JNode =
  if o.kind != jkObj: return nil
  let i = o.keys.find(key)
  if i >= 0: o.vals[i] else: nil

proc jtdHas(o: JNode, key: string): bool =
  o.kind == jkObj and o.keys.find(key) >= 0

proc isRfc3339(s: string): bool =
  ## ^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$
  var i = 0
  proc dig(s: string, i: var int, n: int): bool =
    for _ in 0 ..< n:
      if i >= s.len or s[i] notin {'0'..'9'}: return false
      inc i
    true
  proc lit(s: string, i: var int, c: char): bool =
    if i < s.len and s[i] == c: (inc i; true) else: false
  proc litset(s: string, i: var int, cs: set[char]): bool =
    if i < s.len and s[i] in cs: (inc i; true) else: false
  if not dig(s, i, 4) or not lit(s, i, '-') or not dig(s, i, 2) or
     not lit(s, i, '-') or not dig(s, i, 2) or not litset(s, i, {'T', 't'}) or
     not dig(s, i, 2) or not lit(s, i, ':') or not dig(s, i, 2) or
     not lit(s, i, ':') or not dig(s, i, 2): return false
  if i < s.len and s[i] == '.':
    inc i
    var c = 0
    while i < s.len and s[i] in {'0'..'9'}: (inc i; inc c)
    if c == 0: return false
  if litset(s, i, {'Z', 'z'}): discard
  elif i < s.len and s[i] in {'+', '-'}:
    inc i
    if not dig(s, i, 2) or not lit(s, i, ':') or not dig(s, i, 2): return false
  else: return false
  i == s.len

proc isIntIn(numtok: string, lo, hi: int64): bool =
  let plain = canonNumber(numtok, false, nfPlain)
  if '.' in plain: return false
  let digits = if plain[0] == '-': plain[1..^1] else: plain
  if digits.len > 10: return false      # beyond any JTD int range
  let iv = parseBiggestInt(plain)
  iv >= lo and iv <= hi

proc checkType(t: string, inst: JNode): bool =
  case t
  of "boolean": inst.kind == jkBool
  of "string": inst.kind == jkStr
  of "timestamp": inst.kind == jkStr and isRfc3339(inst.str)
  of "float32", "float64": inst.kind == jkNum
  of "int8": inst.kind == jkNum and isIntIn(inst.num, -128, 127)
  of "uint8": inst.kind == jkNum and isIntIn(inst.num, 0, 255)
  of "int16": inst.kind == jkNum and isIntIn(inst.num, -32768, 32767)
  of "uint16": inst.kind == jkNum and isIntIn(inst.num, 0, 65535)
  of "int32": inst.kind == jkNum and isIntIn(inst.num, -2147483648'i64, 2147483647'i64)
  of "uint32": inst.kind == jkNum and isIntIn(inst.num, 0, 4294967295'i64)
  else: false

proc jtdPtr(tokens: seq[string]): string =
  for t in tokens:
    result.add "/"
    result.add t.replace("~", "~0").replace("/", "~1")

proc jtdValidate(root, schema, inst: JNode,
                 errors: var seq[(seq[string], seq[string])],
                 ip, sp: seq[string], parentTag = "", useTag = false) =
  if schema.kind != jkObj: return
  let nul = jtdGet(schema, "nullable")
  if nul != nil and nul.kind == jkBool and nul.b and inst.kind == jkNull: return

  if jtdHas(schema, "ref"):
    let name = jtdGet(schema, "ref").str
    let defs = jtdGet(root, "definitions")
    if defs == nil or not jtdHas(defs, name):
      raise newException(JsonError, "JTD: unknown definition '" & name & "'")
    jtdValidate(root, jtdGet(defs, name), inst, errors, ip, @["definitions", name])
  elif jtdHas(schema, "type"):
    if not checkType(jtdGet(schema, "type").str, inst): errors.add((ip, sp & @["type"]))
  elif jtdHas(schema, "enum"):
    var found = false
    if inst.kind == jkStr:
      for c in jtdGet(schema, "enum").arr:
        if c.kind == jkStr and c.str == inst.str: (found = true; break)
    if not found: errors.add((ip, sp & @["enum"]))
  elif jtdHas(schema, "elements"):
    if inst.kind == jkArr:
      for i, e in inst.arr:
        jtdValidate(root, jtdGet(schema, "elements"), e, errors, ip & @[$i], sp & @["elements"])
    else: errors.add((ip, sp & @["elements"]))
  elif jtdHas(schema, "properties") or jtdHas(schema, "optionalProperties"):
    if inst.kind == jkObj:
      let props = jtdGet(schema, "properties")
      let opts = jtdGet(schema, "optionalProperties")
      if props != nil:
        for k in props.keys:
          if jtdHas(inst, k):
            jtdValidate(root, jtdGet(props, k), jtdGet(inst, k), errors, ip & @[k], sp & @["properties", k])
          else:
            errors.add((ip, sp & @["properties", k]))
      if opts != nil:
        for k in opts.keys:
          if jtdHas(inst, k):
            jtdValidate(root, jtdGet(opts, k), jtdGet(inst, k), errors, ip & @[k], sp & @["optionalProperties", k])
      let addl = jtdGet(schema, "additionalProperties")
      let allowAddl = addl != nil and addl.kind == jkBool and addl.b
      if not allowAddl:
        for k in inst.keys:
          let inProps = props != nil and jtdHas(props, k)
          let inOpts = opts != nil and jtdHas(opts, k)
          if not inProps and not inOpts and not (useTag and k == parentTag):
            errors.add((ip & @[k], sp))
    else:
      errors.add((ip, sp & (if jtdHas(schema, "properties"): @["properties"] else: @["optionalProperties"])))
  elif jtdHas(schema, "values"):
    if inst.kind == jkObj:
      for k in inst.keys:
        jtdValidate(root, jtdGet(schema, "values"), jtdGet(inst, k), errors, ip & @[k], sp & @["values"])
    else: errors.add((ip, sp & @["values"]))
  elif jtdHas(schema, "discriminator"):
    let tag = jtdGet(schema, "discriminator").str
    if inst.kind == jkObj:
      if jtdHas(inst, tag):
        let tv = jtdGet(inst, tag)
        let mapping = jtdGet(schema, "mapping")
        if tv.kind == jkStr and mapping != nil and jtdHas(mapping, tv.str):
          jtdValidate(root, jtdGet(mapping, tv.str), inst, errors, ip, sp & @["mapping", tv.str], tag, true)
        else:
          errors.add((ip & @[tag], sp & @["mapping"]))
      else:
        errors.add((ip, sp & @["discriminator"]))
    else:
      errors.add((ip, sp & @["discriminator"]))
  # empty form (and metadata-only): always valid

proc validateJtd*(schemaRaw, instanceRaw: string, encoding = ""): seq[Issue] =
  let schema = parse(decodeBytes(schemaRaw, encoding))
  let inst = parse(decodeBytes(instanceRaw, encoding))
  var errors: seq[(seq[string], seq[string])]
  jtdValidate(schema, schema, inst, errors, @[], @[])
  for (ip, sp) in errors:
    let il = jtdPtr(ip)
    let sl = jtdPtr(sp)
    result.add(((if il.len > 0: il else: "(root)"), "jtd",
                "schema " & (if sl.len > 0: sl else: "(root)")))
