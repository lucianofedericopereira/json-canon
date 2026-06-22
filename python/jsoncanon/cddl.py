"""CDDL (RFC 8610) validator — a practical subset.

Validates a JSON instance against a CDDL schema, starting from the first rule.
Supported: type rules (`name = type`), type choices (`a / b`), primitive types
(bool, int, uint, nint, float/float16/32/64, number, tstr/text, bstr/bytes, any,
null/nil), literals (numbers, `"text"`, true/false), numeric ranges (`1..10`),
arrays `[ ... ]` and maps `{ ... }` with occurrence indicators (`?`, `*`, `+`,
`n*m`), and references to other rules.

Out of scope (documented): groups/sockets/generics, control operators (`.size`,
`.regexp`, …), tags, unwrapping, and recursive types. Array matching is greedy
(no backtracking), which covers the common shapes. Errors are reported as
(path, message) with a fixed depth-first order, so the Nim port is identical.
"""

from __future__ import annotations

from typing import Any

from .lint import Issue
from .numbers import canon_number
from .parser import JValue, Number, decode_bytes, loads, JSONError

Ast = Any  # CDDL AST node: heterogeneous tuples like ("choice", [...]) etc.

_PRIMS = {"bool", "int", "uint", "nint", "float", "float16", "float32",
          "float64", "number", "tstr", "text", "bstr", "bytes", "any"}


# --- tokenizer -------------------------------------------------------------

def _tokens(src: str) -> list[tuple[str, str]]:
    toks: list[tuple[str, str]] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
        elif c == ";":
            while i < n and src[i] != "\n":
                i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n and src[j] != '"':
                if src[j] == "\\" and j + 1 < n:
                    buf.append(src[j + 1])
                    j += 2
                    continue
                buf.append(src[j])
                j += 1
            toks.append(("str", "".join(buf)))
            i = j + 1
        elif src[i:i + 2] in ("..", "=>"):
            toks.append(("op", src[i:i + 2]))
            i += 2
        elif c in "={}[]:,?*+/()":
            toks.append(("op", c))
            i += 1
        elif c.isdigit() or (c == "-" and i + 1 < n and src[i + 1].isdigit()):
            j = i + 1
            while j < n and (src[j].isdigit() or src[j] in ".eExX+-abcdefABCDEF"):
                if src[j] == "." and j + 1 < n and src[j + 1] == ".":
                    break
                j += 1
            toks.append(("num", src[i:j]))
            i = j
        elif c.isalpha() or c in "_$":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in "_-.$@"):
                j += 1
            toks.append(("id", src[i:j]))
            i = j
        else:
            raise JSONError(f"CDDL: unexpected character {c!r}")
    return toks


# --- parser ----------------------------------------------------------------

# AST nodes are tuples: ("choice",[...]) ("ref",name) ("prim",name)
# ("lit",(kind,val)) ("range",lo,hi) ("arr",[(occ,type)]) ("map",[(occ,key,type)])

class _P:
    def __init__(self, toks: list[tuple[str, str]]) -> None:
        self.t = toks
        self.i = 0

    def peek(self, k: int = 0) -> tuple[str, str]:
        j = self.i + k
        return self.t[j] if j < len(self.t) else ("eof", "")

    def nxt(self) -> tuple[str, str]:
        tk = self.peek()
        self.i += 1
        return tk

    def eat(self, tok: tuple[str, str]) -> None:
        if self.nxt() != tok:
            raise JSONError(f"CDDL: expected {tok[1]!r}")


def _occur(p: _P) -> tuple[int, int | None]:
    tk = p.peek()
    if tk == ("op", "?"):
        p.nxt(); return (0, 1)
    if tk == ("op", "*"):
        p.nxt(); return (0, None)
    if tk == ("op", "+"):
        p.nxt(); return (1, None)
    if tk[0] == "num" and p.peek(1) == ("op", "*"):
        lo = int(tk[1])
        p.nxt(); p.nxt()
        hi: int | None = None
        if p.peek()[0] == "num":
            hi = int(p.nxt()[1])
        return (lo, hi)
    return (1, 1)


def _type1(p: _P) -> Ast:
    tk = p.peek()
    if tk == ("op", "{"):
        return _map(p)
    if tk == ("op", "["):
        return _array(p)
    if tk == ("op", "("):
        p.nxt()
        t = _type(p)
        p.eat(("op", ")"))
        return t
    if tk[0] == "str":
        p.nxt(); return ("lit", ("str", tk[1]))
    if tk[0] == "num":
        p.nxt()
        if p.peek() == ("op", ".."):
            p.nxt()
            hi = p.nxt()
            return ("range", tk[1], hi[1])
        return ("lit", ("num", tk[1]))
    if tk[0] == "id":
        p.nxt()
        name = tk[1]
        if name in ("true", "false"):
            return ("lit", ("bool", name == "true"))
        if name in ("null", "nil"):
            return ("prim", "null")
        return ("ref", name)
    raise JSONError(f"CDDL: unexpected token {tk[1]!r}")


def _type(p: _P) -> Ast:
    alts = [_type1(p)]
    while p.peek() == ("op", "/"):
        p.nxt()
        alts.append(_type1(p))
    return ("choice", alts) if len(alts) > 1 else alts[0]


def _array(p: _P) -> Ast:
    p.eat(("op", "["))
    entries = []
    while p.peek() != ("op", "]"):
        occ = _occur(p)
        entries.append((occ, _type(p)))
        if p.peek() == ("op", ","):
            p.nxt()
    p.eat(("op", "]"))
    return ("arr", entries)


def _map(p: _P) -> Ast:
    p.eat(("op", "{"))
    members = []
    while p.peek() != ("op", "}"):
        occ = _occur(p)
        key = p.nxt()
        if key[0] not in ("id", "str"):
            raise JSONError("CDDL: expected map member key")
        if p.peek() in (("op", ":"), ("op", "=>")):
            p.nxt()
        else:
            raise JSONError("CDDL: expected ':' in map member")
        members.append((occ, key[1], _type(p)))
        if p.peek() == ("op", ","):
            p.nxt()
    p.eat(("op", "}"))
    return ("map", members)


def parse_cddl(src: str) -> tuple[dict[str, Ast], list[str]]:
    p = _P(_tokens(src))
    rules: dict[str, Ast] = {}
    order: list[str] = []
    while p.peek()[0] != "eof":
        nm = p.nxt()
        if nm[0] != "id":
            raise JSONError("CDDL: expected rule name")
        p.eat(("op", "="))
        rules[nm[1]] = _type(p)
        if nm[1] not in order:
            order.append(nm[1])
    return rules, order


# --- validator -------------------------------------------------------------

def _is_int(num: Number) -> bool:
    return "." not in canon_number(num.text, number_format="plain")


def _num_val(num: Number) -> float:
    return float(canon_number(num.text, number_format="plain"))


def _prim_match(name: str, inst: JValue) -> bool:
    if name == "bool":
        return inst is True or inst is False
    if name in ("tstr", "text", "bstr", "bytes"):
        return isinstance(inst, str)
    if name == "any":
        return True
    if name in ("float", "float16", "float32", "float64", "number"):
        return isinstance(inst, Number)
    if name == "int":
        return isinstance(inst, Number) and _is_int(inst)
    if name == "uint":
        return isinstance(inst, Number) and _is_int(inst) and _num_val(inst) >= 0
    if name == "nint":
        return isinstance(inst, Number) and _is_int(inst) and _num_val(inst) < 0
    return False


def _describe(rules: dict[str, Ast], ast: Ast) -> str:
    tag = ast[0]
    if tag == "choice":
        return " / ".join(_describe(rules, a) for a in ast[1])
    if tag in ("ref", "prim"):
        return str(ast[1])
    if tag == "lit":
        k, v = ast[1]
        return ('"' + v + '"') if k == "str" else ("true" if (k == "bool" and v) else
                                                   "false" if k == "bool" else str(v))
    if tag == "range":
        return str(ast[1]) + ".." + str(ast[2])
    if tag == "arr":
        return "[...]"
    if tag == "map":
        return "{...}"
    return "?"


def _matches(rules: dict[str, Ast], ast: Ast, inst: JValue,
             path: str, errors: list[tuple[str, str]]) -> bool:
    tag = ast[0]
    if tag == "choice":
        for alt in ast[1]:
            if _matches(rules, alt, inst, path, []):
                return True
        errors.append((path, "expected " + _describe(rules, ast)))
        return False
    if tag == "ref":
        name = ast[1]
        if name in _PRIMS:
            if not _prim_match(name, inst):
                errors.append((path, "expected " + name))
                return False
            return True
        if name in rules:
            return _matches(rules, rules[name], inst, path, errors)
        raise JSONError(f"CDDL: unknown type {name!r}")
    if tag == "prim":  # null
        if inst is not None:
            errors.append((path, "expected null"))
            return False
        return True
    if tag == "lit":
        k, v = ast[1]
        if k == "str":
            ok = isinstance(inst, str) and inst == v
        elif k == "bool":
            ok = inst is v
        else:
            ok = isinstance(inst, Number) and canon_number(inst.text) == canon_number(v)
        if not ok:
            errors.append((path, "expected " + _describe(rules, ast)))
        return ok
    if tag == "range":
        ok = isinstance(inst, Number) and _num_val(Number(ast[1])) <= _num_val(inst) <= _num_val(Number(ast[2]))
        if not ok:
            errors.append((path, "expected " + ast[1] + ".." + ast[2]))
        return ok
    if tag == "arr":
        return _match_array(rules, ast[1], inst, path, errors)
    if tag == "map":
        return _match_map(rules, ast[1], inst, path, errors)
    raise JSONError(f"CDDL: bad AST {tag}")


def _match_array(rules: dict[str, Ast], entries: list[Any], inst: JValue,
                 path: str, errors: list[tuple[str, str]]) -> bool:
    if not isinstance(inst, list):
        errors.append((path, "expected array"))
        return False
    idx = 0
    for (lo, hi), t in entries:
        count = 0
        while (hi is None or count < hi) and idx < len(inst) \
                and _matches(rules, t, inst[idx], f"{path}[{idx}]", []):
            idx += 1
            count += 1
        if count < lo:
            errors.append((f"{path}[{idx}]" if idx < len(inst) else path,
                           "expected " + _describe(rules, t)))
            return False
    if idx != len(inst):
        errors.append((f"{path}[{idx}]", "unexpected extra array element"))
        return False
    return True


def _match_map(rules: dict[str, Ast], members: list[Any], inst: JValue,
               path: str, errors: list[tuple[str, str]]) -> bool:
    if not isinstance(inst, dict):
        errors.append((path, "expected object"))
        return False
    ok = True
    declared = {m[1] for m in members}
    for (lo, _hi), key, vt in members:
        if key in inst:
            if not _matches(rules, vt, inst[key], f"{path}.{key}", errors):
                ok = False
        elif lo >= 1:
            errors.append((path, f"missing required member {key!r}"))
            ok = False
    for k in inst:
        if k not in declared:
            errors.append((f"{path}.{k}", "unexpected member"))
            ok = False
    return ok


def validate_cddl(schema_raw: bytes, instance_raw: bytes, *,
                  encoding: str | None = None) -> list[Issue]:
    rules, order = parse_cddl(decode_bytes(schema_raw, encoding))
    if not order:
        raise JSONError("CDDL: no rules in schema")
    inst = loads(decode_bytes(instance_raw, encoding))
    errors: list[tuple[str, str]] = []
    _matches(rules, rules[order[0]], inst, "$", errors)
    return [Issue(p, "cddl", m) for p, m in errors]
