"""Lenient JSON parser (see SPEC.md §1).

Produces a value tree built from: dict, list, str, bool, None, Number, and
NonFinite. Numbers are kept as their raw token text (never floated).
"""

from __future__ import annotations

from typing import Literal, NoReturn, Union, overload

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
                 collect_diags: bool = False) -> None:
        self.s = text
        self.i = 0
        self.n = len(text)
        self.strict_dupes = strict_dupes
        self.collect_diags = collect_diags
        self.diags: list[Diag] = []

    # -- helpers ----------------------------------------------------------
    def _diag(self, pos: int, category: str, message: str) -> None:
        if self.collect_diags:
            self.diags.append((pos, category, message))

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
            self._err("expected ',' or '}'")

    def _array(self) -> list[JValue]:
        self.i += 1  # [
        arr: list[JValue] = []
        self._skip_ws()
        if self._peek() == "]":
            self.i += 1
            return arr
        while True:
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
            self._err("expected ',' or ']'")

    @staticmethod
    def _ident_start(c: str) -> bool:
        return c.isascii() and (c.isalpha() or c in "_$")

    @staticmethod
    def _ident_part(c: str) -> bool:
        return c.isascii() and (c.isalnum() or c in "_$")

    def _ident_key(self) -> str:
        s, n = self.s, self.n
        start = self.i
        if self.i >= n or not self._ident_start(s[self.i]):
            self._err("expected string key")
        self.i += 1
        while self.i < n and self._ident_part(s[self.i]):
            self.i += 1
        self._diag(start, "unquoted-key",
                   f"unquoted key {s[start:self.i]!r} is JSON5, not JSON")
        return s[start:self.i]

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
        if tok in ("", "+", "-"):
            self._err("invalid number")
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


def load_ndjson(text: str, *, strict_dupes: bool = False) -> list[JValue]:
    vals: list[JValue] = []
    for line in text.splitlines():
        if line.strip() == "":
            continue
        vals.append(Parser(line, strict_dupes=strict_dupes).parse())
    return vals
