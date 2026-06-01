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

nim_out=$($NIM fixtures/08-json5.json5)
py_out=$(cd python && $PY ../fixtures/08-json5.json5)
check "08-json5" "fixtures/08-json5.canon" "$nim_out" "$py_out"

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

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
