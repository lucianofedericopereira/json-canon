"""Lenient JSON parser (see SPEC.md §1).

Produces a value tree built from: dict, list, str, bool, None, Number, and
NonFinite. Numbers are kept as their raw token text (never floated).
"""

from __future__ import annotations

from typing import Literal, NoReturn, Union, overload

from ._json5_ident import is_json5_id_start, is_json5_id_continue

# A parsed JSON value. Numbers are Number (raw token), non-finites NonFinite.
JValue = Union[
    dict[str, "JValue"], list["JValue"], str, bool, None, "Number", "NonFinite",
]
# A lint diagnostic: (position, category, message).
Diag = tuple[int, str, str]


class Number:
    """A numeric literal, kept as raw token text for lossless canonicalization."""
    __slots__ = ("text",)

    def __init__(self, text: str) -> None:
        self.text = text

    def __repr__(self) -> str:
        return f"Number({self.text!r})"


class NonFinite:
    """NaN / Infinity / -Infinity placeholder."""
    __slots__ = ("kind",)  # "nan" | "inf" | "-inf"

    def __init__(self, kind: str) -> None:
        self.kind = kind


class JSONError(ValueError):
    pass


_WS = " \t\n\r\v\f"  # JSON5 also treats vertical-tab / form-feed as whitespace
_HEXDIGITS = "0123456789abcdefABCDEF"


def _valid_number_token(tok: str) -> bool:
    """Matches ^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?$ — the lenient number
    grammar (numbers.py _NUM_RE). Identical algorithm to Nim's validNumberToken,
    so a malformed token ("1e", "1.2.3", "1e30.5") is a clean parse error."""
    i, n = 0, len(tok)
    if i < n and tok[i] in "+-":
        i += 1
    mstart = i
    if i < n and tok[i] == ".":
        i += 1
        ds = i
        while i < n and tok[i].isdigit():
            i += 1
        if i == ds:
            return False
    else:
        ds = i
        while i < n and tok[i].isdigit():
            i += 1
        if i == ds:
            return False
        if i < n and tok[i] == ".":
            i += 1
            while i < n and tok[i].isdigit():
                i += 1
    if i == mstart:
        return False
    if i < n and tok[i] in "eE":
        i += 1
        if i < n and tok[i] in "+-":
            i += 1
        es = i
        while i < n and tok[i].isdigit():
            i += 1
        if i == es:
            return False
    return i == n
_BOMS = [
    (b"\xff\xfe\x00\x00", "utf-32-le"),
    (b"\x00\x00\xfe\xff", "utf-32-be"),
    (b"\xef\xbb\xbf", "utf-8"),
    (b"\xff\xfe", "utf-16-le"),
    (b"\xfe\xff", "utf-16-be"),
]


def decode_bytes(data: bytes, encoding: str | None = None) -> str:
    """Detect BOM / encoding and decode to text, stripping any BOM."""
    if encoding:
        return data.decode(encoding)
    for sig, enc in _BOMS:
        if data.startswith(sig):
            return data[len(sig):].decode(enc)
    text = data.decode("utf-8")
    if text and text[0] == "﻿":
        text = text[1:]
    return text


class Parser:
    def __init__(self, text: str, strict_dupes: bool = False,
                 collect_diags: bool = False, force: bool = False) -> None:
        self.s = text
        self.i = 0
        self.n = len(text)
        self.strict_dupes = strict_dupes
        self.collect_diags = collect_diags
        self.diags: list[Diag] = []
        self.force = force
        self.fwarn: list[Diag] = []

    # -- helpers ----------------------------------------------------------
    def _diag(self, pos: int, category: str, message: str) -> None:
        if self.collect_diags:
            self.diags.append((pos, category, message))

    def _recover(self, pos: int, message: str) -> None:
        self.fwarn.append((pos, "recover", message))

    def _skip_to_delim(self) -> None:
        """Force-mode resync: advance to the next ',' '}' or ']' at the current
        depth, skipping nested containers and strings. Leaves i at the delimiter."""
        s, n = self.s, self.n
        depth = 0
        while self.i < n:
            c = s[self.i]
            if c == '"' or c == "'":
                self.i += 1
                while self.i < n and s[self.i] != c:
                    if s[self.i] == "\\":
                        self.i += 1
                    self.i += 1
                if self.i < n:
                    self.i += 1
            elif c in "[{":
                depth += 1
                self.i += 1
            elif c in "]}":
                if depth == 0:
                    return
                depth -= 1
                self.i += 1
            elif c == "," and depth == 0:
                return
            else:
                self.i += 1

    def _err(self, msg: str) -> NoReturn:
        raise JSONError(f"{msg} at position {self.i}")

    def _skip_ws(self) -> None:
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in _WS:
                self.i += 1
            elif c == "/" and self.i + 1 < n and s[self.i + 1] in "/*":
                self._skip_comment()
            else:
                break

    def _skip_comment(self) -> None:
        s, n = self.s, self.n
        self._diag(self.i, "comment", "comment is not valid JSON")
        if s[self.i + 1] == "/":
            self.i += 2
            while self.i < n and s[self.i] != "\n":
                self.i += 1
        else:
            self.i += 2
            while self.i < n and not (s[self.i] == "*" and self.i + 1 < n and s[self.i + 1] == "/"):
                self.i += 1
            if self.i >= n:
                self._err("unterminated block comment")
            self.i += 2

    def _peek(self) -> str:
        return self.s[self.i] if self.i < self.n else ""

    # -- entry ------------------------------------------------------------
    def parse(self) -> JValue:
        self._skip_ws()
        val = self._value()
        self._skip_ws()
        if self.i != self.n:
            self._err("trailing data")
        return val

    def _value(self) -> JValue:
        self._skip_ws()
        c = self._peek()
        if c == "":
            self._err("unexpected end of input")
        if c == "{":
            return self._object()
        if c == "[":
            return self._array()
        if c == '"' or c == "'":
            return self._string(c)
        if c == "-" or c == "+" or c.isdigit() or c == ".":
            return self._number_or_keyword()
        return self._keyword()

    def _object(self) -> dict[str, JValue]:
        self.i += 1  # {
        obj: dict[str, JValue] = {}
        self._skip_ws()
        if self._peek() == "}":
            self.i += 1
            return obj
        while True:
            self._skip_ws()
            if self.force:
                mem_start = self.i
                try:
                    q = self._peek()
                    key = self._string(q) if q in ('"', "'") else self._ident_key()
                    self._skip_ws()
                    if self._peek() != ":":
                        self._err("expected ':'")
                    self.i += 1
                    val = self._value()
                    obj[key] = val  # last wins
                except JSONError:
                    self._recover(mem_start, "dropped malformed object member")
                    self._skip_to_delim()
            else:
                q = self._peek()
                if q in ('"', "'"):
                    key = self._string(q)
                else:
                    key = self._ident_key()
                self._skip_ws()
                if self._peek() != ":":
                    self._err("expected ':'")
                self.i += 1
                val = self._value()
                if key in obj:
                    if self.strict_dupes:
                        self._err(f"duplicate key {key!r}")
                    self._diag(self.i, "duplicate-key", f"duplicate key {key!r} (last value wins)")
                obj[key] = val  # last wins
            self._skip_ws()
            c = self._peek()
            if c == ",":
                self.i += 1
                self._skip_ws()
                if self._peek() == "}":  # trailing comma
                    self._diag(self.i, "trailing-comma", "trailing comma in object")
                    self.i += 1
                    return obj
                continue
            if c == "}":
                self.i += 1
                return obj
            if self.force:
                if c == "":
                    self._recover(self.i, "unterminated object at end of input")
                    return obj
                self._recover(self.i, "unexpected token in object")
                self._skip_to_delim()
                if self._peek() == "}":
                    self.i += 1
                    return obj
                if self._peek() == ",":
                    self.i += 1
                    continue
                return obj
            self._err("expected ',' or '}'")

    def _array(self) -> list[JValue]:
        self.i += 1  # [
        arr: list[JValue] = []
        self._skip_ws()
        if self._peek() == "]":
            self.i += 1
            return arr
        while True:
            if self.force:
                elem_start = self.i
                try:
                    arr.append(self._value())
                except JSONError:
                    self._recover(elem_start, "dropped malformed array element")
                    self._skip_to_delim()
            else:
                arr.append(self._value())
            self._skip_ws()
            c = self._peek()
            if c == ",":
                self.i += 1
                self._skip_ws()
                if self._peek() == "]":  # trailing comma
                    self._diag(self.i, "trailing-comma", "trailing comma in array")
                    self.i += 1
                    return arr
                continue
            if c == "]":
                self.i += 1
                return arr
            if self.force:
                if c == "":
                    self._recover(self.i, "unterminated array at end of input")
                    return arr
                self._recover(self.i, "unexpected token in array")
                self._skip_to_delim()
                if self._peek() == "]":
                    self.i += 1
                    return arr
                if self._peek() == ",":
                    self.i += 1
                    continue
                return arr
            self._err("expected ',' or ']'")

    @staticmethod
    def _is_id_start(cp: int) -> bool:
        if cp < 0x80:
            c = chr(cp)
            return c.isalpha() or c in "_$"
        return is_json5_id_start(cp)

    @staticmethod
    def _is_id_continue(cp: int) -> bool:
        if cp < 0x80:
            c = chr(cp)
            return c.isalnum() or c in "_$"
        return is_json5_id_continue(cp)

    def _ident_codepoint(self) -> int:
        """Consume one identifier unit — a ``\\uXXXX`` escape (with optional
        surrogate pairing) or a raw code point — and return it."""
        s = self.s
        if s[self.i] == "\\":
            if s[self.i + 1:self.i + 2] != "u":
                self._err("invalid identifier escape")
            cp = int(s[self.i + 2:self.i + 6], 16)
            self.i += 6
            if 0xD800 <= cp <= 0xDBFF and s[self.i:self.i + 2] == "\\u":
                lo = int(s[self.i + 2:self.i + 6], 16)
                if 0xDC00 <= lo <= 0xDFFF:
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    self.i += 6
            return cp
        cp = ord(s[self.i])
        self.i += 1
        return cp

    def _ident_key(self) -> str:
        """JSON5 unquoted key: ASCII / Unicode (ID_Start / ID_Continue) /
        ``\\u``-escaped identifier (SPEC §1.2)."""
        s, n = self.s, self.n
        start = self.i
        if self.i >= n:
            self._err("expected string key")
        cp = self._ident_codepoint()
        if not self._is_id_start(cp):
            self.i = start
            self._err("expected string key")
        out = [chr(cp)]
        while self.i < n:
            save = self.i
            if s[self.i] == "\\":
                if s[self.i + 1:self.i + 2] != "u":
                    break
                cp = self._ident_codepoint()
                if not self._is_id_continue(cp):
                    self.i = save
                    break
                out.append(chr(cp))
            else:
                cp = ord(s[self.i])
                if not self._is_id_continue(cp):
                    break
                self.i += 1
                out.append(chr(cp))
        key = "".join(out)
        self._diag(start, "unquoted-key", f"unquoted key {key!r} is JSON5, not JSON")
        return key

    def _string(self, quote: str) -> str:
        s, n = self.s, self.n
        if quote == "'":
            self._diag(self.i, "single-quote", "single-quoted string is not valid JSON")
        self.i += 1  # opening quote
        out: list[str] = []
        while self.i < n:
            c = s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                if self.i >= n:
                    self._err("unterminated escape")
                e = s[self.i]
                if e == "u":
                    hex4 = s[self.i + 1:self.i + 5]
                    cp = int(hex4, 16)
                    self.i += 5
                    if 0xD800 <= cp <= 0xDBFF and s[self.i:self.i + 2] == "\\u":
                        lo = int(s[self.i + 2:self.i + 6], 16)
                        if 0xDC00 <= lo <= 0xDFFF:
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                            self.i += 6
                    out.append(chr(cp))
                    continue
                if e == "x":  # JSON5 \xHH byte escape
                    self._diag(self.i - 1, "hex-escape", r"\xHH escape is JSON5, not JSON")
                    out.append(chr(int(s[self.i + 1:self.i + 3], 16)))
                    self.i += 3
                    continue
                if e in "\n\r\u2028\u2029":  # JSON5 line continuation -> nothing
                    self._diag(self.i - 1, "line-continuation",
                               "escaped newline is JSON5, not JSON")
                    self.i += 1
                    if e == "\r" and self.i < n and s[self.i] == "\n":
                        self.i += 1
                    continue
                out.append({
                    '"': '"', "'": "'", "\\": "\\", "/": "/",
                    "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t",
                    "v": "\v", "0": "\0",
                }.get(e, e))
                self.i += 1
            else:
                out.append(c)
                self.i += 1
        self._err("unterminated string")

    def _number_or_keyword(self) -> JValue:
        # Could be +Infinity / -Infinity.
        s = self.s
        if s.startswith("Infinity", self.i):
            self._diag(self.i, "non-finite", "Infinity has no JSON representation")
            self.i += 8
            return NonFinite("inf")
        if s.startswith("+Infinity", self.i):
            self._diag(self.i, "non-finite", "+Infinity has no JSON representation")
            self.i += 9
            return NonFinite("inf")
        if s.startswith("-Infinity", self.i):
            self._diag(self.i, "non-finite", "-Infinity has no JSON representation")
            self.i += 9
            return NonFinite("-inf")
        if s[self.i:self.i + 4].lower() == "-inf":
            self._diag(self.i, "non-finite", "-inf has no JSON representation")
            self.i += 4
            return NonFinite("-inf")
        if s[self.i:self.i + 3].lower() == "inf":
            self._diag(self.i, "non-finite", "inf has no JSON representation")
            self.i += 3
            return NonFinite("inf")
        return self._number()

    def _number(self) -> Number:
        s, n = self.s, self.n
        start = self.i
        if s[self.i] in "+-":
            self.i += 1
        if s[self.i:self.i + 2] in ("0x", "0X"):  # JSON5 hex integer
            self.i += 2
            hstart = self.i
            while self.i < n and s[self.i] in _HEXDIGITS:
                self.i += 1
            if self.i == hstart:
                self._err("invalid hex number")
            self._diag(start, "hex-number",
                       f"hex number {s[start:self.i]!r} is JSON5, not JSON")
            dec = int(s[hstart:self.i], 16)
            if s[start] == "-":
                dec = -dec
            return Number(str(dec))
        while self.i < n and (s[self.i].isdigit() or s[self.i] in ".eE+-"):
            # stop +/- that isn't part of an exponent
            if s[self.i] in "+-" and s[self.i - 1] not in "eE":
                break
            self.i += 1
        tok = s[start:self.i]
        if not _valid_number_token(tok):
            self._err(f"invalid number {tok!r}")
        body = tok[1:] if tok[:1] in "+-" else tok
        if tok[:1] == "+":
            self._diag(start, "number-syntax", f"leading '+' in number {tok!r}")
        elif len(body) > 1 and body[0] == "0" and body[1].isdigit():
            self._diag(start, "number-syntax", f"leading zero in number {tok!r}")
        elif body[:1] == "." or body[-1:] == ".":
            self._diag(start, "number-syntax", f"missing digit in number {tok!r}")
        return Number(tok)

    def _keyword(self) -> JValue:
        s = self.s
        val: JValue
        for lit, val, dialect in (
            ("true", True, None), ("True", True, "True"),
            ("false", False, None), ("False", False, "False"),
            ("null", None, None), ("None", None, "None"),
            ("NaN", NonFinite("nan"), "non-finite"), ("nan", NonFinite("nan"), "non-finite"),
            ("Infinity", NonFinite("inf"), "non-finite"), ("Inf", NonFinite("inf"), "non-finite"),
            ("inf", NonFinite("inf"), "non-finite"),
        ):
            if s.startswith(lit, self.i):
                if dialect == "non-finite":
                    self._diag(self.i, "non-finite", f"{lit} has no JSON representation")
                elif dialect:
                    self._diag(self.i, "python-literal", f"{dialect} is Python, not JSON")
                self.i += len(lit)
                return val
        self._err("unexpected token")


@overload
def loads(text: str, *, strict_dupes: bool = ...,
          collect_diags: Literal[False] = ...) -> JValue: ...
@overload
def loads(text: str, *, strict_dupes: bool = ...,
          collect_diags: Literal[True]) -> tuple[JValue, list[Diag]]: ...


def loads(text: str, *, strict_dupes: bool = False,
          collect_diags: bool = False) -> JValue | tuple[JValue, list[Diag]]:
    p = Parser(text, strict_dupes=strict_dupes, collect_diags=collect_diags)
    val = p.parse()
    return (val, p.diags) if collect_diags else val


def parse_force(text: str, *, strict_dupes: bool = False) -> tuple[JValue, list[Diag]]:
    """Best-effort recovery parse (--force): salvage as much as parses, dropping
    malformed members/elements and trailing garbage, recording warnings."""
    p = Parser(text, strict_dupes=strict_dupes, force=True)
    p._skip_ws()
    try:
        val: JValue = p._value()
    except JSONError:
        p._recover(p.i, "could not parse a value; using null")
        val = None
    p._skip_ws()
    if p.i != p.n:
        p._recover(p.i, "dropped trailing data after the value")
    return val, p.fwarn


def load_ndjson(text: str, *, strict_dupes: bool = False) -> list[JValue]:
    vals: list[JValue] = []
    for line in text.splitlines():
        if line.strip() == "":
            continue
        vals.append(Parser(line, strict_dupes=strict_dupes).parse())
    return vals


def load_stream(text: str, *, strict_dupes: bool = False) -> list[JValue]:
    """Parse a sequence of top-level values: RFC 7464 JSON Text Sequences
    (RS-prefixed, LF-terminated records), whitespace-separated values, and
    directly concatenated values — all handled by one lenient reader."""
    p = Parser(text, strict_dupes=strict_dupes)
    vals: list[JValue] = []
    n = p.n
    while True:
        while True:  # skip ws / comments / RS framing
            p._skip_ws()
            if p.i < n and text[p.i] == "\x1e":
                p.i += 1
            else:
                break
        if p.i >= n:
            break
        vals.append(p._value())
    return vals
