<img src="assets/logo.png" width="400px">

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
CHANGELOG.md         notable changes (Keep a Changelog format)
paper/               companion arXiv-style paper (main.tex)
python/              Python package (jsoncanon) + pyproject + tests
  jsoncanon/         parser, serializer, numbers, lint, cli, pandas_accessor
nim/                 Nim package (src/jsoncanon.nim, jsoncanon_cli.nim) + tests
fixtures/            input files + committed *.canon golden outputs
tools/               check.sh (gate), parity.sh (cross-language), reproduce.sh (paper claims)
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

# --ijson: is this interoperable JSON (RFC 7493)?  flags big ints, dup keys, etc.
$ echo '{"id":9007199254740993,"a":1,"a":2}' | jsoncanon --ijson
<stdin>
  1:30   duplicate-key   duplicate key 'a' (last value wins)
  $.id   number          9007199254740993 is an integer outside the I-JSON safe range ±(2^53-1)
2 issues, not I-JSON

# --sha256: a content hash that's stable across formatting/key-order/number noise
$ echo '{"b":1,"a":2}' | jsoncanon --sha256
9b2e...c4

# --diff: compare two docs by *meaning*, not bytes (4.0 == 4, reordered keys equal)
$ jsoncanon a.json --diff b.json
~ $.price: 4 => 5
+ $.tags[2]: "new"
- $.legacy

# Re-encode: canonicalize AND convert charset (doubles as an encoding converter)
$ jsoncanon data.json --output-encoding utf-16-le --bom -o data.u16

# Scientific notation
$ echo '[1e308, 0.1, 42]' | jsoncanon --number-format auto    # [1e+308,0.1,42]
$ echo '[1e308, 0.1, 42]' | jsoncanon --number-format scientific

# RFC 8785 (JCS): numbers via the ECMAScript Number.toString algorithm
$ echo '[1e21, 4.50, 0.000001, 1e-7]' | jsoncanon --jcs    # [1e+21,4.5,0.000001,1e-7]
```

## RFC 8785 / JCS mode

**The project's goal is the *lossless* default** (numbers normalized as decimal
strings, never round-tripped through a float — see [SPEC.md §2.3](SPEC.md)). That
is what makes the canonical form exact and the two implementations agree without
trusting any float printer.

`--jcs` is the opt-in [JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785)
mode for when you specifically need RFC 8785 interop: numbers are serialized
exactly as JavaScript's `String(x)` would (shortest round-tripping double, via a
pure-Nim / pure-Python port of Ulf Adams' [**Ryu**](https://github.com/ulfjack/ryu)
`d2s`), and object keys are sorted by UTF-16 code unit. This **gives up the
lossless guarantee**: JCS goes *through* the IEEE-754 double, so
`9007199254740993` rounds to `9007199254740992` and `4.0`/`4` both become `4`.

Because that loss is otherwise invisible, `--jcs` **warns** (on stderr) about
every value it changes, so you never lose parity silently:

```bash
$ echo '[9007199254740993, 1e400, 0.1]' | jsoncanon --jcs --nan null
jsoncanon: --jcs changed 2 value(s) in <stdin>; canonical output no longer round-trips to the exact input:
  [0]: 9007199254740993 → 9007199254740992 (IEEE-754 rounding; not reversible)
  [1]: 1e400 exceeds binary64 range (no JCS parity)
[9007199254740992,null,0.1]

$ jsoncanon data.json --jcs --log convert.log   # save the report; -q silences stderr
```

`--log` is opt-in (the tool never writes a log on its own), and `--quiet`
requires it — you can move the warnings to a file, but you can't silence them
into nothing, so a precision change is never lost without a trace.

## CBOR (RFC 8949) — cross-format canonicalization

`--from cbor` / `--to cbor` turn the tool into a *binary* canonicalizer using
[RFC 8949 Core Deterministic Encoding](https://www.rfc-editor.org/rfc/rfc8949#section-4.2):
integers use the shortest head (bignum tags 2/3 beyond 64-bit), non-integers use
the shortest float (16/32/64) that round-trips, and map keys are sorted by the
bytewise order of their *encoded* keys (§4.2.1). The Nim half-precision codec is
verified against Python over all 65 536 bit patterns; encode is byte-identical
Nim ⇄ Python.

```bash
jsoncanon data.json --to cbor > data.cbor     # JSON  -> deterministic CBOR
jsoncanon --from cbor data.cbor               # CBOR  -> canonical JSON
jsoncanon --from cbor data.cbor --to cbor     # re-canonicalize CBOR (idempotent)
```

Because the JSON number model is decimal-exact, integers survive CBOR losslessly
(even 30-digit ones, via bignums); non-integers go through binary floats, as CBOR
requires. On decode, byte strings become base64 text and bignums become exact
integers. See [SPEC.md §6](SPEC.md). The Nim `d2s` is
validated byte-for-byte against node's `String(x)` over millions of random
doubles (`tools/fuzz_ryu.py`, kept in-repo as proof); see [SPEC.md §5](SPEC.md).

## Flags (both CLIs, identical behavior)

```
-o, --output FILE          write to FILE (default stdout)
    --encoding ENC         force input encoding (else BOM autodetect)
    --output-encoding ENC  utf-8|utf-16-le|utf-16-be|utf-32-le|utf-32-be|latin-1
    --bom                  prepend a BOM to the output
    --from FMT             input format: json (default) | cbor (RFC 8949) | msgpack | jdata (NeuroJSON)
    --to FMT               output format: json (default) | cbor (RFC 8949) | msgpack  (deterministic)
    --ndjson               treat input as NDJSON / JSONL
    --json-seq             parse a value stream: RFC 7464 (RS-framed), ws-sep, or concatenated
    --strict-dupes         error on duplicate object keys (default: last wins)
    --preserve-number-type keep float-vs-int distinction (4.0 stays 4.0)
    --jcs                  RFC 8785 mode: Ryu (ECMAScript) numbers + UTF-16 key sort
    --log FILE             write a --jcs precision-change report to FILE
-q, --quiet                suppress --jcs warnings on stderr (requires --log)
    --number-format FMT    plain (default) | auto | scientific
    --nan error|null|string  how to emit NaN/Infinity (default: error)
    --newline              append a trailing newline
    --force                salvage malformed input (drop bad members/elements), warn on stderr
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
    --format               with --schema: also assert the format vocabulary
    --sha256               output the SHA-256 hex digest of the canonical bytes
    --diff FILE            structural diff of INPUT vs FILE; exit 1 if they differ
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
