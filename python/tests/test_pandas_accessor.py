"""Tests for the pandas accessor (skipped when pandas isn't installed)."""

import pytest

pd = pytest.importorskip("pandas")
import jsoncanon.pandas_accessor  # noqa: E402,F401  (registers the accessor)


def test_int_float_and_column_order_collapse():
    # Same data, different dtype + column order -> identical canonical bytes.
    df1 = pd.DataFrame({"price": [4, 10], "qty": [2, 3]})          # int64
    df2 = pd.DataFrame({"qty": [2.0, 3.0], "price": [4.0, 10.0]})  # float64, swapped
    assert df1.jsoncanon.to_canonical() == df2.jsoncanon.to_canonical()
    assert df1.jsoncanon.sha256() == df2.jsoncanon.sha256()


def test_canonical_output_is_strict_json():
    df = pd.DataFrame({"b": [1], "a": [2.0]})
    assert df.jsoncanon.to_canonical_str() == '{"a":{"0":2},"b":{"0":1}}'


def test_nan_becomes_null():
    df = pd.DataFrame({"x": [1.5, None]})
    assert df.jsoncanon.to_canonical_str() == '{"x":{"0":1.5,"1":null}}'


def test_options_pass_through():
    s = pd.Series([1e21, 0.1], name="v")
    assert s.jsoncanon.to_canonical_str(number_format="auto") == '{"0":1e+21,"1":0.1}'


def test_series_accessor():
    s = pd.Series([3, 1, 2])
    assert s.jsoncanon.to_canonical_str() == '{"0":3,"1":1,"2":2}'


def test_sha256_is_hex():
    df = pd.DataFrame({"a": [1]})
    h = df.jsoncanon.sha256()
    assert len(h) == 64 and all(c in "0123456789abcdef" for c in h)
