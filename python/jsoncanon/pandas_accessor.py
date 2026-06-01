"""pandas integration via the official accessor API.

Importing this module registers a ``.jsoncanon`` accessor on DataFrame and
Series (https://pandas.pydata.org/docs/development/extending.html), so you can
canonicalize pandas data with the same number/encoding rules as the rest of the
library::

    import pandas as pd
    import jsoncanon.pandas_accessor          # registers the accessor

    df = pd.DataFrame({"a": [1, 2], "b": [4.0, 5.0]})
    df.jsoncanon.to_canonical()               # -> deterministic canonical bytes
    df.jsoncanon.sha256()                     # -> content hash (stable across orient/dtype)

The accessor always serializes through a *fixed* internal orient, so two frames
holding the same data hash equal regardless of column order or int-vs-float
dtype (pandas' ``4.0`` collapses to ``4``; see SPEC.md §2.3).
"""

from __future__ import annotations

import hashlib
from typing import Any

import pandas as pd

from . import canonicalize

# Fixed orient used for canonicalization. "columns" => {col: {index: value}},
# whose keys our serializer sorts, so column/row *ordering* never affects output.
_ORIENT = "columns"


def _canon(obj: Any, **opts: Any) -> bytes:
    # date_format="iso" makes timestamps deterministic text rather than
    # platform-dependent epoch units; default_handler stringifies the exotic.
    text: str = obj.to_json(orient=_ORIENT, date_format="iso", default_handler=str)
    return canonicalize(text, **opts)


@pd.api.extensions.register_dataframe_accessor("jsoncanon")
class JsonCanonDataFrameAccessor:
    def __init__(self, pandas_obj: Any) -> None:
        self._obj = pandas_obj

    def to_canonical(self, **opts: Any) -> bytes:
        """Canonical JSON bytes for this DataFrame (see canonicalize() flags)."""
        return _canon(self._obj, **opts)

    def to_canonical_str(self, **opts: Any) -> str:
        return self.to_canonical(**opts).decode("utf-8")

    def sha256(self, **opts: Any) -> str:
        """Hex SHA-256 of the canonical bytes — a stable content fingerprint."""
        return hashlib.sha256(self.to_canonical(**opts)).hexdigest()


@pd.api.extensions.register_series_accessor("jsoncanon")
class JsonCanonSeriesAccessor:
    def __init__(self, pandas_obj: Any) -> None:
        self._obj = pandas_obj

    def to_canonical(self, **opts: Any) -> bytes:
        return _canon(self._obj, **opts)

    def to_canonical_str(self, **opts: Any) -> str:
        return self.to_canonical(**opts).decode("utf-8")

    def sha256(self, **opts: Any) -> str:
        return hashlib.sha256(self.to_canonical(**opts)).hexdigest()
