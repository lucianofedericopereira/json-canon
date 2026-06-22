"""Lint mode — report each deviation from canonical form (see README)."""

from __future__ import annotations

import math

from .parser import JValue, Parser, Number, decode_bytes
from .numbers import canon_number
from .ecma import ecmascript_number_to_string

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


# --- I-JSON conformance (RFC 7493) -----------------------------------------
_SAFE_INT = "9007199254740991"  # 2^53 - 1


def _ijson_number(text: str) -> str | None:
    """I-JSON number rule: integers must stay within ±(2^53-1), and every number
    must be exactly representable as a binary64. Returns a message or None."""
    plain = canon_number(text, number_format="plain")
    digits = plain[1:] if plain.startswith("-") else plain
    if "." not in plain and (
            len(digits) > len(_SAFE_INT)
            or (len(digits) == len(_SAFE_INT) and digits > _SAFE_INT)):
        return f"{plain} is an integer outside the I-JSON safe range ±(2^53-1)"
    f = float(plain)
    if math.isinf(f):
        return f"{plain} is outside binary64 range"
    if canon_number(ecmascript_number_to_string(f), number_format="plain") != plain:
        return f"{plain} is not exactly representable as binary64 (loses precision)"
    return None


def _has_lone_surrogate(s: str) -> bool:
    return any(0xD800 <= ord(ch) <= 0xDFFF for ch in s)


def _ijson_walk(node: JValue, path: str, out: list[_Finding]) -> None:
    here = path or "$"
    if isinstance(node, Number):
        msg = _ijson_number(node.text)
        if msg:
            out.append((here, "number", msg))
    elif isinstance(node, str):
        if _has_lone_surrogate(node):
            out.append((here, "surrogate", "string contains an unpaired surrogate"))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            _ijson_walk(item, f"{path}[{i}]", out)
    elif isinstance(node, dict):
        for k, v in node.items():
            if _has_lone_surrogate(k):
                out.append((f"{path}.{k}", "surrogate", "key contains an unpaired surrogate"))
            _ijson_walk(v, f"{path}.{k}", out)


_GEOJSON_TYPES = {"Point", "MultiPoint", "LineString", "MultiLineString",
                  "Polygon", "MultiPolygon", "GeometryCollection",
                  "Feature", "FeatureCollection"}
_GEOMETRY_TYPES = _GEOJSON_TYPES - {"Feature", "FeatureCollection"}


def _gj_num(v: JValue) -> bool:
    return isinstance(v, Number)


def _gj_float(v: Number) -> float:
    return float(canon_number(v.text, number_format="plain"))


def _gj_position(pos: JValue, path: str, out: list[_Finding]) -> bool:
    if not isinstance(pos, list) or len(pos) < 2:
        out.append((path, "geojson-coordinates", "position must have at least two numbers"))
        return False
    ok = True
    for i, c in enumerate(pos):
        if not _gj_num(c):
            out.append((f"{path}[{i}]", "geojson-coordinates", "coordinate is not a number"))
            ok = False
    return ok


def _gj_pos_eq(a: JValue, b: JValue) -> bool:
    if not (isinstance(a, list) and isinstance(b, list) and len(a) == len(b)):
        return False
    return all(isinstance(x, Number) and isinstance(y, Number)
               and canon_number(x.text) == canon_number(y.text) for x, y in zip(a, b))


def _gj_ring_area(ring: list[JValue]) -> float:
    area = 0.0
    for i in range(len(ring) - 1):
        p, q = ring[i], ring[i + 1]
        assert isinstance(p, list) and isinstance(q, list)
        assert isinstance(p[0], Number) and isinstance(p[1], Number)
        assert isinstance(q[0], Number) and isinstance(q[1], Number)
        area += _gj_float(p[0]) * _gj_float(q[1]) - _gj_float(q[0]) * _gj_float(p[1])
    return area / 2


def _gj_polygon(coords: JValue, path: str, out: list[_Finding]) -> None:
    if not isinstance(coords, list):
        out.append((path, "geojson-coordinates", "Polygon coordinates must be an array of rings"))
        return
    for r, ring in enumerate(coords):
        rp = f"{path}[{r}]"
        if not isinstance(ring, list) or len(ring) < 4:
            out.append((rp, "geojson-ring", "linear ring must have at least four positions"))
            continue
        valid = True
        for i, p in enumerate(ring):  # no short-circuit (keep parity with Nim)
            if not _gj_position(p, f"{rp}[{i}]", out):
                valid = False
        if not _gj_pos_eq(ring[0], ring[-1]):
            out.append((rp, "geojson-ring", "linear ring is not closed (first != last position)"))
            continue
        if valid:
            area = _gj_ring_area(ring)
            if r == 0 and area < 0:
                out.append((rp, "geojson-winding", "exterior ring should be counterclockwise (RFC 7946 §3.1.6)"))
            elif r > 0 and area > 0:
                out.append((rp, "geojson-winding", "interior ring (hole) should be clockwise (RFC 7946 §3.1.6)"))


def _gj_geometry(obj: JValue, path: str, out: list[_Finding]) -> None:
    if not isinstance(obj, dict):
        out.append((path, "geojson-type", "geometry must be an object"))
        return
    t = obj.get("type")
    if not isinstance(t, str) or t not in _GEOMETRY_TYPES:
        out.append((path, "geojson-type", "invalid or missing geometry type"))
        return
    if t == "GeometryCollection":
        geoms = obj.get("geometries")
        if not isinstance(geoms, list):
            out.append((path, "geojson-member", "GeometryCollection requires a 'geometries' array"))
        else:
            for i, g in enumerate(geoms):
                _gj_geometry(g, f"{path}.geometries[{i}]", out)
        return
    coords = obj.get("coordinates")
    if coords is None:
        out.append((path, "geojson-member", f"{t} requires a 'coordinates' member"))
        return
    cp = f"{path}.coordinates"
    if t == "Point":
        _gj_position(coords, cp, out)
    elif t in ("MultiPoint", "LineString"):
        if isinstance(coords, list):
            for i, p in enumerate(coords):
                _gj_position(p, f"{cp}[{i}]", out)
            if t == "LineString" and len(coords) < 2:
                out.append((cp, "geojson-coordinates", "LineString needs at least two positions"))
    elif t == "MultiLineString":
        if isinstance(coords, list):
            for i, line in enumerate(coords):
                if isinstance(line, list):
                    for j, p in enumerate(line):
                        _gj_position(p, f"{cp}[{i}][{j}]", out)
    elif t == "Polygon":
        _gj_polygon(coords, cp, out)
    elif t == "MultiPolygon":
        if isinstance(coords, list):
            for i, poly in enumerate(coords):
                _gj_polygon(poly, f"{cp}[{i}]", out)


def _gj_object(obj: JValue, path: str, out: list[_Finding]) -> None:
    here = path or "$"
    if not isinstance(obj, dict):
        out.append((here, "geojson-type", "GeoJSON value must be an object"))
        return
    if "crs" in obj:
        out.append((here, "geojson-crs", "'crs' member was removed in RFC 7946 (assume WGS 84)"))
    if "bbox" in obj:
        bbox = obj["bbox"]
        if not isinstance(bbox, list) or len(bbox) < 4 or len(bbox) % 2 != 0 \
                or not all(_gj_num(x) for x in bbox):
            out.append((f"{here}.bbox", "geojson-bbox", "bbox must be an array of 2*n numbers (n>=2)"))
    t = obj.get("type")
    if not isinstance(t, str) or t not in _GEOJSON_TYPES:
        out.append((here, "geojson-type", "invalid or missing GeoJSON 'type'"))
        return
    if t == "FeatureCollection":
        feats = obj.get("features")
        if not isinstance(feats, list):
            out.append((here, "geojson-member", "FeatureCollection requires a 'features' array"))
        else:
            for i, f in enumerate(feats):
                _gj_object(f, f"{path}.features[{i}]", out)
    elif t == "Feature":
        if "geometry" not in obj:
            out.append((here, "geojson-member", "Feature requires a 'geometry' member (may be null)"))
        elif obj["geometry"] is not None:
            _gj_geometry(obj["geometry"], f"{path}.geometry", out)
        if "properties" not in obj:
            out.append((here, "geojson-member", "Feature requires a 'properties' member (object or null)"))
    else:
        _gj_geometry(obj, path, out)


def geojson(raw: bytes, *, encoding: str | None = None) -> list[Issue]:
    """Return GeoJSON (RFC 7946) conformance violations; empty == conformant."""
    text = decode_bytes(raw, encoding)
    val = Parser(text).parse()
    out: list[_Finding] = []
    _gj_object(val, "$", out)
    return [Issue(p, c, m) for p, c, m in out]


def ijson(raw: bytes, *, encoding: str | None = None) -> list[Issue]:
    """Return I-JSON (RFC 7493) conformance violations; empty == conformant.

    I-JSON is a strict subset of RFC 8259, so any non-JSON lexical feature the
    parser flags (comments, single quotes, NaN, hex, trailing commas, duplicate
    keys, …) is also an I-JSON violation; on top of those we add the semantic
    rules: number range/precision and unpaired surrogates."""
    issues: list[Issue] = []
    for sig, name in ((b"\xef\xbb\xbf", "UTF-8"), (b"\xff\xfe\x00\x00", "UTF-32-LE"),
                      (b"\x00\x00\xfe\xff", "UTF-32-BE"), (b"\xff\xfe", "UTF-16-LE"),
                      (b"\xfe\xff", "UTF-16-BE")):
        if raw.startswith(sig):
            issues.append(Issue("1:1", "bom", f"{name} BOM present (I-JSON requires UTF-8, no BOM)"))
            break

    text = decode_bytes(raw, encoding)
    p = Parser(text, collect_diags=True)
    val = p.parse()
    for pos, category, message in p.diags:
        line, col = _line_col(text, pos)
        issues.append(Issue(f"{line}:{col}", category, message))

    walk: list[_Finding] = []
    _ijson_walk(val, "$", walk)
    for path, category, message in walk:
        issues.append(Issue(path, category, message))
    return issues
