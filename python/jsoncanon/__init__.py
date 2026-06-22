"""jsoncanon — canonical JSON normalizer (see SPEC.md)."""

from __future__ import annotations

from typing import Any

from .parser import (
    JValue, loads, load_ndjson, load_stream, parse_force, decode_bytes,
    JSONError, Number, NonFinite,
)
from .lint import _line_col
from .serializer import dumps, collect_jcs_warnings, diff_values
from .numbers import canon_number
from .lint import lint, ijson, Issue
from .cbor import encode_cbor, decode_cbor
from .msgpack import encode_msgpack, decode_msgpack
from .jdata import decode_jdata
from .jsonpointer import get_pointer

_BIN_DECODERS = {"cbor": decode_cbor, "msgpack": decode_msgpack}
_BIN_ENCODERS = {"cbor": encode_cbor, "msgpack": encode_msgpack}

__version__ = "0.1.0"

__all__ = [
    "canonicalize", "encode_output", "from_pandas", "lint", "ijson", "diff",
    "encode_cbor", "decode_cbor", "dumps", "loads", "load_ndjson",
    "canon_number", "decode_bytes",
    "JValue", "JSONError", "Number", "NonFinite", "Issue", "__version__",
]

# output encoding name -> (python codec, BOM bytes)
_OUT_ENC = {
    "utf-8": ("utf-8", b"\xef\xbb\xbf"),
    "utf-16-le": ("utf-16-le", b"\xff\xfe"),
    "utf-16-be": ("utf-16-be", b"\xfe\xff"),
    "utf-32-le": ("utf-32-le", b"\xff\xfe\x00\x00"),
    "utf-32-be": ("utf-32-be", b"\x00\x00\xfe\xff"),
    "latin-1": ("latin-1", b""),
}


def diff(a: bytes | str, b: bytes | str, *, encoding: str | None = None,
         strict_dupes: bool = False, jcs: bool = False) -> list[str]:
    """Structural diff of two inputs after canonicalization. Empty == identical."""
    ta = a if isinstance(a, str) else decode_bytes(bytes(a), encoding)
    tb = b if isinstance(b, str) else decode_bytes(bytes(b), encoding)
    va = loads(ta, strict_dupes=strict_dupes)
    vb = loads(tb, strict_dupes=strict_dupes)
    return diff_values(va, vb, jcs=jcs)


def encode_output(text: str, output_encoding: str = "utf-8",
                  bom: bool = False) -> bytes:
    try:
        codec, bom_bytes = _OUT_ENC[output_encoding]
    except KeyError:
        raise JSONError(f"unsupported output encoding: {output_encoding}") from None
    prefix = bom_bytes if bom else b""
    return prefix + text.encode(codec)


def canonicalize(
    data: bytes | bytearray | str,
    *,
    encoding: str | None = None,
    ndjson: bool = False,
    strict_dupes: bool = False,
    preserve_number_type: bool = False,
    nan: str = "error",
    number_format: str = "plain",
    jcs: bool = False,
    newline: bool = False,
    output_encoding: str = "utf-8",
    bom: bool = False,
    warnings: list[str] | None = None,
    json_seq: bool = False,
    input_format: str = "json",
    output_format: str = "json",
    force: bool = False,
    force_warnings: list[str] | None = None,
    transform: Any = None,
) -> bytes:
    """Bytes/str/file-content in → canonical bytes out (UTF-8 by default).

    ``input_format``/``output_format`` may be "json" or "cbor" (RFC 8949
    deterministic). CBOR is single-value (no ndjson/json-seq); CBOR output is
    binary and ignores ``--output-encoding``. When ``jcs`` is set and
    ``warnings`` is a list, value-changing numbers (SPEC.md §5) are appended."""
    warn = jcs and warnings is not None
    xf = transform if transform is not None else (lambda v: v)

    def one(v: JValue, prefix: str = "") -> str:
        if warn:
            assert warnings is not None
            collect_jcs_warnings(v, prefix, warnings)
        return dumps(v, preserve_number_type=preserve_number_type, nan=nan,
                     number_format=number_format, jcs=jcs)

    def parse_one(t: str) -> JValue:
        if not force:
            return loads(t, strict_dupes=strict_dupes)
        v, ws = parse_force(t, strict_dupes=strict_dupes)
        if force_warnings is not None:
            for pos, _cat, msg in ws:
                line, col = _line_col(t, pos)
                force_warnings.append(f"{line}:{col}  {msg}")
        return v

    if input_format in _BIN_DECODERS:
        value = xf(_BIN_DECODERS[input_format](
            bytes(data) if not isinstance(data, str) else data.encode("latin-1")))
        if output_format in _BIN_ENCODERS:
            return _BIN_ENCODERS[output_format](value, nan=nan)
        out = one(value)
        if newline:
            out += "\n"
        return encode_output(out, output_encoding, bom)

    text = data if isinstance(data, str) else decode_bytes(bytes(data), encoding)

    if input_format == "jdata":
        value = xf(decode_jdata(loads(text, strict_dupes=strict_dupes)))
        if output_format in _BIN_ENCODERS:
            return _BIN_ENCODERS[output_format](value, nan=nan)
        out = one(value)
        if newline:
            out += "\n"
        return encode_output(out, output_encoding, bom)

    if output_format in _BIN_ENCODERS:
        return _BIN_ENCODERS[output_format](xf(parse_one(text)), nan=nan)

    if json_seq and not force:
        out = "\n".join(
            one(v, f"value {i}")
            for i, v in enumerate(load_stream(text, strict_dupes=strict_dupes), 1))
    elif ndjson or json_seq:
        lines = [ln for ln in text.splitlines() if ln.strip() != ""]
        out = "\n".join(one(parse_one(ln), f"line {i}") for i, ln in enumerate(lines, 1))
    else:
        out = one(xf(parse_one(text)))
    if newline:
        out += "\n"
    return encode_output(out, output_encoding, bom)


def from_pandas(df_or_obj: Any, **kwargs: Any) -> bytes:
    """Canonicalize a pandas DataFrame/Series (via its to_json) or any object
    that json.dumps can handle. Routes through text so the same number rules
    apply — pandas '4.0' floats collapse to '4' by default.

    For richer integration, prefer the registered accessor in
    ``jsoncanon.pandas_accessor`` (``df.jsoncanon.to_canonical()``)."""
    import json
    if hasattr(df_or_obj, "to_json"):
        text: str = df_or_obj.to_json()
    else:
        text = json.dumps(df_or_obj)
    return canonicalize(text, **kwargs)
