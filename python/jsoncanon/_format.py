"""Deterministic JSON Schema `format` checks (opt-in via --format).

Hand-written so the Nim port (`format_ok` in jsonschema.nim) is byte-identical;
no locale/library dependencies. Unknown formats pass (annotation only).
"""

from __future__ import annotations

from ._regex import search as _re_search


def _digits(s: str) -> bool:
    return s != "" and all("0" <= c <= "9" for c in s)


def _date(s: str) -> bool:
    if len(s) != 10 or s[4] != "-" or s[7] != "-":
        return False
    if not (_digits(s[0:4]) and _digits(s[5:7]) and _digits(s[8:10])):
        return False
    mo, da = int(s[5:7]), int(s[8:10])
    return 1 <= mo <= 12 and 1 <= da <= 31


def _time(s: str) -> bool:
    # HH:MM:SS(.frac)?(Z|±HH:MM)?
    if len(s) < 8 or s[2] != ":" or s[5] != ":":
        return False
    if not (_digits(s[0:2]) and _digits(s[3:5]) and _digits(s[6:8])):
        return False
    if int(s[0:2]) > 23 or int(s[3:5]) > 59 or int(s[6:8]) > 59:
        return False
    rest = s[8:]
    if rest and rest[0] == ".":
        i = 1
        while i < len(rest) and "0" <= rest[i] <= "9":
            i += 1
        if i == 1:
            return False
        rest = rest[i:]
    if rest == "" or rest in ("Z", "z"):
        return True
    if rest[0] in "+-" and len(rest) == 6 and rest[3] == ":" \
            and _digits(rest[1:3]) and _digits(rest[4:6]):
        return int(rest[1:3]) <= 23 and int(rest[4:6]) <= 59
    return False


def _date_time(s: str) -> bool:
    if len(s) < 11 or s[10] not in "Tt":
        return False
    return _date(s[:10]) and _time(s[11:])


def _ipv4(s: str) -> bool:
    parts = s.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not _digits(p) or len(p) > 3 or (len(p) > 1 and p[0] == "0") or int(p) > 255:
            return False
    return True


def _ipv6(s: str) -> bool:
    if s.count("::") > 1:
        return False
    tail_v4 = False
    head, _, tail = s.partition("::")
    groups_h = head.split(":") if head else []
    groups_t = tail.split(":") if tail else []
    all_groups = groups_h + groups_t
    if all_groups and "." in all_groups[-1]:
        if not _ipv4(all_groups[-1]):
            return False
        tail_v4 = True
        all_groups = all_groups[:-1]
    for g in all_groups:
        if g == "" or len(g) > 4 or not all(c in "0123456789abcdefABCDEF" for c in g):
            return False
    count = len(all_groups) + (2 if tail_v4 else 0)
    if "::" in s:
        return count <= (6 if tail_v4 else 7)
    return count == (6 if tail_v4 else 8)


def _email(s: str) -> bool:
    if s.count("@") != 1:
        return False
    local, _, domain = s.partition("@")
    if local == "" or domain == "":
        return False
    return _hostname(domain) and " " not in local


def _hostname(s: str) -> bool:
    if s == "" or len(s) > 253:
        return False
    labels = s.split(".")
    for lab in labels:
        if lab == "" or len(lab) > 63 or lab[0] == "-" or lab[-1] == "-":
            return False
        if not all(c.isalnum() and c.isascii() or c == "-" for c in lab):
            return False
    return True


def _uuid(s: str) -> bool:
    if len(s) != 36:
        return False
    if [s[8], s[13], s[18], s[23]] != ["-", "-", "-", "-"]:
        return False
    return all(c in "0123456789abcdefABCDEF" for i, c in enumerate(s)
               if i not in (8, 13, 18, 23))


def _uri(s: str) -> bool:
    # require an absolute URI: scheme ":" ...
    i = 0
    if i >= len(s) or not (s[0].isalpha() and s[0].isascii()):
        return False
    i = 1
    while i < len(s) and (s[i].isalnum() and s[i].isascii() or s[i] in "+-."):
        i += 1
    return i < len(s) and s[i] == ":"


def _json_pointer(s: str) -> bool:
    if s == "":
        return True
    if s[0] != "/":
        return False
    # each ~ must be followed by 0 or 1
    i = 0
    while i < len(s):
        if s[i] == "~":
            if i + 1 >= len(s) or s[i + 1] not in "01":
                return False
            i += 1
        i += 1
    return True


def _regex(s: str) -> bool:
    try:
        _re_search(s, "")
        return True
    except Exception:
        return False


_CHECKS = {
    "date-time": _date_time, "date": _date, "time": _time,
    "email": _email, "idn-email": _email,
    "hostname": _hostname, "idn-hostname": _hostname,
    "ipv4": _ipv4, "ipv6": _ipv6,
    "uri": _uri, "iri": _uri, "uri-reference": _uri, "iri-reference": _uri,
    "uuid": _uuid, "json-pointer": _json_pointer, "regex": _regex,
}


def format_ok(name: str, value: str) -> bool:
    """True if `value` satisfies format `name` (unknown formats pass)."""
    check = _CHECKS.get(name)
    return check(value) if check else True
