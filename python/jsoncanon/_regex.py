"""A small, self-contained regex engine — the subset JSON Schema `pattern`
needs, with identical semantics in the Nim port so the validators stay
byte-parity. NOT a general regex library.

Supported: literals, `.` (any char except newline), character classes
`[...]`/`[^...]` with ranges, anchors `^`/`$` (string start/end), groups `(...)`,
alternation `|`, quantifiers `* + ?` and `{n}` `{n,}` `{n,m}` (greedy), and the
escapes `\\d \\w \\s \\D \\W \\S \\n \\t \\r \\f \\v` plus `\\<metachar>`.
Matching is `search` semantics (unanchored), matching ECMAScript `test()` /
`re.search` for this subset. Backtracking matcher; repeats require progress
(no zero-width loops), which is fine for schema patterns.
"""

from __future__ import annotations

from typing import Any, Callable

from .parser import JSONError

_DIGIT = [(ord("0"), ord("9"))]
_WORD = [(ord("0"), ord("9")), (ord("A"), ord("Z")), (ord("a"), ord("z")), (ord("_"), ord("_"))]
_SPACE = [(c, c) for c in (0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B)]


class _RP:
    def __init__(self, src: str) -> None:
        self.s = src
        self.i = 0
        self.n = len(src)

    def parse(self) -> Any:
        node = self._alt()
        if self.i != self.n:
            raise JSONError(f"regex: unexpected {self.s[self.i]!r}")
        return node

    def _alt(self) -> Any:
        branches = [self._seq()]
        while self.i < self.n and self.s[self.i] == "|":
            self.i += 1
            branches.append(self._seq())
        return ("alt", branches) if len(branches) > 1 else branches[0]

    def _seq(self) -> Any:
        items = []
        while self.i < self.n and self.s[self.i] not in "|)":
            items.append(self._quantified())
        return ("seq", items)

    def _quantified(self) -> Any:
        atom = self._atom()
        if self.i < self.n and self.s[self.i] in "*+?":
            q = self.s[self.i]
            self.i += 1
            lo, hi = {"*": (0, None), "+": (1, None), "?": (0, 1)}[q]
            return ("rep", atom, lo, hi)
        if self.i < self.n and self.s[self.i] == "{":
            return self._brace(atom)
        return atom

    def _brace(self, atom: Any) -> Any:
        j = self.s.find("}", self.i)
        if j < 0:
            raise JSONError("regex: unterminated {")
        body = self.s[self.i + 1:j]
        self.i = j + 1
        if "," in body:
            a, _, b = body.partition(",")
            lo = int(a) if a else 0
            hi = int(b) if b else None
        else:
            lo = hi = int(body)
        return ("rep", atom, lo, hi)

    def _atom(self) -> Any:
        c = self.s[self.i]
        if c == "(":
            self.i += 1
            # optional non-capturing prefix (?:
            if self.s[self.i:self.i + 2] == "?:":
                self.i += 2
            node = self._alt()
            if self.i >= self.n or self.s[self.i] != ")":
                raise JSONError("regex: unterminated (")
            self.i += 1
            return node
        if c == "[":
            return self._class()
        if c == ".":
            self.i += 1
            return ("dot",)
        if c == "^":
            self.i += 1
            return ("bol",)
        if c == "$":
            self.i += 1
            return ("eol",)
        if c == "\\":
            return self._escape()
        self.i += 1
        return ("lit", c)

    def _escape(self) -> Any:
        self.i += 1
        if self.i >= self.n:
            raise JSONError("regex: trailing backslash")
        e = self.s[self.i]
        self.i += 1
        if e == "d":
            return ("class", False, _DIGIT)
        if e == "D":
            return ("class", True, _DIGIT)
        if e == "w":
            return ("class", False, _WORD)
        if e == "W":
            return ("class", True, _WORD)
        if e == "s":
            return ("class", False, _SPACE)
        if e == "S":
            return ("class", True, _SPACE)
        lit = {"n": "\n", "t": "\t", "r": "\r", "f": "\f", "v": "\v"}.get(e, e)
        return ("lit", lit)

    def _class(self) -> Any:
        self.i += 1  # [
        neg = False
        if self.i < self.n and self.s[self.i] == "^":
            neg = True
            self.i += 1
        ranges: list[tuple[int, int]] = []
        while self.i < self.n and self.s[self.i] != "]":
            lo = self._class_char()
            if self.i + 1 < self.n and self.s[self.i] == "-" and self.s[self.i + 1] != "]":
                self.i += 1
                hi = self._class_char()
                ranges.append((lo, hi))
            else:
                ranges.append((lo, lo))
        if self.i >= self.n:
            raise JSONError("regex: unterminated [")
        self.i += 1  # ]
        return ("class", neg, ranges)

    def _class_char(self) -> int:
        if self.s[self.i] == "\\":
            self.i += 1
            e = self.s[self.i]
            self.i += 1
            return ord({"n": "\n", "t": "\t", "r": "\r", "f": "\f", "v": "\v"}.get(e, e))
        c = self.s[self.i]
        self.i += 1
        return ord(c)


def _in_ranges(cp: int, ranges: list[tuple[int, int]]) -> bool:
    return any(lo <= cp <= hi for lo, hi in ranges)


def _match(node: Any, s: str, i: int, k: Callable[[int], bool]) -> bool:
    t = node[0]
    if t == "seq":
        items = node[1]

        def run(idx: int, j: int) -> bool:
            if idx == len(items):
                return k(j)
            return _match(items[idx], s, j, lambda j2: run(idx + 1, j2))
        return run(0, i)
    if t == "alt":
        return any(_match(b, s, i, k) for b in node[1])
    if t == "rep":
        _, sub, lo, hi = node

        def rec(count: int, j: int, prev_empty: bool) -> bool:
            # greedy: try one more iteration first. An empty iteration is allowed
            # (needed for nullable subexpressions) but two empties in a row are
            # blocked to avoid infinite loops.
            if hi is None or count < hi:
                def after(j2: int) -> bool:
                    if j2 == j and prev_empty:
                        return False
                    return rec(count + 1, j2, j2 == j)
                if _match(sub, s, j, after):
                    return True
            if count >= lo:
                return k(j)
            # below the minimum with only empty matches left: empty iterations
            # satisfy the minimum (re treats a nullable repeat this way).
            if _match(sub, s, j, lambda j2: j2 == j):
                return k(j)
            return False
        return rec(0, i, False)
    if t == "lit":
        return i < len(s) and s[i] == node[1] and k(i + 1)
    if t == "dot":
        return i < len(s) and s[i] != "\n" and k(i + 1)
    if t == "class":
        if i >= len(s):
            return False
        inside = _in_ranges(ord(s[i]), node[2])
        return (inside != node[1]) and k(i + 1)
    if t == "bol":
        return i == 0 and k(i)
    if t == "eol":
        return i == len(s) and k(i)
    raise JSONError(f"regex: bad node {t}")


def search(pattern: str, text: str) -> bool:
    """True if `pattern` matches anywhere in `text` (unanchored)."""
    ast = _RP(pattern).parse()
    for start in range(len(text) + 1):
        if _match(ast, text, start, lambda j: True):
            return True
    return False
