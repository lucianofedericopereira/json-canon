"""JSON Pointer (RFC 6901) — parse + resolve. Shared by --pointer and JSON Patch.

`--pointer EXPR` extracts the referenced sub-value, which is then canonicalized.
Array indices follow RFC 6901: "0" or a no-leading-zero decimal (and "-" only in
JSON Patch `add`, handled there).
"""

from __future__ import annotations

from .parser import JValue, JSONError


def unescape(tok: str) -> str:
    return tok.replace("~1", "/").replace("~0", "~")


def parse_pointer(ptr: str) -> list[str]:
    if ptr == "":
        return []
    if not ptr.startswith("/"):
        raise JSONError(f"invalid JSON Pointer {ptr!r} (must be empty or start with '/')")
    return [unescape(t) for t in ptr[1:].split("/")]


def _array_index(tok: str, length: int, *, allow_dash: bool = False) -> int:
    if allow_dash and tok == "-":
        return length
    if tok != "0" and (tok == "" or tok[0] == "0" or not tok.isdigit()):
        raise JSONError(f"JSON Pointer: invalid array index {tok!r}")
    return int(tok)


def resolve_tokens(doc: JValue, toks: list[str]) -> JValue:
    node = doc
    for tok in toks:
        if isinstance(node, dict):
            if tok not in node:
                raise JSONError(f"JSON Pointer: no member {tok!r}")
            node = node[tok]
        elif isinstance(node, list):
            i = _array_index(tok, len(node))
            if i >= len(node):
                raise JSONError(f"JSON Pointer: index {tok} out of range")
            node = node[i]
        else:
            raise JSONError(f"JSON Pointer: cannot descend into a scalar at {tok!r}")
    return node


def get_pointer(doc: JValue, ptr: str) -> JValue:
    return resolve_tokens(doc, parse_pointer(ptr))
