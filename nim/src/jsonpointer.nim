## JSON Pointer (RFC 6901) — parse + resolve. Mirror of python/jsoncanon/
## jsonpointer.py. Shared by --pointer and JSON Patch.

import std/strutils
import ./jsoncanon

proc ptrUnescape*(tok: string): string =
  tok.replace("~1", "/").replace("~0", "~")

proc parsePointer*(pt: string): seq[string] =
  if pt.len == 0: return @[]
  if pt[0] != '/':
    raise newException(JsonError, "invalid JSON Pointer '" & pt & "' (must be empty or start with '/')")
  for t in pt[1 .. ^1].split('/'): result.add ptrUnescape(t)

proc arrayIndex*(tok: string, length: int, allowDash = false): int =
  if allowDash and tok == "-": return length
  if tok != "0" and (tok.len == 0 or tok[0] == '0' or (block:
       var ok = true
       for c in tok: (if c notin {'0'..'9'}: ok = false)
       not ok)):
    raise newException(JsonError, "JSON Pointer: invalid array index '" & tok & "'")
  parseInt(tok)

proc resolveTokens*(doc: JNode, toks: seq[string]): JNode =
  result = doc
  for tok in toks:
    case result.kind
    of jkObj:
      let i = result.keys.find(tok)
      if i < 0: raise newException(JsonError, "JSON Pointer: no member '" & tok & "'")
      result = result.vals[i]
    of jkArr:
      let idx = arrayIndex(tok, result.arr.len)
      if idx >= result.arr.len: raise newException(JsonError, "JSON Pointer: index " & tok & " out of range")
      result = result.arr[idx]
    else:
      raise newException(JsonError, "JSON Pointer: cannot descend into a scalar at '" & tok & "'")

proc getPointer*(doc: JNode, pt: string): JNode =
  resolveTokens(doc, parsePointer(pt))
