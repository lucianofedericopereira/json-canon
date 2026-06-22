"""JData / NeuroJSON N-dimensional array decoding (uncompressed).

JData encodes an N-D numeric array as an annotated object:

    {"_ArrayType_": "double", "_ArraySize_": [2, 3], "_ArrayData_": [1,2,3,4,5,6]}

`--from jdata` expands every such object into the equivalent nested JSON array
(row-major) — here `[[1,2,3],[4,5,6]]` — then the result is canonicalized
normally. Other JData constructs are passed through untouched. Compressed arrays
(`_ArrayZipData_`) are not supported (they need zlib/lz4 + base64); they raise.
"""

from __future__ import annotations

from .numbers import canon_number
from .parser import JValue, Number, JSONError

_ARRAY_KEYS = ("_ArrayType_", "_ArraySize_", "_ArrayData_")


def _dim(v: JValue) -> int:
    assert isinstance(v, Number)
    return int(canon_number(v.text, number_format="plain"))


def _reshape(data: list[JValue], dims: list[int]) -> JValue:
    if len(dims) == 1:
        return data
    step = 1
    for d in dims[1:]:
        step *= d
    return [_reshape(data[i * step:(i + 1) * step], dims[1:]) for i in range(dims[0])]


def decode_jdata(v: JValue) -> JValue:
    if isinstance(v, dict):
        if "_ArrayZipData_" in v:
            raise JSONError("JData: compressed arrays (_ArrayZipData_) are not supported")
        if all(k in v for k in _ARRAY_KEYS):
            size = v["_ArraySize_"]
            data = v["_ArrayData_"]
            if isinstance(size, list):
                dims = [_dim(x) for x in size]
            elif isinstance(size, Number):
                dims = [_dim(size)]
            else:
                raise JSONError("JData: _ArraySize_ must be a number or array of numbers")
            if not isinstance(data, list):
                raise JSONError("JData: _ArrayData_ must be an array")
            flat = [decode_jdata(e) for e in data]
            prod = 1
            for d in dims:
                prod *= d
            if not dims or prod != len(flat):
                raise JSONError("JData: _ArrayData_ length does not match _ArraySize_")
            return _reshape(flat, dims)
        return {k: decode_jdata(val) for k, val in v.items()}
    if isinstance(v, list):
        return [decode_jdata(e) for e in v]
    return v
