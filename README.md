<img src="assets/logo.png width=400px">

# jsoncanon — canonical JSON

Take JSON produced by *anything* — CPython `json`, pandas `to_json`, Nim
`std/json`, JS, hand-edited files with comments and trailing commas — and emit
**one deterministic byte-stream**. Then `cmp`, `sha256`, and `git diff` on the
output actually mean something, no matter who produced the input.

Two **independent** implementations (Python and Nim) that are byte-identical by
construction. The contract they both obey is [`SPEC.md`](SPEC.md).

Luciano Federico Pereira

## Repository layout

```
SPEC.md              the canonical-form contract both implementations obey
python/              Python package (jsoncanon) + pyproject + tests
  jsoncanon/         parser, serializer, numbers, lint, cli, pandas_accessor
nim/                 Nim package (src/jsoncanon.nim, jsoncanon_cli.nim) + tests
fixtures/            input files + committed *.canon golden outputs
tools/               check.sh (full gate) and parity.sh (cross-language)
```

Build artifacts (the compiled `nim/jsoncanon_cli`, `__pycache__`, `.venv/`,
tool caches) are git-ignored; see [`.gitignore`](.gitignore).

## The pain it kills

| Producer quirk                              | Canonical result        |
|---------------------------------------------|-------------------------|
| pandas emits `4.0`, CPython emits `4`       | both → `4`              |
| `ensure_ascii` → `é` vs raw `é`        | raw `é` (UTF-8)         |
| key order differs run to run                | sorted by code point    |
| pretty-printed vs compact whitespace        | compact, no spaces      |
| UTF-8/16/32 BOM, single quotes, `// comments`, trailing commas | parsed & normalized away |
| JSON5: `unquoted: 1`, `0xFF`, `\x41`, line-continuations | `{"unquoted":1}`, `255`, `A`, joined |
| `1e3`, `0.10`, `4.50e1`, `-0.0`             | `1000`, `0.1`, `45`, `0`|
| 30-digit integers                           | preserved exactly       |

Numbers are normalized **as decimal strings** — never round-tripped through a
binary float — so big ints survive and the two languages agree byte-for-byte
(no dependence on each language's float printer). See [SPEC.md §2.3](SPEC.md).

## Python

Requires Python ≥ 3.10. Install into a virtualenv (recommended — many systems
ship an externally-managed Python):

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e "python[pandas]"           # drop [pandas] if you don't need the accessor

jsoncanon input.json -o out.json          # CLI
jsoncanon --ndjson logs.jsonl
cat a.json | jsoncanon --check && echo "already canonical"
```

```python
import jsoncanon
jsoncanon.canonicalize(open("f.json","rb").read())   # -> canonical bytes
jsoncanon.canon_number("4.0")                         # -> "4"
```

### pandas accessor

`import jsoncanon.pandas_accessor` registers a `.jsoncanon` accessor on
DataFrame/Series (the official [pandas extension API](https://pandas.pydata.org/docs/development/extending.html)).
Because it serializes through a fixed internal orient and runs the output
through the canonicalizer, two frames holding the same data hash equal
**regardless of column order or int-vs-float dtype**:

```python
import pandas as pd, jsoncanon.pandas_accessor

df1 = pd.DataFrame({"price": [4, 10],   "qty": [2, 3]})        # int64
df2 = pd.DataFrame({"qty":   [2., 3.],  "price": [4., 10.]})   # float64, cols swapped

df1.jsoncanon.sha256() == df2.jsoncanon.sha256()   # True
df1.jsoncanon.to_canonical()                       # deterministic bytes
df1.jsoncanon.to_canonical_str(number_format="auto", nan="null")  # flags pass through
```

(`jsoncanon.from_pandas(df)` remains as a one-shot helper that routes any
`to_json`-able object through `canonicalize`.)

## Nim

```bash
cd nim && nimble build          # produces ./jsoncanon_cli
./jsoncanon_cli input.json -o out.json
```

```nim
import jsoncanon
let bytes = canonicalize(readFile("f.json"))
echo canonNumber("4.50e1")      # -> "45"
```

## Lint & re-encode

```bash
# Lint: report every deviation from canonical form (exit 1 if any)
$ printf "{'b':1,'a':4.0,/* c */}" | jsoncanon --lint
<stdin>
  1:2   single-quote    single-quoted string is not valid JSON
  1:8   single-quote    single-quoted string is not valid JSON
  1:16  comment         comment is not valid JSON
  1:23  trailing-comma  trailing comma in object
  $     key-order       object keys are not sorted
  $.a   number          4.0 → 4
6 issues, not canonical

# --check is the quiet version (exit code only)
$ jsoncanon --check config.json && echo ok

# Re-encode: canonicalize AND convert charset (doubles as an encoding converter)
$ jsoncanon data.json --output-encoding utf-16-le --bom -o data.u16

# Scientific notation
$ echo '[1e308, 0.1, 42]' | jsoncanon --number-format auto    # [1e+308,0.1,42]
$ echo '[1e308, 0.1, 42]' | jsoncanon --number-format scientific
```

## Flags (both CLIs, identical behavior)

```
-o, --output FILE          write to FILE (default stdout)
    --encoding ENC         force input encoding (else BOM autodetect)
    --output-encoding ENC  utf-8|utf-16-le|utf-16-be|utf-32-le|utf-32-be|latin-1
    --bom                  prepend a BOM to the output
    --ndjson               treat input as NDJSON / JSONL
    --strict-dupes         error on duplicate object keys (default: last wins)
    --preserve-number-type keep float-vs-int distinction (4.0 stays 4.0)
    --number-format FMT    plain (default) | auto | scientific
    --nan error|null|string  how to emit NaN/Infinity (default: error)
    --newline              append a trailing newline
    --check                exit 0 if input already canonical, else 1
    --lint                 report every deviation; exit 1 if any
```

## Conformance & static analysis

```bash
pip install -e "python[dev]"   # pytest, mypy, pyright, pandas (once, in your venv)

bash tools/check.sh            # everything: mypy --strict, pyright, nim check, tests, parity
bash tools/parity.sh           # just cross-language byte-parity (Nim == Python == golden)
cd python && python3 -m pytest
```

The Python package is clean under `mypy --strict` and `pyright`; the Nim
sources are warning-clean under `nim check`. `tools/check.sh` runs all of it as
one gate (it auto-uses `.venv/` if present so the pandas tests run).
