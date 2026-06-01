"""jsoncanon — canonical JSON normalizer (see SPEC.md)."""

from __future__ import annotations

from typing import Any

from .parser import (
    JValue, loads, load_ndjson, decode_bytes, JSONError, Number, NonFinite,
)
from .serializer import dumps
from .numbers import canon_number
from .lint import lint, Issue

__version__ = "0.1.0"

__all__ = [
    "canonicalize", "encode_output", "from_pandas", "lint", "dumps", "loads",
    "load_ndjson", "canon_number", "decode_bytes",
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
    newline: bool = False,
    output_encoding: str = "utf-8",
    bom: bool = False,
) -> bytes:
    """Bytes/str/file-content in → canonical bytes out (UTF-8 by default)."""
    if isinstance(data, str):
        text = data
    else:
        text = decode_bytes(bytes(data), encoding)

    def one(v: JValue) -> str:
        return dumps(v, preserve_number_type=preserve_number_type, nan=nan,
                     number_format=number_format)

    if ndjson:
        out = "\n".join(one(v) for v in load_ndjson(text, strict_dupes=strict_dupes))
    else:
        out = one(loads(text, strict_dupes=strict_dupes))
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
