"""Canonical serializer (see SPEC.md §2)."""

from __future__ import annotations

from .numbers import canon_number
from .parser import JValue, Number, NonFinite, JSONError

_ESCAPES = {
    '"': '\\"', "\\": "\\\\",
    "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r",
}


def _enc_string(s: str) -> str:
    out = ['"']
    for ch in s:
        e = _ESCAPES.get(ch)
        if e is not None:
            out.append(e)
        elif ch < "\x20":
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


class Serializer:
    def __init__(self, *, preserve_number_type: bool = False, nan: str = "error",
                 number_format: str = "plain") -> None:
        self.preserve = preserve_number_type
        self.nan = nan
        self.number_format = number_format

    def dumps(self, val: JValue) -> str:
        out: list[str] = []
        self._write(val, out, "")
        return "".join(out)

    def _write(self, val: JValue, out: list[str], path: str) -> None:
        if val is True:
            out.append("true")
        elif val is False:
            out.append("false")
        elif val is None:
            out.append("null")
        elif isinstance(val, Number):
            out.append(canon_number(val.text, self.preserve, self.number_format))
        elif isinstance(val, NonFinite):
            out.append(self._nonfinite(val, path))
        elif isinstance(val, str):
            out.append(_enc_string(val))
        elif isinstance(val, list):
            out.append("[")
            for i, item in enumerate(val):
                if i:
                    out.append(",")
                self._write(item, out, f"{path}[{i}]")
            out.append("]")
        elif isinstance(val, dict):
            out.append("{")
            for i, key in enumerate(sorted(val.keys())):
                if i:
                    out.append(",")
                out.append(_enc_string(key))
                out.append(":")
                self._write(val[key], out, f"{path}.{key}")
            out.append("}")
        else:
            raise JSONError(f"cannot serialize {type(val).__name__} at {path or '<root>'}")

    def _nonfinite(self, val: NonFinite, path: str) -> str:
        if self.nan == "null":
            return "null"
        if self.nan == "string":
            return {"nan": '"NaN"', "inf": '"Infinity"', "-inf": '"-Infinity"'}[val.kind]
        raise JSONError(
            f"non-finite number ({val.kind}) at {path or '<root>'}; "
            f"choose a policy with --nan=null|string"
        )


def dumps(val: JValue, *, preserve_number_type: bool = False, nan: str = "error",
          number_format: str = "plain") -> str:
    return Serializer(preserve_number_type=preserve_number_type, nan=nan,
                      number_format=number_format).dumps(val)
