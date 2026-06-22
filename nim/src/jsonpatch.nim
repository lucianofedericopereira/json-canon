## JSON Patch (RFC 6902) and JSON Merge Patch (RFC 7386). Mirror of
## python/jsoncanon/jsonpatch.py. Produces a transformed value tree that the
## caller then canonicalizes (so intermediate key order is irrelevant).

import ./jsoncanon
import ./jsonpointer

proc deepCopy*(n: JNode): JNode =
  case n.kind
  of jkNull: result = JNode(kind: jkNull)
  of jkBool: result = JNode(kind: jkBool, b: n.b)
  of jkNum: result = JNode(kind: jkNum, num: n.num)
  of jkStr: result = JNode(kind: jkStr, str: n.str)
  of jkNonFinite: result = JNode(kind: jkNonFinite, nf: n.nf)
  of jkArr:
    result = JNode(kind: jkArr)
    for x in n.arr: result.arr.add deepCopy(x)
  of jkObj:
    result = JNode(kind: jkObj)
    for i in 0 ..< n.keys.len:
      result.keys.add n.keys[i]
      result.vals.add deepCopy(n.vals[i])

proc member(o: JNode, key: string): JNode =
  let i = o.keys.find(key)
  if i >= 0: o.vals[i] else: nil

proc opStr(op: JNode, key: string): string =
  let v = member(op, key)
  if v == nil or v.kind != jkStr:
    raise newException(JsonError, "patch: '" & key & "' must be a string")
  v.str

proc parentOf(doc: JNode, path: string): (JNode, string) =
  let toks = parsePointer(path)
  if toks.len == 0: raise newException(JsonError, "patch: empty path has no parent")
  (resolveTokens(doc, toks[0 ..< toks.len - 1]), toks[^1])

proc addOp(doc: JNode, path: string, value: JNode): JNode =
  let toks = parsePointer(path)
  if toks.len == 0: return value
  let (parent, last) = parentOf(doc, path)
  case parent.kind
  of jkArr:
    let i = arrayIndex(last, parent.arr.len, allowDash = true)
    if i > parent.arr.len: raise newException(JsonError, "patch add: index out of range")
    parent.arr.insert(value, i)
  of jkObj:
    let ix = parent.keys.find(last)
    if ix >= 0: parent.vals[ix] = value
    else: (parent.keys.add last; parent.vals.add value)
  else: raise newException(JsonError, "patch add: parent is not an array or object")
  doc

proc replaceOp(doc: JNode, path: string, value: JNode): JNode =
  let toks = parsePointer(path)
  if toks.len == 0: return value
  let (parent, last) = parentOf(doc, path)
  case parent.kind
  of jkArr:
    let i = arrayIndex(last, parent.arr.len)
    if i >= parent.arr.len: raise newException(JsonError, "patch replace: index out of range")
    parent.arr[i] = value
  of jkObj:
    let ix = parent.keys.find(last)
    if ix < 0: raise newException(JsonError, "patch replace: no member '" & last & "'")
    parent.vals[ix] = value
  else: raise newException(JsonError, "patch replace: parent is not an array or object")
  doc

proc removeOp(doc: JNode, path: string): (JNode, JNode) =
  let (parent, last) = parentOf(doc, path)
  case parent.kind
  of jkArr:
    let i = arrayIndex(last, parent.arr.len)
    if i >= parent.arr.len: raise newException(JsonError, "patch remove: index out of range")
    let v = parent.arr[i]
    parent.arr.delete(i)
    (v, doc)
  of jkObj:
    let ix = parent.keys.find(last)
    if ix < 0: raise newException(JsonError, "patch remove: no member '" & last & "'")
    let v = parent.vals[ix]
    parent.keys.delete(ix); parent.vals.delete(ix)
    (v, doc)
  else: raise newException(JsonError, "patch remove: parent is not an array or object")

proc applyOp(doc: JNode, op: JNode): JNode =
  if op.kind != jkObj or member(op, "op") == nil or member(op, "path") == nil:
    raise newException(JsonError, "patch: each operation needs 'op' and 'path'")
  let o = opStr(op, "op")
  let path = opStr(op, "path")
  case o
  of "add": addOp(doc, path, deepCopy(member(op, "value")))
  of "replace": replaceOp(doc, path, deepCopy(member(op, "value")))
  of "remove": removeOp(doc, path)[1]
  of "move":
    let frm = opStr(op, "from")
    let (val, d) = removeOp(doc, frm)
    addOp(d, path, val)
  of "copy":
    let frm = opStr(op, "from")
    addOp(doc, path, deepCopy(resolveTokens(doc, parsePointer(frm))))
  of "test":
    let got = resolveTokens(doc, parsePointer(path))
    if serialize(got) != serialize(member(op, "value")):
      raise newException(JsonError, "patch test failed at " & path)
    doc
  else: raise newException(JsonError, "patch: unknown op '" & o & "'")

proc applyPatch*(doc, patch: JNode): JNode =
  if patch.kind != jkArr:
    raise newException(JsonError, "JSON Patch must be an array of operations")
  result = deepCopy(doc)
  for op in patch.arr: result = applyOp(result, op)

proc applyMergePatch*(target, patch: JNode): JNode =
  if patch.kind == jkObj:
    result = if target.kind == jkObj: target else: JNode(kind: jkObj)
    for i in 0 ..< patch.keys.len:
      let k = patch.keys[i]
      let v = patch.vals[i]
      let existing = result.keys.find(k)
      if v.kind == jkNull:
        if existing >= 0: (result.keys.delete(existing); result.vals.delete(existing))
      else:
        let cur = if existing >= 0: result.vals[existing] else: JNode(kind: jkNull)
        let merged = applyMergePatch(cur, v)
        if existing >= 0: result.vals[existing] = merged
        else: (result.keys.add k; result.vals.add merged)
  else:
    result = deepCopy(patch)