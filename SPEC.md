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
- Value streams (`--json-seq`): a sequence of top-level values with no single
  fixed framing — RFC 7464 JSON Text Sequences (each value prefixed by RS
  U+001E, terminated by LF), whitespace-separated values, and directly
  concatenated values (`{"a":1}{"b":2}`) are all accepted by one lenient reader.
  Like `--ndjson`, the canonical values are emitted one per line (joined by a
  single `\n`).

JSON5 additions:
- Unquoted object keys following the ECMAScript `IdentifierName` grammar:
  ASCII identifiers (`{name: 1, $id: 2}`), Unicode identifiers (`{café: 1, π: 2,
  中文: 3}` — start chars in Unicode categories Lu/Ll/Lt/Lm/Lo/Nl plus `_`/`$`,
  continue chars additionally Mn/Mc/Nd/Pc and ZWNJ/ZWJ), and `\uXXXX`-escaped
  identifiers (a backslash-u escape in a key position decodes to its code point,
  e.g. an escaped `a` followed by `bc` yields the key `abc`; surrogate pairs are
  joined). The
  identifier code-point tables are generated once (`tools/gen_id_tables.py`) and
  embedded identically in both implementations, so classification can't drift
  between each language's own Unicode database.
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
which sorts by UTF-16 code units; that only matters for astral-plane keys.
The `--jcs` mode (§5) switches to UTF-16 ordering.)

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

### 3.1 I-JSON conformance (`--ijson`)
Reports violations of **I-JSON** (RFC 7493), the interoperable JSON subset, then
exits non-zero if any. Because I-JSON is a strict subset of RFC 8259, every
non-JSON lexical feature the parser already detects (comments, single quotes,
trailing commas, `NaN`/`Infinity`, hex, unquoted/Python literals, BOM, duplicate
keys) is reported as an I-JSON violation, using the same `line:col CATEGORY`
form as `--lint`. On top of those, two semantic rules are checked on the parsed
tree (location = JSONPath-ish, category `number` / `surrogate`):

- **Numbers** (RFC 7493 §2.2): an integer outside the safe range ±(2⁵³−1), or
  any number not exactly representable as an IEEE-754 binary64 (loses precision,
  or overflows the range). Ordinary values like `2`, `3.5`, `0.1` are fine.
- **Strings / keys** (§2.1): must not contain an unpaired surrogate.

Note `--ijson` is about *interoperability*, not canonical form: `4.0` is valid
I-JSON (it is not flagged), whereas `--lint` would note `4.0 → 4`.

### 3.3 GeoJSON conformance (`--geojson`)
Reports violations of **GeoJSON** (RFC 7946); exit non-zero if any. Categories
(location = JSONPath-ish): `geojson-type` (missing/invalid `type`),
`geojson-member` (missing `coordinates`/`geometry`/`features`/`geometries`/
`properties`), `geojson-coordinates` (a position needs ≥2 numbers; LineString
≥2 positions), `geojson-ring` (a Polygon linear ring needs ≥4 positions and must
be closed), `geojson-winding` (RFC 7946 §3.1.6 right-hand rule — exterior rings
counterclockwise, holes clockwise; a SHOULD, so reported as guidance),
`geojson-bbox` (must be 2·n numbers, n≥2), and `geojson-crs` (the `crs` member
was removed in RFC 7946). Geometries nested in Features and collections are
checked recursively.

## 5. RFC 8785 mode (`--jcs`)

Off by default. `--jcs` switches two rules to match the **JSON Canonicalization
Scheme** (RFC 8785) instead of the house defaults:

1. **Numbers** are serialized by the ECMAScript `Number.prototype.toString`
   algorithm (ES2017 §7.1.12.1), i.e. *the exact string `String(x)` produces in
   JavaScript*. Each number token is parsed into an IEEE-754 binary64 and the
   **shortest** decimal that round-trips back to that double is emitted, with
   the ECMAScript plain/exponential split (scientific when the decimal exponent
   `n > 21` or `n ≤ -6`):

   | Input        | `--jcs` output            |
   |--------------|---------------------------|
   | `4.0`, `4`   | `4`                       |
   | `1e21`       | `1e+21`                   |
   | `1e20`       | `100000000000000000000`   |
   | `1e-7`       | `1e-7`                    |
   | `0.000001`   | `0.000001`                |
   | `333333333.33333329` | `333333333.3333333` |
   | `5e-324`     | `5e-324` (min subnormal)  |

   This is fundamentally different from the default decimal-string engine
   (§2.3): JCS goes *through* the double, so values beyond binary64 precision
   are rounded (`9007199254740993` → `9007199254740992`) and magnitudes outside
   the finite range are rejected per the `--nan` policy. The shortest-decimal
   step is a pure-Nim / pure-Python port of Ulf Adams' **Ryu** `d2s`
   (`nim/src/ryu.nim`); on the Python side CPython's `repr(float)` provides the
   same shortest digits, and both are validated byte-for-byte against node's
   `String(x)` over millions of random doubles.

2. **Object keys** are sorted by **UTF-16 code unit**, not Unicode code point.
   These agree for all BMP characters; they differ only when an astral key
   (≥ U+10000, encoded as a surrogate pair whose lead unit is U+D800–U+DBFF) is
   compared against a BMP key in U+E000–U+FFFF — the astral key sorts *first*
   under UTF-16.

String escaping (§2.2) and everything else are unchanged — the house defaults
already match JCS there (`/` unescaped, lowercase `\uXXXX`, minimal escapes,
UTF-8 output). `--jcs` composes with `--nan`, `--ndjson`, output encodings, etc.;
it is mutually exclusive in spirit with `--number-format`/`--preserve-number-type`
(those tune the default engine and are ignored for numbers under `--jcs`).

### 5.1 Parity warning
The project's primary goal is the **lossless** decimal engine of §2.3: numbers
are never round-tripped through a float, so the canonical form always reproduces
the exact input value and the two implementations agree without depending on any
float printer. `--jcs` deliberately gives that up for RFC 8785 compliance.

To make the trade-off visible rather than silent, in `--jcs` mode the tool emits
a **warning** for every number whose value actually changes — detected by
comparing the exact decimal value of the token (the §2.3 lossless form) against
the exact decimal value of the Ryu output; they differ exactly when binary64
could not hold the input. Two kinds:

- `PATH: 9007199254740993 → 9007199254740992 (IEEE-754 rounding; not reversible)`
- `PATH: 1e400 exceeds binary64 range (no JCS parity)`

`PATH` is the JSONPath-ish location (`<root>`, `[3]`, `.a.b`, or `line N` for
NDJSON). Exact values (`0.1`, `4.0`, `1e21`, …) produce no warning. Warnings go
to **stderr by default** and do not affect the output bytes.

- `--log FILE` writes the full report to `FILE` (header + one line per change;
  a "conversion is exact" header when nothing changed). **Not written unless
  requested** — the tool never creates a log file on its own.
- `-q` / `--quiet` suppresses the stderr warnings, **but requires `--log`** —
  silencing the console must not be a way to discard the record. Using `--quiet`
  without `--log` is an error (exit 2). So a precision change is always either
  shown on stderr or written to a log; it can never vanish silently.

The warning text and log format are themselves byte-identical between Nim and
Python (covered by `tools/parity.sh`).

### 3.4 JTD schema validation (`--validate FILE`)
Validates the input against a **JSON Type Definition** (RFC 8927) schema, then
exits non-zero if it does not conform. Implements all eight JTD forms (empty,
ref, type, enum, elements, properties, values, discriminator) plus `nullable`
and root `definitions`. Each violation is reported (category `jtd`) as the
instance location with the offending schema location, both rendered as JSON
Pointers per RFC 8927 §3.3.2. The schema is assumed to be a valid JTD schema.

### 3.6 JSON Schema validation (`--schema FILE`)
Validates the input against a **JSON Schema**, dialect autodetected from the
schema's `$schema` (**Draft 2020-12** default, **Draft-07** when the URI says so);
exit non-zero on failure (category `schema`, location = JSON Pointer). Supported
keywords: `type`, `enum`, `const`; `multipleOf`, `maximum`/`minimum` and their
`exclusive*` forms; `minLength`/`maxLength`/`pattern`; `items`/`prefixItems`/
`additionalItems`, `minItems`/`maxItems`, `uniqueItems`, `contains`/`minContains`
/`maxContains`; `properties`/`patternProperties`/`additionalProperties`,
`required`, `propertyNames`, `min`/`maxProperties`, `dependentRequired`/
`dependentSchemas` (and Draft-07 `dependencies`); `allOf`/`anyOf`/`oneOf`/`not`;
`if`/`then`/`else`; boolean schemas; local `$ref` (a `#/…` JSON Pointer into
`$defs`/`definitions`, or `#name` resolving a `$anchor`); and
`unevaluatedProperties`/`unevaluatedItems` (with annotation collection across
`properties`/`additionalProperties`, `allOf`, passing `anyOf`/`oneOf`, and
`if`/`then`/`else`).

`pattern` (and `patternProperties`) use a **self-contained regex subset** —
literals, `.`, classes `[...]`/`[^...]`, anchors `^`/`$`, groups, alternation,
quantifiers `* + ?` `{n,m}`, and `\d\w\s\D\W\S` — implemented identically in both
languages (validated against Python `re` for correctness and Nim==Python for
parity over millions of pattern/text pairs). `format` is annotation-only unless `--format` is given, which asserts a built-in
deterministic check for `date-time`/`date`/`time`, `email`, `hostname`, `ipv4`,
`ipv6`, `uri`, `uuid`, `json-pointer`, and `regex` (unknown formats still pass).
Out of scope (documented): remote `$ref` and `$dynamicRef`/`$dynamicAnchor`
(need network / dynamic scope); `content*` keywords; numeric bounds compare as
binary64. `unevaluated*` annotation collection covers the common applicators
above but is not the full recursive annotation algorithm.

## 3.2 Content hash & diff
Two convenience modes that operate on the canonical form:

- `--sha256`: emit the lowercase SHA-256 hex digest of the canonical output
  bytes (after any `--output-encoding`/`--bom`), plus a trailing newline,
  instead of the bytes themselves. Nim ships its own SHA-256 (`src/sha256.nim`,
  no stdlib dependency); it is byte-identical to Python's `hashlib.sha256`.
- `--diff FILE`: canonicalize INPUT and FILE under the same options, then report
  their structural differences (so whitespace, key order, and number spelling
  are already normalized away — `4.0` and `4` compare equal). One line per
  difference, depth-first with keys in canonical order; exit 1 if any differ:
  `~ PATH: old => new` (changed value or type), `+ PATH: val` (only in FILE),
  `- PATH: val` (only in INPUT).

## 6. CBOR (RFC 8949)
`--from cbor` decodes CBOR into the value tree; `--to cbor` emits **Core
Deterministic Encoding** (RFC 8949 §4.2). Both are single-value (not combined
with `--ndjson`/`--json-seq`); CBOR output is binary and ignores
`--output-encoding`.

Encoding (`--to cbor`):
- Integers: shortest head (major type 0/1). Magnitudes ≥ 2⁶⁴ use bignum tags
  (2 positive, 3 negative). Because numbers are decimal-exact (§2.3), integers —
  including 30-digit ones — survive losslessly.
- Non-integer numbers: the shortest of float16/float32/float64 whose value equals
  the binary64 value (§4.2.2 preferred serialization).
- Strings major type 3; arrays major type 4; objects major type 5 with members
  ordered by the **bytewise lexicographic order of their encoded keys** (§4.2.1)
  — CBOR's own ordering, distinct from §2.1 and from `--jcs`.
- `true`/`false`/`null` → 0xf5/0xf4/0xf6. Non-finite numbers follow `--nan`.

Decoding (`--from cbor`):
- Integers and bignums → exact decimal Numbers; floats → their shortest decimal;
  NaN/Infinity → non-finite (then subject to `--nan` on output).
- Text strings → strings; byte strings → standard base64 text; arrays/maps →
  arrays/objects (non-text map keys are an error); known numeric tags handled,
  other tags transparently unwrapped.

The half-precision codec is validated against Python over all 65 536 bit
patterns, and `--to cbor` is byte-identical between the two implementations
(`tools/parity.sh`).

### 3.5 CDDL schema validation (`--cddl FILE`)
Validates the input against a **CDDL** (RFC 8610) schema, starting from the first
rule, exit non-zero on failure (category `cddl`). Supported subset: type rules
(`name = type`), type choices (`a / b`), primitive types (`bool`, `int`, `uint`,
`nint`, `float`/`float16`/`float32`/`float64`, `number`, `tstr`/`text`,
`bstr`/`bytes`, `any`, `null`/`nil`), literals (numbers, `"text"`, `true`/
`false`), numeric ranges (`1..10`), arrays `[ … ]` and maps `{ … }` with
occurrence indicators (`?`, `*`, `+`, `n*m`), and references to other rules.
Out of scope: groups/sockets/generics, control operators (`.size`, `.regexp`,
…), tags, unwrapping, and recursive types; array matching is greedy. The schema
is assumed valid.

### 6.1 MessagePack (`--from msgpack` / `--to msgpack`)
MessagePack has no official canonical form, so `--to msgpack` emits a
deterministic one in the spirit of CBOR §4.2: smallest int / float (32 vs 64) /
str / array / map headers, and **map members ordered by the bytewise order of
their encoded keys**. Integers beyond 64-bit have no MessagePack representation
(no bignum) and fall back to float64 (rounding, like the rest of the binary
path). Decode maps the int/float/str/bin/array/map families to the value tree
(bin → base64 text; ext → error; non-finite floats → the `--nan` policy).
Byte-identical between the two implementations.

## 7. JData / NeuroJSON (`--from jdata`)
Decodes the JData N-dimensional array annotation — an object carrying
`_ArrayType_`, `_ArraySize_`, and `_ArrayData_` — into the equivalent nested
JSON array (row-major), then canonicalizes normally. `_ArraySize_` may be a
single number (1-D) or an array of dimensions; `_ArrayData_` must be a flat array
whose length equals the product of the dimensions. Objects without the
annotation, and all other values, pass through untouched. Compressed arrays
(`_ArrayZipData_`, which need zlib/lz4 + base64) are not supported and raise.

## 7.1 Pointer & patch transforms
Three transforms run on the parsed value *before* canonicalization (and compose
with `--from`/`--to` and `--jcs`):

- `--pointer EXPR` — extract the sub-value at a **JSON Pointer** (RFC 6901);
  `~1`→`/`, `~0`→`~`, `""` = whole document, array indices have no leading zeros.
- `--patch FILE` — apply a **JSON Patch** (RFC 6902): `add`, `remove`, `replace`,
  `move`, `copy`, `test` (with `-` array append in `add`); a failed `test` or
  structural error fails the whole patch.
- `--merge-patch FILE` — apply a **JSON Merge Patch** (RFC 7386): recursive
  object merge, `null` deletes a member, a non-object patch replaces the target.

## 8. Force / salvage mode (`--force`)
By default a malformed document is an error. `--force` switches the parser to
**best-effort recovery**: it harvests everything that parses and drops only the
ill parts, writing a recovery report to stderr (suppress with `-q`). The
recovery is deterministic — identical bytes from both implementations — and
applies these rules:

- A malformed **object member** (bad key, missing `:`, or unparseable value) is
  dropped; the parser resynchronises to the next `,` or `}` at the same depth.
- A malformed **array element** is dropped, resynchronising to the next `,` or
  `]`.
- An **unterminated** container at end of input is closed with what was
  collected; **trailing data** after a complete value is dropped.
- A top-level value that cannot be parsed at all becomes `null`.

Resynchronisation skips over nested containers and quoted strings, so a `,`
inside a string is not mistaken for a delimiter. Each drop/closure/truncation is
reported as `line:col  message`. `--force` composes with the normal pipeline
(canonicalize, `--jcs`, `--ndjson`, `--to cbor`, …); the salvaged value is then
processed exactly as a clean parse would be.

## 4. Conformance
`tools/parity.sh` runs both implementations over `fixtures/*` and the flag
matrix (number formats, `--jcs`, all output encodings ± BOM, lint), asserting
the outputs are byte-identical to each other and to the committed `*.canon`
golden files. Two extra harnesses pin the Ryu number engine to ground truth:
`tools/fuzz_ryu.py` diffs the Nim `d2s` against node's `String(x)` over millions
of random doubles, and `tools/parity_jcs.py` feeds the same number tokens
through both CLIs in `--jcs` mode to confirm the decimal→double parse agrees.
The Ryu tables are regenerated by `tools/gen_ryu_tables.py`.
