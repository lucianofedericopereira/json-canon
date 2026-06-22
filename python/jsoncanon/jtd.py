"""JSON Type Definition (RFC 8927) validator.

Validates a JSON instance against a JTD schema, producing the standard error
indicators (instancePath / schemaPath) from RFC 8927 §3.3.2, rendered as JSON
Pointers. Implements all eight forms (empty, ref, type, enum, elements,
properties, values, discriminator) plus `nullable` and root `definitions`.
The schema is assumed to be a valid JTD schema.

Deterministic: errors are produced in a fixed depth-first order, so the Nim port
emits an identical list.
"""

from __future__ import annotations

import re

from .lint import Issue
from .numbers import canon_number
from .parser import JValue, Number, decode_bytes, loads, JSONError

_RFC3339 = re.compile(
    r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$")

_INT_RANGES = {
    "int8": (-128, 127), "uint8": (0, 255),
    "int16": (-32768, 32767), "uint16": (0, 65535),
    "int32": (-2147483648, 2147483647), "uint32": (0, 4294967295),
}


def _is_int_in(num: Number, lo: int, hi: int) -> bool:
    plain = canon_number(num.text, number_format="plain")
    if "." in plain:
        return False
    return lo <= int(plain) <= hi


def _check_type(t: str, inst: JValue) -> bool:
    if t == "boolean":
        return inst is True or inst is False
    if t == "string":
        return isinstance(inst, str)
    if t == "timestamp":
        return isinstance(inst, str) and bool(_RFC3339.match(inst))
    if t in ("float32", "float64"):
        return isinstance(inst, Number)
    if t in _INT_RANGES:
        return isinstance(inst, Number) and _is_int_in(inst, *_INT_RANGES[t])
    return False


def _ptr(tokens: list[str]) -> str:
    return "".join("/" + t.replace("~", "~0").replace("/", "~1") for t in tokens)


def _validate(root: JValue, schema: JValue, inst: JValue,
              errors: list[tuple[list[str], list[str]]],
              ip: list[str], sp: list[str], parent_tag: str | None = None) -> None:
    assert isinstance(schema, dict)
    if schema.get("nullable") is True and inst is None:
        return

    if "ref" in schema:
        name = schema["ref"]
        assert isinstance(name, str) and isinstance(root, dict)
        defs = root.get("definitions")
        assert isinstance(defs, dict)
        if name not in defs:
            raise JSONError(f"JTD: unknown definition {name!r}")
        _validate(root, defs[name], inst, errors, ip, ["definitions", name])
    elif "type" in schema:
        t = schema["type"]
        assert isinstance(t, str)
        if not _check_type(t, inst):
            errors.append((ip, sp + ["type"]))
    elif "enum" in schema:
        choices = schema["enum"]
        assert isinstance(choices, list)
        if not (isinstance(inst, str) and inst in choices):
            errors.append((ip, sp + ["enum"]))
    elif "elements" in schema:
        if isinstance(inst, list):
            for i, e in enumerate(inst):
                _validate(root, schema["elements"], e, errors,
                          ip + [str(i)], sp + ["elements"])
        else:
            errors.append((ip, sp + ["elements"]))
    elif "properties" in schema or "optionalProperties" in schema:
        if isinstance(inst, dict):
            props = schema.get("properties") or {}
            opts = schema.get("optionalProperties") or {}
            assert isinstance(props, dict) and isinstance(opts, dict)
            for k in props:
                if k in inst:
                    _validate(root, props[k], inst[k], errors,
                              ip + [k], sp + ["properties", k])
                else:
                    errors.append((ip, sp + ["properties", k]))
            for k in opts:
                if k in inst:
                    _validate(root, opts[k], inst[k], errors,
                              ip + [k], sp + ["optionalProperties", k])
            if schema.get("additionalProperties") is not True:
                for k in inst:
                    if k not in props and k not in opts and k != parent_tag:
                        errors.append((ip + [k], sp))
        else:
            errors.append((ip, sp + (["properties"] if "properties" in schema
                                     else ["optionalProperties"])))
    elif "values" in schema:
        if isinstance(inst, dict):
            for k, v in inst.items():
                _validate(root, schema["values"], v, errors,
                          ip + [k], sp + ["values"])
        else:
            errors.append((ip, sp + ["values"]))
    elif "discriminator" in schema:
        tag = schema["discriminator"]
        assert isinstance(tag, str)
        if isinstance(inst, dict):
            if tag in inst:
                tv = inst[tag]
                mapping = schema["mapping"]
                assert isinstance(mapping, dict)
                if isinstance(tv, str) and tv in mapping:
                    _validate(root, mapping[tv], inst, errors, ip,
                              sp + ["mapping", tv], parent_tag=tag)
                else:
                    errors.append((ip + [tag], sp + ["mapping"]))
            else:
                errors.append((ip, sp + ["discriminator"]))
        else:
            errors.append((ip, sp + ["discriminator"]))
    # empty form (and metadata-only): always valid


def validate_jtd(schema_raw: bytes, instance_raw: bytes, *,
                 encoding: str | None = None) -> list[Issue]:
    schema = loads(decode_bytes(schema_raw, encoding))
    inst = loads(decode_bytes(instance_raw, encoding))
    errors: list[tuple[list[str], list[str]]] = []
    _validate(schema, schema, inst, errors, [], [])
    return [Issue(_ptr(ip) or "(root)", "jtd", "schema " + (_ptr(spp) or "(root)"))
            for ip, spp in errors]
