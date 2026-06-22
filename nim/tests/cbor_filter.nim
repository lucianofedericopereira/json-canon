## Test helper for CBOR validation against Python. Modes:
##   half          -> for h in 0..65535, print 16-hex float64-bits of halfToDouble(h)
##   enc           -> read JSON per line, print hex of deterministic CBOR
##   dec           -> read hex CBOR per line, print canonical JSON of the decode
import std/[strutils, os]
import ../src/jsoncanon
import ../src/cbor

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "enc"
  case mode
  of "half":
    for h in 0 .. 65535:
      let d = halfToDouble(uint16(h))
      stdout.writeLine toHex(cast[uint64](d), 16)
  of "enc":
    for line in stdin.lines:
      if line.strip().len == 0: continue
      let bytes = encodeCbor(parse(line))
      var hex = ""
      for c in bytes: hex.add toHex(ord(c), 2).toLowerAscii
      stdout.writeLine hex
  of "dec":
    for line in stdin.lines:
      let s = line.strip()
      if s.len == 0: continue
      var raw = ""
      var i = 0
      while i < s.len: raw.add chr(parseHexInt(s[i..i+1])); i += 2
      stdout.writeLine serialize(decodeCbor(raw), Options(nan: npString))
  else: quit("unknown mode", 1)
