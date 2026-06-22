"""JSON Schema validator — Draft 2020-12 and Draft-07 (practical subset).

Dialect is autodetected from `$schema` (defaults to 2020-12). Instance numbers
keep their decimal text (compared as binary64 for bounds, like everywhere else).
Errors are (instancePath JSON Pointer, keyword message), produced in a fixed
order so the Nim port is byte-identical.

Supported keywords: type, enum, const; multipleOf, maximum/minimum and their
exclusive forms; minLength/maxLength/pattern (pattern via the shared regex
subset); items/prefixItems/additionalItems, minItems/maxItems, uniqueItems,
contains/minContains/maxContains; properties/patternProperties/
additionalProperties, required, propertyNames, min/maxProperties,
dependentRequired/dependentSchemas (and Draft-07 `dependencies`); allOf/anyOf/
oneOf/not; if/then/else; local `$ref` (#/… JSON Pointer) into $defs/definitions;
boolean schemas. `format` is annotation-only. Out of scope (documented):
$dynamicRef/$anchor, remote refs, unevaluatedProperties/Items, content*.
"""

from __future__ import annotations

import math
from typing import Any

from ._format import format_ok
from ._regex import search as _re_search
from .lint import Issue
from .numbers import canon_number
from .parser import JValue, Number, decode_bytes, loads, JSONError
from .serializer import dumps

Schema = Any
_ASSERT_FORMAT = False  # set per call by validate_jsonschema (see --format)
_ANCHORS: dict[str, Schema] = {}  # $anchor name -> schema, collected per call


def _collect_anchors(node: Schema, out: dict[str, Schema]) -> None:
    if isinstance(node, dict):
        a = node.get("$anchor")
        if isinstance(a, str):
            out.setdefault(a, node)
        for v in node.values():
            _collect_anchors(v, out)
    elif isinstance(node, list):
        for v in node:
            _collect_anchors(v, out)


def _ptr(tokens: list[str]) -> str:
    return "".join("/" + t.replace("~", "~0").replace("/", "~1") for t in tokens)


def _canon(v: JValue) -> str:
    return dumps(v)


def _num(v: Number) -> float:
    return float(canon_number(v.text, number_format="plain"))


def _is_integer(v: JValue) -> bool:
    return isinstance(v, Number) and "." not in canon_number(v.text, number_format="plain")


def _type_ok(t: str, inst: JValue) -> bool:
    if t == "null":
        return inst is None
    if t == "boolean":
        return inst is True or inst is False
    if t == "object":
        return isinstance(inst, dict)
    if t == "array":
        return isinstance(inst, list)
    if t == "string":
        return isinstance(inst, str)
    if t == "integer":
        return _is_integer(inst)
    if t == "number":
        return isinstance(inst, Number)
    return False


def _resolve(root: Schema, ref: str) -> Schema:
    if not ref.startswith("#"):
        raise JSONError(f"JSON Schema: only local $ref supported, got {ref!r}")
    if len(ref) > 1 and ref[1] != "/":          # plain-name $anchor (#name)
        name = ref[1:]
        if name in _ANCHORS:
            return _ANCHORS[name]
        raise JSONError(f"JSON Schema: cannot resolve $ref {ref!r}")
    node: JValue = root
    frag = ref[1:].lstrip("/")
    if frag:
        for raw in frag.split("/"):
            tok = raw.replace("~1", "/").replace("~0", "~")
            if isinstance(node, dict) and tok in node:
                node = node[tok]
            elif isinstance(node, list) and tok.isdigit() and int(tok) < len(node):
                node = node[int(tok)]
            else:
                raise JSONError(f"JSON Schema: cannot resolve $ref {ref!r}")
    return node


def _validate(root: Schema, schema: Schema, inst: JValue, ip: list[str],
              errors: list[tuple[str, str]], dialect: str) -> None:
    # Boolean schemas.
    if schema is True:
        return
    if schema is False:
        errors.append((_ptr(ip), "boolean false schema: nothing is valid"))
        return
    assert isinstance(schema, dict)

    if "$ref" in schema:
        target = schema["$ref"]
        assert isinstance(target, str)
        _validate(root, _resolve(root, target), inst, ip, errors, dialect)
        # In 2019-09+ $ref is non-exclusive, but for our subset we treat $ref
        # standalone (the common case) and stop here.
        return

    here = _ptr(ip)

    # --- type / enum / const ---
    if "type" in schema:
        t = schema["type"]
        types = t if isinstance(t, list) else [t]
        if not any(_type_ok(str(x), inst) for x in types):
            errors.append((here, f"type: expected {'/'.join(str(x) for x in types)}"))
    if "enum" in schema:
        choices = schema["enum"]
        assert isinstance(choices, list)
        if not any(_canon(inst) == _canon(c) for c in choices):
            errors.append((here, "enum: value not in the allowed set"))
    if "const" in schema:
        if _canon(inst) != _canon(schema["const"]):
            errors.append((here, "const: value does not equal the constant"))

    # --- numbers ---
    if isinstance(inst, Number):
        x = _num(inst)
        if "multipleOf" in schema:
            m = _num(schema["multipleOf"])
            q = x / m
            if q - math.floor(q) != 0:
                errors.append((here, "multipleOf: not a multiple"))
        if "maximum" in schema and x > _num(schema["maximum"]):
            errors.append((here, "maximum exceeded"))
        if "minimum" in schema and x < _num(schema["minimum"]):
            errors.append((here, "minimum not met"))
        if "exclusiveMaximum" in schema and x >= _num(schema["exclusiveMaximum"]):
            errors.append((here, "exclusiveMaximum reached"))
        if "exclusiveMinimum" in schema and x <= _num(schema["exclusiveMinimum"]):
            errors.append((here, "exclusiveMinimum reached"))

    # --- strings ---
    if isinstance(inst, str):
        if "minLength" in schema and len(inst) < _num(schema["minLength"]):
            errors.append((here, "minLength not met"))
        if "maxLength" in schema and len(inst) > _num(schema["maxLength"]):
            errors.append((here, "maxLength exceeded"))
        if "pattern" in schema:
            pat = schema["pattern"]
            assert isinstance(pat, str)
            if not _re_search(pat, inst):
                errors.append((here, "pattern: does not match"))
        if _ASSERT_FORMAT and "format" in schema:
            fmt = schema["format"]
            assert isinstance(fmt, str)
            if not format_ok(fmt, inst):
                errors.append((here, f"format: not a valid {fmt}"))

    # --- arrays ---
    if isinstance(inst, list):
        _validate_array(root, schema, inst, ip, errors, dialect)

    # --- objects ---
    if isinstance(inst, dict):
        _validate_object(root, schema, inst, ip, errors, dialect)

    # --- applicators ---
    if "allOf" in schema:
        for i, sub in enumerate(schema["allOf"]):
            _validate(root, sub, inst, ip, errors, dialect)
    if "anyOf" in schema:
        if not any(not _probe(root, sub, inst, dialect) for sub in schema["anyOf"]):
            errors.append((here, "anyOf: no subschema matched"))
    if "oneOf" in schema:
        n = sum(1 for sub in schema["oneOf"] if not _probe(root, sub, inst, dialect))
        if n != 1:
            errors.append((here, f"oneOf: matched {n} subschemas (need exactly 1)"))
    if "not" in schema:
        if not _probe(root, schema["not"], inst, dialect):
            errors.append((here, "not: subschema unexpectedly matched"))
    if "if" in schema:
        if not _probe(root, schema["if"], inst, dialect):   # "if" matched
            if "then" in schema:
                _validate(root, schema["then"], inst, ip, errors, dialect)
        else:                                                # "if" did not match
            if "else" in schema:
                _validate(root, schema["else"], inst, ip, errors, dialect)


def _probe(root: Schema, schema: Schema, inst: JValue, dialect: str) -> bool:
    """True if `inst` has any validation error against `schema`."""
    tmp: list[tuple[str, str]] = []
    _validate(root, schema, inst, [], tmp, dialect)
    return bool(tmp)


def _validate_array(root: Schema, schema: Schema, inst: list[JValue],
                    ip: list[str], errors: list[tuple[str, str]], dialect: str) -> None:
    here = _ptr(ip)
    prefix = schema.get("prefixItems")
    if prefix is None and dialect == "draft7" and isinstance(schema.get("items"), list):
        prefix = schema["items"]
    rest = schema.get("items")
    if isinstance(rest, list):  # draft-07 tuple form handled via prefix
        rest = schema.get("additionalItems")

    start = 0
    if isinstance(prefix, list):
        for i, sub in enumerate(prefix):
            if i < len(inst):
                _validate(root, sub, inst[i], ip + [str(i)], errors, dialect)
        start = len(prefix)
    if rest is not None and not isinstance(rest, list):
        for i in range(start, len(inst)):
            _validate(root, rest, inst[i], ip + [str(i)], errors, dialect)

    if "minItems" in schema and len(inst) < _num(schema["minItems"]):
        errors.append((here, "minItems not met"))
    if "maxItems" in schema and len(inst) > _num(schema["maxItems"]):
        errors.append((here, "maxItems exceeded"))
    if schema.get("uniqueItems") is True:
        seen = set()
        for e in inst:
            c = _canon(e)
            if c in seen:
                errors.append((here, "uniqueItems: duplicate element"))
                break
            seen.add(c)
    if "contains" in schema:
        matched = sum(1 for e in inst if not _probe(root, schema["contains"], e, dialect))
        lo = int(_num(schema["minContains"])) if "minContains" in schema else 1
        hi = int(_num(schema["maxContains"])) if "maxContains" in schema else None
        if matched < lo or (hi is not None and matched > hi):
            errors.append((here, "contains: count outside min/maxContains"))

    if "unevaluatedItems" in schema:
        n = _eval_items(root, schema, inst, dialect)
        ui = schema["unevaluatedItems"]
        for i in range(n, len(inst)):
            if ui is False:
                errors.append((_ptr(ip + [str(i)]), "unevaluatedItems: not allowed"))
            elif ui is not True:
                _validate(root, ui, inst[i], ip + [str(i)], errors, dialect)


def _eval_props(root: Schema, schema: Schema, inst: dict[str, JValue], dialect: str) -> set[str]:
    """Property names of `inst` considered evaluated by `schema` (properties /
    patternProperties / additionalProperties + successful in-place applicators).
    Used by unevaluatedProperties. Does not itself count unevaluatedProperties."""
    if not isinstance(schema, dict):
        return set()
    ev: set[str] = set()
    props = schema.get("properties") or {}
    ev |= {k for k in props if k in inst}
    for p in (schema.get("patternProperties") or {}):
        ev |= {k for k in inst if _re_search(p, k)}
    if "additionalProperties" in schema:
        ev = set(inst.keys())
    if "$ref" in schema:
        ev |= _eval_props(root, _resolve(root, schema["$ref"]), inst, dialect)
    for sub in schema.get("allOf", []):
        ev |= _eval_props(root, sub, inst, dialect)
    for kw in ("anyOf", "oneOf"):
        for sub in schema.get(kw, []):
            if not _probe(root, sub, inst, dialect):
                ev |= _eval_props(root, sub, inst, dialect)
    if "if" in schema:
        if not _probe(root, schema["if"], inst, dialect):
            ev |= _eval_props(root, schema["if"], inst, dialect)
            if "then" in schema:
                ev |= _eval_props(root, schema["then"], inst, dialect)
        elif "else" in schema:
            ev |= _eval_props(root, schema["else"], inst, dialect)
    return ev


def _eval_items(root: Schema, schema: Schema, inst: list[JValue], dialect: str) -> int:
    """Count of leading items of `inst` considered evaluated (for unevaluatedItems)."""
    if not isinstance(schema, dict):
        return 0
    n = 0
    pre = schema.get("prefixItems")
    if pre is None and dialect == "draft7" and isinstance(schema.get("items"), list):
        pre = schema["items"]
    if isinstance(pre, list):
        n = min(len(pre), len(inst))
    rest = schema.get("items")
    if rest is not None and not isinstance(rest, list):
        n = len(inst)
    if dialect == "draft7" and isinstance(schema.get("items"), list) \
            and schema.get("additionalItems") is not None:
        n = len(inst)
    if "$ref" in schema:
        n = max(n, _eval_items(root, _resolve(root, schema["$ref"]), inst, dialect))
    for sub in schema.get("allOf", []):
        n = max(n, _eval_items(root, sub, inst, dialect))
    for kw in ("anyOf", "oneOf"):
        for sub in schema.get(kw, []):
            if not _probe(root, sub, inst, dialect):
                n = max(n, _eval_items(root, sub, inst, dialect))
    if "if" in schema:
        if not _probe(root, schema["if"], inst, dialect):
            n = max(n, _eval_items(root, schema["if"], inst, dialect))
            if "then" in schema:
                n = max(n, _eval_items(root, schema["then"], inst, dialect))
        elif "else" in schema:
            n = max(n, _eval_items(root, schema["else"], inst, dialect))
    return n


def _validate_object(root: Schema, schema: Schema, inst: dict[str, JValue],
                     ip: list[str], errors: list[tuple[str, str]], dialect: str) -> None:
    here = _ptr(ip)
    props = schema.get("properties") or {}
    pat_props = schema.get("patternProperties") or {}
    addl = schema.get("additionalProperties")
    assert isinstance(props, dict) and isinstance(pat_props, dict)

    for key, val in inst.items():
        covered = key in props
        if key in props:
            _validate(root, props[key], val, ip + [key], errors, dialect)
        for pat, sub in pat_props.items():
            if _re_search(pat, key):
                covered = True
                _validate(root, sub, val, ip + [key], errors, dialect)
        if not covered and addl is not None:
            if addl is False:
                errors.append((_ptr(ip + [key]), "additionalProperties: not allowed"))
            elif addl is not True:
                _validate(root, addl, val, ip + [key], errors, dialect)

    for req in schema.get("required") or []:
        if req not in inst:
            errors.append((here, f"required: missing property {req!r}"))
    if "propertyNames" in schema:
        for key in inst:
            if _probe(root, schema["propertyNames"], key, dialect):
                errors.append((_ptr(ip + [key]), "propertyNames: invalid property name"))
    if "minProperties" in schema and len(inst) < _num(schema["minProperties"]):
        errors.append((here, "minProperties not met"))
    if "maxProperties" in schema and len(inst) > _num(schema["maxProperties"]):
        errors.append((here, "maxProperties exceeded"))

    dep_req = schema.get("dependentRequired") or {}
    if dialect == "draft7":
        for k, v in (schema.get("dependencies") or {}).items():
            if isinstance(v, list):
                dep_req = {**dep_req, k: v}
    for k, reqs in dep_req.items():
        if k in inst:
            for r in reqs:
                if r not in inst:
                    errors.append((here, f"dependentRequired: {k!r} needs {r!r}"))
    dep_sch = dict(schema.get("dependentSchemas") or {})
    if dialect == "draft7":
        for k, v in (schema.get("dependencies") or {}).items():
            if not isinstance(v, list):
                dep_sch[k] = v
    for k, sub in dep_sch.items():
        if k in inst:
            _validate(root, sub, inst, ip, errors, dialect)

    if "unevaluatedProperties" in schema:
        ev = _eval_props(root, schema, inst, dialect)
        up = schema["unevaluatedProperties"]
        for k in inst:
            if k not in ev:
                if up is False:
                    errors.append((_ptr(ip + [k]), "unevaluatedProperties: not allowed"))
                elif up is not True:
                    _validate(root, up, inst[k], ip + [k], errors, dialect)


def _dialect(schema: Schema) -> str:
    if isinstance(schema, dict):
        sid = schema.get("$schema")
        if isinstance(sid, str) and "draft-07" in sid:
            return "draft7"
    return "2020-12"


def validate_jsonschema(schema_raw: bytes, instance_raw: bytes, *,
                        encoding: str | None = None,
                        assert_format: bool = False) -> list[Issue]:
    global _ASSERT_FORMAT, _ANCHORS
    schema = loads(decode_bytes(schema_raw, encoding))
    inst = loads(decode_bytes(instance_raw, encoding))
    errors: list[tuple[str, str]] = []
    _ASSERT_FORMAT = assert_format
    _ANCHORS = {}
    _collect_anchors(schema, _ANCHORS)
    try:
        _validate(schema, schema, inst, [], errors, _dialect(schema))
    finally:
        _ASSERT_FORMAT = False
        _ANCHORS = {}
    return [Issue(p or "(root)", "schema", m) for p, m in errors]
