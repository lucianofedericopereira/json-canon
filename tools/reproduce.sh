#!/usr/bin/env bash
# Reproduce every claim in the companion paper (paper/main.tex) from scratch.
#
#   bash tools/reproduce.sh          # full scale (matches the paper's Table 2)
#   bash tools/reproduce.sh quick    # reduced scale for a fast smoke run
#
# Runs the full static-analysis + parity gate, then each differential fuzzer
# with its fixed seed against external oracles (node, CPython re, Python struct).
# Exits non-zero if anything fails. node is optional: the Ryu-vs-node row is
# skipped (with a notice) if node is unavailable.
set -u
cd "$(dirname "$0")/.."
fail=0
step() { echo; echo "============================================================"; echo "» $1"; echo "============================================================"; }
run()  { "$@" || { echo "  *** FAILED ***"; fail=1; }; }

if [ "${1:-}" = "quick" ]; then
  RYU=200000; REGEX=5000; FORCE=800; JCS=50000
else
  RYU=2000000; REGEX=40000; FORCE=4000; JCS=200000
fi

step "Build Nim CLI and test helpers"
run nim c --hints:off --warnings:off -o:nim/jsoncanon_cli nim/src/jsoncanon_cli.nim
run nim c --hints:off --warnings:off -d:release nim/tests/ryu_filter.nim
run nim c --hints:off --warnings:off -d:release nim/tests/regex_filter.nim
run nim c --hints:off --warnings:off -d:release nim/tests/cbor_filter.nim

step "Full gate (mypy --strict, pyright, nim check, both test suites, parity)"
run bash tools/check.sh

step "Ryu shortest float vs node String(x)  [paper Table 2, row 1]"
if command -v node >/dev/null 2>&1; then
  run python3 tools/fuzz_ryu.py "$RYU"
else
  echo "  (node not found -- skipping; install Node.js to reproduce this row)"
fi

step "JCS number tokens, Nim == Python  [row 2]"
run python3 tools/parity_jcs.py "$JCS"

step "Regex subset vs CPython re and Nim == Python  [row 3]"
run python3 tools/fuzz_regex.py "$REGEX"

step "CBOR float16 codec vs Python struct, exhaustive 65536  [row 4]"
run bash -c './nim/tests/cbor_filter half | python3 -c "
import sys,struct
bad=0
for h in range(65536):
    nim=sys.stdin.readline().strip().lower()
    want=struct.pack(\">d\", struct.unpack(\">e\", struct.pack(\">H\", h))[0]).hex()
    if nim!=want: bad+=1
print(\"cbor float16: all 65536 patterns\", \"OK\" if bad==0 else str(bad)+\" MISMATCH\")
sys.exit(1 if bad else 0)"'

step "--force salvage, Nim == Python (stdout+stderr+rc)  [row 5]"
run python3 tools/fuzz_force.py "$FORCE"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PAPER CLAIMS REPRODUCED"
else
  echo "SOME REPRODUCTION STEPS FAILED"
fi
exit "$fail"
