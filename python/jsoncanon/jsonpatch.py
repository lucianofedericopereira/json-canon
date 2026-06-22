"""JSON Patch (RFC 6902) and JSON Merge Patch (RFC 7386).

Both produce a transformed value tree that is then canonicalized. Patch ops are
applied in order; on a failed `test` or any structural error the whole patch
fails (raises). Mirrors jsonpatch.nim. Because the result is canonicalized,
intermediate key order is irrelevant to the output.
"""

from __future__ import annotations

from copy import deepcopy

from .jsonpointer import parse_pointer, resolve_tokens, _array_index
from .parser import JValue, JSONError
from .serializer import dumps


def _add(doc: JValue, path: str, value: JValue) -> JValue:
    toks = parse_pointer(path)
    if not toks:
        return value  # add/replace at root
    parent = resolve_tokens(doc, toks[:-1])
    last = toks[-1]
    if isinstance(parent, list):
        i = _array_index(last, len(parent), allow_dash=True)
        if i > len(parent):
            raise JSONError(f"patch add: index {last} out of range")
        parent.insert(i, value)
    elif isinstance(parent, dict):
        parent[last] = value
    else:
        raise JSONError("patch add: parent is not an array or object")
    return doc


def _replace(doc: JValue, path: str, value: JValue) -> JValue:
    toks = parse_pointer(path)
    if not toks:
        return value
    parent = resolve_tokens(doc, toks[:-1])
    last = toks[-1]
    if isinstance(parent, list):
        i = _array_index(last, len(parent))
        if i >= len(parent):
            raise JSONError(f"patch replace: index {last} out of range")
        parent[i] = value
    elif isinstance(parent, dict):
        if last not in parent:
            raise JSONError(f"patch replace: no member {last!r}")
        parent[last] = value
    else:
        raise JSONError("patch replace: parent is not an array or object")
    return doc


def _remove(doc: JValue, path: str) -> tuple[JValue, JValue]:
    toks = parse_pointer(path)
    if not toks:
        raise JSONError("patch: cannot remove the whole document")
    parent = resolve_tokens(doc, toks[:-1])
    last = toks[-1]
    if isinstance(parent, list):
        i = _array_index(last, len(parent))
        if i >= len(parent):
            raise JSONError(f"patch remove: index {last} out of range")
        return parent.pop(i), doc
    if isinstance(parent, dict):
        if last not in parent:
            raise JSONError(f"patch remove: no member {last!r}")
        return parent.pop(last), doc
    raise JSONError("patch remove: parent is not an array or object")


def _op(doc: JValue, op: JValue) -> JValue:
    if not isinstance(op, dict) or "op" not in op or "path" not in op:
        raise JSONError("patch: each operation needs 'op' and 'path'")
    o, path = op["op"], op["path"]
    if not isinstance(o, str) or not isinstance(path, str):
        raise JSONError("patch: 'op' and 'path' must be strings")
    if o == "add":
        return _add(doc, path, deepcopy(op["value"]))
    if o == "replace":
        return _replace(doc, path, deepcopy(op["value"]))
    if o == "remove":
        return _remove(doc, path)[1]
    if o == "move":
        frm = op["from"]
        assert isinstance(frm, str)
        val, doc = _remove(doc, frm)
        return _add(doc, path, val)
    if o == "copy":
        frm = op["from"]
        assert isinstance(frm, str)
        return _add(doc, path, deepcopy(resolve_tokens(doc, parse_pointer(frm))))
    if o == "test":
        got = resolve_tokens(doc, parse_pointer(path))
        if dumps(got) != dumps(op["value"]):
            raise JSONError(f"patch test failed at {path}")
        return doc
    raise JSONError(f"patch: unknown op {o!r}")


def apply_patch(doc: JValue, patch: JValue) -> JValue:
    if not isinstance(patch, list):
        raise JSONError("JSON Patch must be an array of operations")
    doc = deepcopy(doc)
    for op in patch:
        doc = _op(doc, op)
    return doc


def apply_merge_patch(target: JValue, patch: JValue) -> JValue:
    if isinstance(patch, dict):
        base = target if isinstance(target, dict) else {}
        for k, v in patch.items():
            if v is None:
                base.pop(k, None)
            else:
                base[k] = apply_merge_patch(base.get(k), v)
        return base
    return deepcopy(patch)
