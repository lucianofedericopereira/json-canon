## CLI: jsoncanon [INPUT] [-o OUTPUT] [flags]  — see ../../SPEC.md

import std/[os, strutils]
import jsoncanon
import sha256
import cbor
import msgpack
import jtd
import cddl
import jsonschema
import jsonpointer
import jsonpatch

proc usage() =
  stderr.writeLine """jsoncanon — normalize, lint, and re-encode JSON

usage: jsoncanon [INPUT] [options]
  -o, --output FILE          write to FILE (default: stdout)
      --encoding ENC         force input encoding (else BOM autodetect)
      --output-encoding ENC  utf-8|utf-16-le|utf-16-be|utf-32-le|utf-32-be|latin-1
      --bom                  prepend a BOM to the output
      --from FMT             input format: json | cbor | msgpack | jdata
      --to FMT               output format: json | cbor | msgpack  (deterministic)
      --ndjson               treat input as NDJSON/JSONL
      --json-seq             parse a value stream: RFC 7464 / ws-sep / concatenated
      --strict-dupes         error on duplicate object keys
      --preserve-number-type keep float-vs-int distinction (4.0 stays 4.0)
      --jcs                  RFC 8785 mode (Ryu numbers, UTF-16 key sort)
      --log FILE             write a --jcs precision-change report to FILE
  -q, --quiet                suppress --jcs warnings on stderr (requires --log)
      --number-format FMT    plain|auto|scientific  (default: plain)
      --nan POLICY           error|null|string  (default: error)
      --newline              append a trailing newline
      --force                salvage malformed input (drop bad members/elements), warn
      --pointer EXPR         extract the sub-value at a JSON Pointer (RFC 6901)
      --patch FILE           apply a JSON Patch (RFC 6902) before canonicalizing
      --merge-patch FILE     apply a JSON Merge Patch (RFC 7386) before canonicalizing
      --check                exit 0 if input already canonical, else 1
      --lint                 report every deviation; exit 1 if any
      --ijson                report I-JSON (RFC 7493) violations; exit 1 if any
      --geojson              report GeoJSON (RFC 7946) violations; exit 1 if any
      --validate FILE        validate INPUT against a JSON Type Definition (RFC 8927) schema
      --cddl FILE            validate INPUT against a CDDL (RFC 8610) schema
      --schema FILE          validate INPUT against a JSON Schema (2020-12 / draft-07)
      --format               with --schema: also assert the `format` vocabulary
      --sha256               output the SHA-256 hex digest of the canonical bytes
      --diff FILE            structural diff of INPUT vs FILE; exit 1 if they differ
  -h, --help"""

proc reportIssues(name: string, issues: seq[Issue], cleanMsg, dirtyTail: string): int =
  if issues.len == 0:
    echo name & ": " & cleanMsg
    return 0
  echo name
  var width = 0
  for it in issues: width = max(width, it.loc.len)
  for it in issues:
    echo "  " & it.loc.alignLeft(width) & "  " &
         it.category.alignLeft(14) & "  " & it.message
  echo $issues.len & " issue" & (if issues.len != 1: "s" else: "") & ", " & dirtyTail
  return 1

proc runLint(name, raw, encoding: string, fmt: NumberFormat): int =
  reportIssues(name, lint(raw, encoding, fmt), "already canonical", "not canonical")

proc runIjson(name, raw, encoding: string): int =
  reportIssues(name, ijson(raw, encoding), "conforms to I-JSON", "not I-JSON")

proc runGeojson(name, raw, encoding: string): int =
  reportIssues(name, geojson(raw, encoding), "conforms to GeoJSON", "not GeoJSON")

proc main() =
  var
    input, output, encoding, logFile, diffFile, jtdFile, cddlFile, schemaFile, pointerExpr = ""
    patchFile, mergePatchFile = ""
    outputEncoding = "utf-8"
    inFmt, outFmt = "json"
    ndjson, jsonSeq, newline, check, doLint, doIjson, doGeojson, bom, quiet, doSha256, force, assertFormat = false
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
      of "from":
        inFmt = takeVal(name, inlineVal)
        if inFmt notin ["json", "cbor", "msgpack", "jdata"]: (stderr.writeLine "jsoncanon: bad --from value"; quit 2)
      of "to":
        outFmt = takeVal(name, inlineVal)
        if outFmt notin ["json", "cbor", "msgpack"]: (stderr.writeLine "jsoncanon: bad --to value"; quit 2)
      of "bom": bom = true
      of "ndjson": ndjson = true
      of "json-seq": jsonSeq = true
      of "strict-dupes": opts.strictDupes = true
      of "preserve-number-type": opts.preserveNumberType = true
      of "jcs": opts.jcs = true
      of "log": logFile = takeVal(name, inlineVal)
      of "q", "quiet": quiet = true
      of "newline": newline = true
      of "force": force = true
      of "pointer": pointerExpr = takeVal(name, inlineVal)
      of "patch": patchFile = takeVal(name, inlineVal)
      of "merge-patch": mergePatchFile = takeVal(name, inlineVal)
      of "check": check = true
      of "lint": doLint = true
      of "ijson": doIjson = true
      of "geojson": doGeojson = true
      of "sha256": doSha256 = true
      of "diff": diffFile = takeVal(name, inlineVal)
      of "validate": jtdFile = takeVal(name, inlineVal)
      of "cddl": cddlFile = takeVal(name, inlineVal)
      of "schema": schemaFile = takeVal(name, inlineVal)
      of "format": assertFormat = true
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

  # Safety: --quiet must not be a way to discard the §5 precision record. If you
  # silence the warnings, you have to capture them somewhere.
  if quiet and logFile.len == 0:
    stderr.writeLine "jsoncanon: --quiet requires --log (the --jcs precision " &
      "changes must be recorded somewhere)"
    quit 2

  let raw = if input.len > 0: readFile(input) else: stdin.readAll()

  if doLint or doIjson or doGeojson:
    let name = if input.len > 0: input else: "<stdin>"
    try:
      if doGeojson: quit runGeojson(name, raw, encoding)
      elif doIjson: quit runIjson(name, raw, encoding)
      else: quit runLint(name, raw, encoding, opts.numberFormat)
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  if diffFile.len > 0:
    try:
      let lines = diff(raw, readFile(diffFile), opts, encoding)
      for ln in lines: echo ln
      quit(if lines.len == 0: 0 else: 1)
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  if jtdFile.len > 0:
    let name = if input.len > 0: input else: "<stdin>"
    try:
      quit reportIssues(name, validateJtd(readFile(jtdFile), raw, encoding),
                        "valid against JTD schema", "invalid against JTD schema")
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  if cddlFile.len > 0:
    let name = if input.len > 0: input else: "<stdin>"
    try:
      quit reportIssues(name, validateCddl(readFile(cddlFile), raw, encoding),
                        "valid against CDDL schema", "invalid against CDDL schema")
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  if schemaFile.len > 0:
    let name = if input.len > 0: input else: "<stdin>"
    try:
      quit reportIssues(name, validateJsonSchema(readFile(schemaFile), raw, encoding, assertFormat),
                        "valid against JSON Schema", "invalid against JSON Schema")
    except CatchableError:
      stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2

  # --pointer / --patch / --merge-patch compose as a transform over the value.
  var patchNode, mergeNode: JNode = nil
  try:
    if patchFile.len > 0: patchNode = parse(readFile(patchFile))
    if mergePatchFile.len > 0: mergeNode = parse(readFile(mergePatchFile))
  except CatchableError:
    stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg(); quit 2
  proc xf(n: JNode): JNode =
    if pointerExpr.len > 0: getPointer(n, pointerExpr)
    elif patchNode != nil: applyPatch(n, patchNode)
    elif mergeNode != nil: applyMergePatch(n, mergeNode)
    else: n
  let hasXf = pointerExpr.len > 0 or patchNode != nil or mergeNode != nil

  var outStr: string
  var warns: seq[string]
  var fwarns: seq[string]
  try:
    if inFmt in ["cbor", "msgpack", "jdata"]:
      let node = xf(case inFmt
                 of "cbor": decodeCbor(raw)
                 of "msgpack": decodeMsgpack(raw)
                 else: decodeJdata(parse(decodeBytes(raw, encoding), opts)))
      if outFmt == "cbor":
        outStr = encodeCbor(node, opts)
      elif outFmt == "msgpack":
        outStr = encodeMsgpack(node, opts)
      else:
        if opts.jcs: collectJcsWarnings(node, "", warns)
        var t = serialize(node, opts)
        if newline: t.add "\n"
        outStr = encodeOutput(t, outputEncoding, bom)
    elif outFmt == "cbor":
      outStr = encodeCbor(xf(parse(decodeBytes(raw, encoding), opts)), opts)
    elif outFmt == "msgpack":
      outStr = encodeMsgpack(xf(parse(decodeBytes(raw, encoding), opts)), opts)
    else:
      outStr = canonicalize(raw, opts, encoding, ndjson, newline, outputEncoding, bom,
                            (if opts.jcs: addr warns else: nil), jsonSeq,
                            force, (if force: addr fwarns else: nil),
                            (if hasXf: xf else: nil))
  except CatchableError:
    stderr.writeLine "jsoncanon: " & getCurrentExceptionMsg()
    quit 2

  if check:
    quit(if outStr == raw: 0 else: 1)

  # --force recovery report (stderr).
  if force and fwarns.len > 0 and not quiet:
    let src = if input.len > 0: input else: "<stdin>"
    stderr.writeLine "jsoncanon: --force salvaged " & src & " with " &
      $fwarns.len & " recovery action(s):"
    for w in fwarns: stderr.writeLine "  " & w

  # §5 precision report: --jcs can round numbers through binary64.
  if opts.jcs and (warns.len > 0 or logFile.len > 0):
    let src = if input.len > 0: input else: "<stdin>"
    let header =
      if warns.len == 0: "jsoncanon: --jcs conversion of " & src & " is exact; no values changed."
      else: "jsoncanon: --jcs changed " & $warns.len & " value(s) in " & src &
             "; canonical output no longer round-trips to the exact input:"
    if not quiet and warns.len > 0:
      stderr.writeLine header
      for w in warns: stderr.writeLine "  " & w
    if logFile.len > 0:
      let f = open(logFile, fmWrite)
      f.writeLine header
      for w in warns: f.writeLine "  " & w
      f.close()

  if doSha256: outStr = sha256Hex(outStr) & "\n"

  if output.len > 0: writeFile(output, outStr)
  else: stdout.write outStr

main()
