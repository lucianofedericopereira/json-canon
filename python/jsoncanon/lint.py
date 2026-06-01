"""Lint mode — report each deviation from canonical form (see README)."""

from __future__ import annotations

from .parser import JValue, Parser, Number, decode_bytes
from .numbers import canon_number

# A structural finding: (location, category, message).
_Finding = tuple[str, str, str]


def _line_col(text: str, pos: int) -> tuple[int, int]:
    line = text.count("\n", 0, pos) + 1
    col = pos - (text.rfind("\n", 0, pos))
    return line, col


def _structural(node: JValue, path: str, number_format: str,
                out: list[_Finding]) -> None:
    """Walk the parsed tree for structural (path-bearing) issues."""
    if isinstance(node, Number):
        canon = canon_number(node.text, number_format=number_format)
        if canon != node.text:
            out.append((path or "$", "number", f"{node.text} → {canon}"))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            _structural(item, f"{path}[{i}]", number_format, out)
    elif isinstance(node, dict):
        keys = list(node.keys())
        if keys != sorted(keys):
            out.append((path or "$", "key-order", "object keys are not sorted"))
        for k in keys:
            _structural(node[k], f"{path}.{k}", number_format, out)


class Issue:
    __slots__ = ("loc", "category", "message")

    def __init__(self, loc: str, category: str, message: str) -> None:
        self.loc = loc
        self.category = category
        self.message = message


def lint(raw: bytes, *, encoding: str | None = None,
         number_format: str = "plain") -> list[Issue]:
    """Return a list of Issue. Empty list == already canonical."""
    issues: list[Issue] = []
    # BOM / encoding
    for sig, name in ((b"\xef\xbb\xbf", "UTF-8"), (b"\xff\xfe\x00\x00", "UTF-32-LE"),
                      (b"\x00\x00\xfe\xff", "UTF-32-BE"), (b"\xff\xfe", "UTF-16-LE"),
                      (b"\xfe\xff", "UTF-16-BE")):
        if raw.startswith(sig):
            issues.append(Issue("1:1", "bom", f"{name} BOM present"))
            break

    text = decode_bytes(raw, encoding)
    p = Parser(text, collect_diags=True)
    val = p.parse()

    for pos, category, message in p.diags:
        line, col = _line_col(text, pos)
        issues.append(Issue(f"{line}:{col}", category, message))

    struct: list[_Finding] = []
    _structural(val, "$", number_format, struct)
    for path, category, message in struct:
        issues.append(Issue(path, category, message))

    return issues
