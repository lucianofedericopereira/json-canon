## CLI: jsoncanon [INPUT] [-o OUTPUT] [flags]  — see ../../SPEC.md

import std/[os, strutils]
import jsoncanon

proc usage() =
  stderr.writeLine """jsoncanon — normalize, lint, and re-encode JSON

usage: jsoncanon [INPUT] [options]
  -o, --output FILE          write to FILE (default: stdout)
      --encoding ENC         force input encoding (else BOM autodetect)
      --output-encoding ENC  utf-8|utf-16-le|utf-16-be|utf-32-le|utf-32-be|latin-1
      --bom                  prepend a BOM to the output
      --ndjson               treat input as NDJSON/JSONL
      --strict-dupes         error on duplicate object keys
      --preserve-number-type keep float-vs-int distinction (4.0 stays 4.0)
      --number-format FMT    plain|auto|scientific  (default: plain)
      --nan POLICY           error|null|string  (default: error)
      --newline              append a trailing newline
      --check                exit 0 if input already canonical, else 1
      --lint                 report every deviation; exit 1 if any
  -h, --help"""

proc runLint(name, raw, encoding: string, fmt: NumberFormat): int =
  let issues = lint(raw, encoding, fmt)
  if issues.len == 0:
    echo name & ": already canonical"
    return 0
  echo name
  var width = 0
  for it in issues: width = max(width, it.loc.len)
  for it in issues:
    echo "  " & it.loc.alignLeft(width) & "  " &
         it.category.alignLeft(14) & "  " & it.message
  echo $issues.len & " issue" & (if issues.len != 1: "s" else: "") & ", not canonical"
  return 1

proc main() =
  var
    input, output, encoding = ""
    outputEncoding = "utf-8"
    ndjson, newline, check, doLint, bom = false
    opts = Options(nan: npError, numberFormat: nfPlain)

  # Manual parse so that both "--opt value" and "--opt=value" work (like argparse).
  let params = commandLineParams()
  var i = 0
  proc takeVal(name, inlineVal: string): string =
    if inlineVal.len > 0: return inlineVal
    inc i
    if i >= params.len: (stderr.writeLine "jsoncanon: --" & name & " needs a value"; quit 2)
    params[i]
  while i < params.len:
    let arg = params[i]
    if arg.len >= 2 and arg[0] == '-' and arg != "-":
      var name = arg[1..^1]
      if name.len > 0 and name[0] == '-': name = name[1..^1]  # strip second dash
      var inlineVal = ""
      let eq = name.find('=')
      if eq >= 0: (inlineVal = name[eq+1..^1]; name = name[0..<eq])
      case name
      of "o", "output": output = takeVal(name, inlineVal)
      of "encoding": encoding = takeVal(name, inlineVal)
      of "output-encoding": outputEncoding = takeVal(name, inlineVal)
      of "bom": bom = true
      of "ndjson": ndjson = true
      of "strict-dupes": opts.strictDupes = true
      of "preserve-number-type": opts.preserveNumberType = true
      of "newline": newline = true
      of "check": check = true
      of "lint": doLint = true
      of "number-format":
        case takeVal(name, inlineVal)
        of "plain": opts.numberFormat = nfPlain
        of "auto": opts.numberFormat = nfAuto
        of "scientific": opts.numberFormat = nfScientific
        else: (stderr.writeLine "jsoncanon: bad --number-format value"; quit 2)
      of "nan":
        case takeVal(name, inlineVal)
        of "error": opts.nan = npError
        of "null": opts.nan = npNull
        of "string": opts.nan = npString
        else: (stderr.writeLine "jsoncanon: bad --nan value"; quit 2)
      of "h", "help": (usage(); quit 0)
      else: (stderr.writeLine "jsoncanon: unknown option " & arg; quit 2)
    else:
      input = arg
    inc i

  let raw = if input.len > 0: readFile(input) else: stdin.readAll()

  if doLint:
    let name = if input.len > 0: input else: "<stdin>"
    try: quit runLint(name, raw, encoding, opts.numberFormat)
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  var outStr: string
  try:
    outStr = canonicalize(raw, opts, encoding, ndjson, newline, outputEncoding, bom)
  except CatchableError:
    stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg()
    quit 2

  if check:
    quit(if outStr == raw: 0 else: 1)
  if output.len > 0: writeFile(output, outStr)
  else: stdout.write outStr

main()
