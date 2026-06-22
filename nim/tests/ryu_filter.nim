## Reads one 16-hex-digit float64 bit pattern per line, writes the
## ecmaScriptNumberToString of that double. Used by the fuzz harness to diff
## against node's Number.prototype.toString.
import std/strutils
import ../src/ryu

for line in stdin.lines:
  let s = line.strip()
  if s.len == 0: continue
  let bits = fromHex[uint64](s)
  stdout.writeLine ecmaScriptNumberToString(cast[float64](bits))
