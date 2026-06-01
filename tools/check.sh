#!/usr/bin/env bash
# Full static-analysis + test gate for both implementations.
#   - Python: mypy --strict, pyright, pytest
#   - Nim:    nim check (warnings as analysis), unittest
#   - Cross:  tools/parity.sh (Nim == Python == golden)
set -u
cd "$(dirname "$0")/.."
fail=0
run() { echo "» $1"; shift; "$@" || { echo "  FAILED"; fail=1; }; echo; }

PY=python3
[ -x .venv/bin/python ] && PY=$PWD/.venv/bin/python  # use venv if present (has pandas)

echo "===== Python static analysis ====="
( cd python && run "mypy --strict" mypy )
( cd python && command -v pyright >/dev/null && run "pyright" pyright || echo "(pyright not installed, skipped)"; echo )

echo "===== Nim static analysis ====="
run "nim check jsoncanon.nim"     nim check --warnings:on --hints:off nim/src/jsoncanon.nim
run "nim check jsoncanon_cli.nim" nim check --warnings:on --hints:off nim/src/jsoncanon_cli.nim

echo "===== Tests ====="
( cd python && run "pytest" "$PY" -m pytest tests/ -q )
run "nim unittest" nim c -r --hints:off --warnings:off nim/tests/test_canon.nim

echo "===== Cross-language parity ====="
run "parity.sh" bash tools/parity.sh

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
