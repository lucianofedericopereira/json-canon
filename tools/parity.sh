#!/usr/bin/env bash
# Assert the Nim and Python implementations produce byte-identical output,
# matching the committed golden *.canon files. See SPEC.md §3.
set -u
cd "$(dirname "$0")/.."
NIM=./nim/jsoncanon_cli
PY="python3 -m jsoncanon.cli"
pass=0; fail=0

check() { # label golden nim_output py_output
  local label="$1" golden="$2" nim_out="$3" py_out="$4"
  if [ "$nim_out" = "$py_out" ] && [ "$nim_out" = "$(cat "$golden")" ]; then
    printf '  \xe2\x9c\x93 %s\n' "$label"; pass=$((pass+1))
  else
    printf '  \xe2\x9c\x97 %s\n' "$label"
    printf '    nim:    %s\n' "$nim_out"
    printf '    py:     %s\n' "$py_out"
    printf '    golden: %s\n' "$(cat "$golden")"
    fail=$((fail+1))
  fi
}

echo "Parity (Nim == Python == golden):"
for f in fixtures/0[1-6]*.json; do
  base=$(basename "${f%.*}")
  nim_out=$($NIM "$f")
  py_out=$(cd python && $PY "../$f")
  check "$base" "fixtures/$base.canon" "$nim_out" "$py_out"
done

nim_out=$($NIM --ndjson fixtures/07.ndjson)
py_out=$(cd python && $PY --ndjson ../fixtures/07.ndjson)
check "07.ndjson" "fixtures/07.canon" "$nim_out" "$py_out"

# JSON Text Sequences (RFC 7464, RS-framed) + concatenated streams.
nim_out=$($NIM --json-seq fixtures/11-json-seq.jsonseq)
py_out=$(cd python && $PY --json-seq ../fixtures/11-json-seq.jsonseq)
check "11-json-seq" "fixtures/11-json-seq.canon" "$nim_out" "$py_out"

nim_out=$($NIM fixtures/08-json5.json5)
py_out=$(cd python && $PY ../fixtures/08-json5.json5)
check "08-json5" "fixtures/08-json5.canon" "$nim_out" "$py_out"

# JSON5 Unicode / escaped identifier keys (SPEC §1.2).
nim_out=$($NIM fixtures/10-json5-ident.json5)
py_out=$(cd python && $PY ../fixtures/10-json5-ident.json5)
check "10-json5-ident" "fixtures/10-json5-ident.canon" "$nim_out" "$py_out"

# RFC 8785 (JCS) mode: Ryu numbers + UTF-16 key sort. (The fixture intentionally
# includes a lossy value; its §5 warning goes to stderr, dropped here with 2>.)
nim_out=$($NIM --jcs fixtures/09-jcs.json 2>/dev/null)
py_out=$(cd python && $PY --jcs ../fixtures/09-jcs.json 2>/dev/null)
check "09-jcs" "fixtures/09-jcs.canon" "$nim_out" "$py_out"

# --- cross-impl checks for flags (Nim must equal Python) -------------------
xcheck() { # label nim_output py_output
  if [ "$2" = "$3" ]; then printf '  \xe2\x9c\x93 %s\n' "$1"; pass=$((pass+1))
  else printf '  \xe2\x9c\x97 %s\n    nim: %s\n    py:  %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
py() { (cd python && $PY "$@"); }
NUMS='[4, 1e3, 1e21, 1e-7, 6.022e23, 0.1, 1e-6, 123456789012345678901234567890]'

echo "number-format (Nim == Python):"
for fmt in plain auto scientific; do
  xcheck "$fmt" "$(printf '%s' "$NUMS" | $NIM --number-format $fmt)" \
                "$(printf '%s' "$NUMS" | py --number-format $fmt)"
done

echo "jcs numbers (Nim == Python):"
JCSNUMS='[333333333.33333329, 1e30, 4.50, 2e-3, 1e-27, 9007199254740993, 5e-324, 1.7976931348623157e308]'
xcheck "jcs numbers" "$(printf '%s' "$JCSNUMS" | $NIM --jcs 2>/dev/null)" \
                     "$(printf '%s' "$JCSNUMS" | py --jcs 2>/dev/null)"

echo "jcs --quiet requires --log (Nim == Python, both exit 2):"
nq=$(printf '[1]' | $NIM --jcs --quiet 2>&1 >/dev/null; echo "exit=$?")
pq=$(printf '[1]' | py  --jcs --quiet 2>&1 >/dev/null; echo "exit=$?")
xcheck "quiet-needs-log" "$nq" "$pq"

echo "jcs precision-warning log (Nim == Python):"
LOSSY='[9007199254740993, 1e400, 333333333.33333329, 0.1, {"k":2.000000000000002}]'
printf '%s' "$LOSSY" | $NIM --jcs --nan null --quiet --log /tmp/jc_nim.log >/dev/null
printf '%s' "$LOSSY" | py  --jcs --nan null --quiet --log /tmp/jc_py.log  >/dev/null
xcheck "jcs warnings" "$(cat /tmp/jc_nim.log)" "$(cat /tmp/jc_py.log)"

echo "output-encoding (Nim == Python, byte hashes):"
for enc in utf-8 utf-16-le utf-16-be utf-32-le utf-32-be latin-1; do
  for b in "" "--bom"; do
    lbl="$enc ${b:-plain}"
    xcheck "$lbl" \
      "$(printf '{"v":1,"x":"é"}' | $NIM --output-encoding $enc $b | shasum)" \
      "$(printf '{"v":1,"x":"é"}' | py  --output-encoding $enc $b | shasum)"
  done
done

echo "lint (Nim == Python):"
LI="{'b': 1, 'a': 2, /* c */ 'n': 4.0, 'd': 1, 'd': 2,}"
xcheck "lint output" "$(printf '%s' "$LI" | $NIM --lint)" "$(printf '%s' "$LI" | py --lint)"

echo "json-seq concatenated stream (Nim == Python):"
xcheck "json-seq concat" "$(printf '{"a":1}{"b":2} 3' | $NIM --json-seq)" \
                         "$(printf '{"a":1}{"b":2} 3' | py --json-seq)"

echo "cbor — RFC 8949 (Nim == Python == golden):"
xcheck "to cbor"   "$($NIM --to cbor fixtures/12-cbor.json | shasum)" \
                   "$(py --to cbor ../fixtures/12-cbor.json | shasum)"
if [ "$($NIM --to cbor fixtures/12-cbor.json | shasum)" = "$(shasum < fixtures/12-cbor.cbor)" ]
then printf '  \xe2\x9c\x93 to cbor == golden\n'; pass=$((pass+1))
else printf '  \xe2\x9c\x97 to cbor == golden\n'; fail=$((fail+1)); fi
xcheck "from cbor" "$($NIM --from cbor fixtures/12-cbor.cbor)" \
                   "$(py --from cbor ../fixtures/12-cbor.cbor)"
check "from cbor == golden" "fixtures/12-cbor.canon" \
      "$($NIM --from cbor fixtures/12-cbor.cbor)" "$(py --from cbor ../fixtures/12-cbor.cbor)"

echo "msgpack — deterministic (Nim == Python == golden):"
xcheck "to msgpack"   "$($NIM --to msgpack fixtures/18-msgpack.json | shasum)" \
                      "$(py --to msgpack ../fixtures/18-msgpack.json | shasum)"
if [ "$($NIM --to msgpack fixtures/18-msgpack.json | shasum)" = "$(shasum < fixtures/18-msgpack.msgpack)" ]
then printf '  \xe2\x9c\x93 to msgpack == golden\n'; pass=$((pass+1))
else printf '  \xe2\x9c\x97 to msgpack == golden\n'; fail=$((fail+1)); fi
check "from msgpack == golden" "fixtures/18-msgpack.canon" \
      "$($NIM --from msgpack fixtures/18-msgpack.msgpack)" "$(py --from msgpack ../fixtures/18-msgpack.msgpack)"

echo "jdata — NeuroJSON N-D arrays (Nim == Python == golden):"
nim_out=$($NIM --from jdata fixtures/15-jdata.json)
py_out=$(py --from jdata ../fixtures/15-jdata.json)
check "15-jdata" "fixtures/15-jdata.canon" "$nim_out" "$py_out"

echo "geojson — RFC 7946 (Nim == Python):"
xcheck "geojson valid"  "$(cat fixtures/13-geojson.json | $NIM --geojson)" \
                        "$(cat fixtures/13-geojson.json | py --geojson)"
GJBAD='{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[0,0]]],"crs":1}'
xcheck "geojson broken" "$(printf '%s' "$GJBAD" | $NIM --geojson)" \
                        "$(printf '%s' "$GJBAD" | py --geojson)"

echo "jtd — RFC 8927 (Nim == Python):"
xcheck "jtd valid"  "$(cat fixtures/14-jtd.instance.json | $NIM --validate fixtures/14-jtd.schema.jtd)" \
                    "$(cat fixtures/14-jtd.instance.json | py --validate ../fixtures/14-jtd.schema.jtd)"
xcheck "jtd errors" "$(printf '{"id":-5,"tags":[1],"x":9}' | $NIM --validate fixtures/14-jtd.schema.jtd)" \
                    "$(printf '{"id":-5,"tags":[1],"x":9}' | py --validate ../fixtures/14-jtd.schema.jtd)"

echo "pointer / patch / merge-patch (Nim == Python):"
PDOC='{"a":{"b":[1,2,3]},"x":5}'
xcheck "pointer"     "$(printf '%s' "$PDOC" | $NIM --pointer /a/b/2)" \
                     "$(printf '%s' "$PDOC" | py --pointer /a/b/2)"
echo '[{"op":"add","path":"/a/b/-","value":9},{"op":"test","path":"/x","value":5},{"op":"remove","path":"/x"}]' > /tmp/jc_pa.json
xcheck "patch"       "$(printf '%s' "$PDOC" | $NIM --patch /tmp/jc_pa.json)" \
                     "$(printf '%s' "$PDOC" | py --patch /tmp/jc_pa.json)"
echo '{"x":null,"a":{"c":2},"n":{"d":1}}' > /tmp/jc_mp.json
xcheck "merge-patch" "$(printf '%s' "$PDOC" | $NIM --merge-patch /tmp/jc_mp.json)" \
                     "$(printf '%s' "$PDOC" | py --merge-patch /tmp/jc_mp.json)"

echo "force salvage (Nim == Python, stdout+stderr):"
FBAD='{"a":1, "b": , bad, "c":[1,2,{"x":}], "d":4} trailing'
xcheck "force salvage" "$(printf '%s' "$FBAD" | $NIM --force 2>&1)" \
                       "$(printf '%s' "$FBAD" | py --force 2>&1)"

echo "json schema — 2020-12 / draft-07 (Nim == Python):"
xcheck "schema valid"  "$(cat fixtures/17-schema.instance.json | $NIM --schema fixtures/17-schema.schema.json)" \
                       "$(cat fixtures/17-schema.instance.json | py --schema ../fixtures/17-schema.schema.json)"
# exercises pattern (shared regex), additionalProperties, minimum, uniqueItems
SBAD='{"id":0,"email":"BAD","tags":["x","x"],"extra":1}'
xcheck "schema errors" "$(printf '%s' "$SBAD" | $NIM --schema fixtures/17-schema.schema.json)" \
                       "$(printf '%s' "$SBAD" | py --schema ../fixtures/17-schema.schema.json)"
echo '{"properties":{"dob":{"format":"date"},"ip":{"format":"ipv4"},"id":{"format":"uuid"}}}' > /tmp/fmt.json
FMT='{"dob":"2020-13-99","ip":"1.2.3.4","id":"nope"}'
xcheck "schema --format" "$(printf '%s' "$FMT" | $NIM --schema /tmp/fmt.json --format)" \
                         "$(printf '%s' "$FMT" | py --schema /tmp/fmt.json --format)"

echo 'json schema $anchor / unevaluated (Nim == Python):'
echo '{"allOf":[{"properties":{"a":{}}}],"unevaluatedProperties":false}' > /tmp/uneval.json
UDOC='{"a":1,"b":2,"c":3}'
xcheck "unevaluatedProperties" "$(printf '%s' "$UDOC" | $NIM --schema /tmp/uneval.json)" \
                               "$(printf '%s' "$UDOC" | py --schema /tmp/uneval.json)"
echo '{"$defs":{"P":{"$anchor":"pos","minimum":0}},"properties":{"n":{"$ref":"#pos"}}}' > /tmp/anchor.json
xcheck "anchor ref"            "$(printf '{"n":-1}' | $NIM --schema /tmp/anchor.json)" \
                               "$(printf '{"n":-1}' | py --schema /tmp/anchor.json)"

echo "cddl — RFC 8610 (Nim == Python):"
xcheck "cddl valid"  "$(cat fixtures/16-cddl.instance.json | $NIM --cddl fixtures/16-cddl.schema.cddl)" \
                     "$(cat fixtures/16-cddl.instance.json | py --cddl ../fixtures/16-cddl.schema.cddl)"
xcheck "cddl errors" "$(printf '{"name":"X","age":-1,"status":"bad","extra":1}' | $NIM --cddl fixtures/16-cddl.schema.cddl)" \
                     "$(printf '{"name":"X","age":-1,"status":"bad","extra":1}' | py --cddl ../fixtures/16-cddl.schema.cddl)"

echo "sha256 of canonical bytes (Nim == Python):"
xcheck "sha256" "$(printf '{"b":1,"a":[4.0,1e3]}' | $NIM --sha256)" \
                "$(printf '{"b":1,"a":[4.0,1e3]}' | py --sha256)"

echo "diff after canonicalization (Nim == Python):"
printf '{"a":1,"b":2,"x":7}' > /tmp/jc_A.json
printf '{"b":3,"a":1,"c":{"q":[1,2]}}' > /tmp/jc_B.json
nd=$($NIM /tmp/jc_A.json --diff /tmp/jc_B.json; echo "exit=$?")
pd=$(py /tmp/jc_A.json --diff /tmp/jc_B.json; echo "exit=$?")  # /tmp paths are absolute
xcheck "diff output" "$nd" "$pd"

echo "ijson — RFC 7493 (Nim == Python):"
IJ='{"big":9007199254740993,"safe":2,"safe":3,"huge":1e400,"ok":[1.5,0.1]}'
xcheck "ijson report" "$(printf '%s' "$IJ" | $NIM --ijson)" "$(printf '%s' "$IJ" | py --ijson)"
xcheck "ijson clean"  "$(printf '{"a":1,"b":[2,3.5]}' | $NIM --ijson)" \
                      "$(printf '{"a":1,"b":[2,3.5]}' | py --ijson)"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
