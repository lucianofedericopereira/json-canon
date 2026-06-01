# Canonical JSON (CJSON) — normalization spec

Version: 0.1

Goal: take JSON produced by *anything* — CPython `json`, pandas `to_json`,
Nim `std/json`, JS, hand-written files — and emit **one deterministic
byte-stream**, so that `cmp` / `sha256` / `git diff` on the canonical output
is meaningful regardless of the producer.

Two independent implementations (Python, Nim) MUST produce byte-identical
output for the same input. This document is the contract. Where the two
disagree, this file wins and the bug is in the implementation.

---

## 1. Input (lenient parse)

The parser accepts a superset of RFC 8259 so it can ingest the messy real
world. All of the following are accepted on **input** and normalized away on
**output**:

### 1.1 Byte encoding / BOM
Auto-detected from the leading bytes, decoded to Unicode text:

| BOM bytes              | Encoding   |
|------------------------|------------|
| `EF BB BF`             | UTF-8      |
| `FF FE 00 00`          | UTF-32-LE  |
| `00 00 FE FF`          | UTF-32-BE  |
| `FF FE`                | UTF-16-LE  |
| `FE FF`                | UTF-16-BE  |
| (none)                 | UTF-8      |

No BOM + non-UTF-8 can be forced with `--encoding`. The BOM itself is never
echoed to the output.

### 1.2 Dialect leniency
The parser accepts standard JSON (RFC 8259), JSONC, and JSON5, plus a few
Python-emitter quirks:

- Python literals: `True` → true, `False` → false, `None` → null.
- Non-finite floats: `NaN`, `Infinity`, `-Infinity`, `inf`, `-inf` (see §2.5).
- Single-quoted strings: `'abc'` (Python `repr` / JS / JSON5 style).
- Trailing commas in arrays and objects: `[1,2,]`, `{"a":1,}`.
- Comments (JSONC): `// line` and `/* block */`.
- Leading `+` and leading zeros in numbers: `+4`, `007`, `.5`, `5.`.
- NDJSON / JSONL: one value per line, enabled with `--ndjson`.

JSON5 additions:
- Unquoted object keys that are ASCII identifiers: `[A-Za-z_$][A-Za-z0-9_$]*`
  (e.g. `{name: 1, $id: 2}`). Unicode identifier keys and `\u`-escaped keys are
  not accepted in v0.1.
- Hexadecimal integers: `0xFF`, `-0x10`, `+0x2A`. Converted to their exact
  decimal value (arbitrary precision — big hex stays exact), then canonicalized
  per §2.3.
- Extra string escapes: `\xHH` (two-digit hex → that code point), `\v`
  (U+000B), `\0` (U+0000).
- Line continuations: a backslash immediately before a line terminator
  (LF, CR, CRLF, U+2028, U+2029) is removed, joining the two lines.
- Vertical tab / form feed as insignificant whitespace.

Every non-standard feature is normalized to strict RFC 8259 on output and, in
`--lint` mode, reported (categories `unquoted-key`, `hex-number`, `hex-escape`,
`line-continuation`, etc.; see §3).

---

## 2. Output (canonical form)

- Encoding: **UTF-8, no BOM**.
- No insignificant whitespace. Separators are exactly `,` and `:`.
- No trailing newline (add one with `--newline`). NDJSON output joins values
  with a single `\n` and no trailing newline.

### 2.1 Objects
Members sorted by object key, ascending, comparing **Unicode code point by
code point** (the sequence of scalar values). This is deterministic and
identical across implementations. (Note: this differs from RFC 8785 JCS,
which sorts by UTF-16 code units; that only matters for astral-plane keys
and may be offered later as `--jcs-sort`.)

Duplicate keys: **last value wins** by default; `--strict-dupes` makes it an
error.

### 2.2 Strings
Emit raw UTF-8 for every character except those that MUST be escaped. Escapes,
all lowercase:

- `"` → `\"`
- `\` → `\\`
- U+0008 → `\b`, U+0009 → `\t`, U+000A → `\n`, U+000C → `\f`, U+000D → `\r`
- any other control char U+0000–U+001F → `\u00xx` (lowercase hex)

Everything else — including non-ASCII (`é`, `中`, emoji) and U+007F — is
emitted as raw UTF-8. `/` is **never** escaped. This erases all
`ensure_ascii` / `\uXXXX` differences between producers.

### 2.3 Numbers — the important one

Numbers are normalized **as decimal strings**, using only string and integer
digit operations. They are **never** parsed into an IEEE-754 binary float.
This makes the result (a) lossless for big integers and high-precision
decimals and (b) trivially identical across languages (no dependence on each
language's float printer).

Given a number token, decompose into: sign, integer digits `I`, fraction
digits `F`, exponent `E` (default 0):

1. `combined = I + F`  (digit strings concatenated)
2. `pointExp = E - len(F)`   → value is `combined × 10^pointExp`
3. Strip **leading** zeros from `combined`.
4. If `combined` is now empty → the value is zero → output `"0"`.
   (So `0`, `0.0`, `-0`, `-0.0`, `0e9` all canonicalize to `0`.)
5. Strip **trailing** zeros from `combined`, adding one to `pointExp` per
   removed zero. Now `combined` is the minimal significand.
6. Sign is `-` only if the original was negative **and** value ≠ 0.
7. Format as **plain decimal** (no scientific notation):
   - `pointExp >= 0` (integral): `sign + combined + "0"*pointExp`
   - `pointExp < 0`, let `k = -pointExp`:
     - `k < len(combined)`: `sign + combined[:-k] + "." + combined[-k:]`
     - `k >= len(combined)`: `sign + "0." + "0"*(k-len(combined)) + combined`

Examples:

| Input              | Canonical              |
|--------------------|------------------------|
| `4`                | `4`                    |
| `4.0`              | `4`                    |
| `4.50e1`           | `45`                   |
| `-0.0`             | `0`                    |
| `1e3`              | `1000`                 |
| `0.10`             | `0.1`                  |
| `+007`             | `7`                    |
| `1.5E-3`           | `0.0015`               |
| `123456789012345678901234567890` | (preserved exactly) |

`--preserve-number-type`: if set, a token that was written as a float
(had `.` or exponent) but canonicalizes to an integer gets a `.0` suffix
(`4.0` → `4.0`, `4` → `4`). This *keeps* the int/float distinction instead of
unifying it — the opposite of the default. Off by default, because unifying
`4.0` and `4` is the whole point.

#### Number format (`--number-format`)
Controls plain vs scientific output. The decomposition above is unchanged; only
the final formatting step differs. Let `sciExp = pointExp + (len(combined) - 1)`
(the exponent if the point sat after the first significant digit).

- `plain` (default): always plain decimal, no exponent (`1e21` → a 22-digit
  integer; big integers stay integers).
- `scientific`: always `d[.ddd]e±X` — one digit before the point, no trailing
  zeros, explicit exponent sign, no leading zeros in the exponent
  (`4` → `4e+0`, `0.1` → `1e-1`, `6.022e23` → `6.022e+23`).
- `auto`: scientific when `sciExp >= 21` or `sciExp < -6` (ECMAScript
  `Number.toString` thresholds), plain otherwise. Avoids 300-digit blowups for
  values like `1e308` while keeping ordinary numbers readable.

### 2.6 Output encoding
The canonical text (§2.1–2.5) is always computed as UTF-8. `--output-encoding`
then re-encodes the final byte stream to one of: `utf-8` (default),
`utf-16-le`, `utf-16-be`, `utf-32-le`, `utf-32-be`, `latin-1`. `--bom` prepends
the matching BOM (`latin-1` has none). This makes the tool a deterministic
encoding converter as well as a normalizer; decoding the result back (BOM
autodetected, §1.1) reproduces the canonical UTF-8 form exactly.

### 2.4 Literals
`true`, `false`, `null` — lowercase, always.

### 2.5 Non-finite numbers
`NaN` / `Infinity` have no JSON representation. On output, controlled by
`--nan`:
- `error` (default): refuse, with a message naming the offending path.
- `null`: emit `null`.
- `string`: emit `"NaN"`, `"Infinity"`, `"-Infinity"`.

---

## 3. Lint mode (`--lint`)
Instead of emitting canonical output, report every deviation from canonical
form, one per line, as `LOCATION  CATEGORY  MESSAGE`, then a summary; exit
non-zero if any issue is found. Categories:

- lexical (location = `line:col`): `bom`, `comment`, `single-quote`,
  `trailing-comma`, `python-literal`, `non-finite`, `number-syntax`,
  `duplicate-key`, `unquoted-key`, `hex-number`, `hex-escape`,
  `line-continuation`.
- structural (location = JSONPath-ish, e.g. `$.items[3]`): `key-order`
  (object keys not sorted), `number` (token not in canonical form, shown as
  `before → after`).

This is the verbose counterpart to `--check`, which prints nothing and only
sets the exit code (`0` already canonical, `1` not).

## 4. Conformance
`tools/parity.sh` runs both implementations over `fixtures/*` and the flag
matrix (number formats, all output encodings ± BOM, lint), asserting the
outputs are byte-identical to each other and to the committed `*.canon`
golden files.
