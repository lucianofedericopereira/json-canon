## Reads tab-separated `pattern\ttext` lines, prints "1"/"0" for reSearch.
import std/strutils
import ../src/regexlite

for line in stdin.lines:
  if line.len == 0: continue
  let parts = line.split('\t')
  if parts.len != 2: (stdout.writeLine "ERR"; continue)
  stdout.writeLine (if reSearch(parts[0], parts[1]): "1" else: "0")
