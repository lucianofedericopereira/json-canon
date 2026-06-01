import jsoncanon
from jsoncanon import canonicalize, canon_number


def c(s, **kw):
    return canonicalize(s, **kw).decode()


def test_numbers_collapse():
    assert canon_number("4.0") == "4"
    assert canon_number("4.50e1") == "45"
    assert canon_number("-0.0") == "0"
    assert canon_number("1e3") == "1000"
    assert canon_number("0.10") == "0.1"
    assert canon_number("+007") == "7"
    assert canon_number("1.5E-3") == "0.0015"
    assert canon_number(".5") == "0.5"
    assert canon_number("5.") == "5"


def test_bigint_lossless():
    big = "123456789012345678901234567890"
    assert canon_number(big) == big


def test_preserve_number_type():
    assert canon_number("4.0", preserve_type=True) == "4.0"
    assert canon_number("4", preserve_type=True) == "4"
    assert canon_number("1e3", preserve_type=True) == "1000.0"


def test_key_sort_and_whitespace():
    assert c('{ "b":1, "a":2 }') == '{"a":2,"b":1}'


def test_python_dialect():
    assert c("{'ok': True, 'no': False, 'x': None,}") == '{"no":false,"ok":true,"x":null}'


def test_unicode_raw():
    assert c('{"u":"caf\\u00e9"}') == '{"u":"café"}'  # é -> raw é


def test_comments():
    assert c('{"a":1 /* c */, // line\n "b":2}') == '{"a":1,"b":2}'


def test_dupe_last_wins():
    assert c('{"a":1,"a":2}') == '{"a":2}'


def test_nan_policies():
    assert c('{"x":NaN}', nan="null") == '{"x":null}'
    assert c('{"x":Infinity}', nan="string") == '{"x":"Infinity"}'


def test_bom_utf8():
    assert canonicalize(b"\xef\xbb\xbf{\"v\":1}") == b'{"v":1}'


def test_ndjson():
    assert c('{"b":1,"a":2}\n{"a":3}', ndjson=True) == '{"a":2,"b":1}\n{"a":3}'


def test_idempotent():
    once = canonicalize('{"b":4.0,"a":[1,2.0,3]}')
    twice = canonicalize(once)
    assert once == twice


def test_number_format_scientific():
    assert canon_number("4", number_format="scientific") == "4e+0"
    assert canon_number("0.1", number_format="scientific") == "1e-1"
    assert canon_number("6.022e23", number_format="scientific") == "6.022e+23"


def test_number_format_auto():
    assert canon_number("1e3", number_format="auto") == "1000"      # in range -> plain
    assert canon_number("1e21", number_format="auto") == "1e+21"    # large -> sci
    assert canon_number("1e-7", number_format="auto") == "1e-7"     # small -> sci
    assert canon_number("1e-6", number_format="auto") == "0.000001"  # boundary -> plain


def test_output_encoding():
    assert canonicalize('{"v":1}', output_encoding="utf-16-le", bom=True) == \
        b"\xff\xfe" + '{"v":1}'.encode("utf-16-le")
    assert canonicalize('{"v":1}', output_encoding="utf-8", bom=True) == \
        b"\xef\xbb\xbf" + b'{"v":1}'


def test_json5_unquoted_keys():
    assert c("{ unquoted: 1, $id: 2, _x: 3 }") == '{"$id":2,"_x":3,"unquoted":1}'


def test_json5_hex():
    assert c("{a:0xFF, b:-0x10, c:+0x1}") == '{"a":255,"b":-16,"c":1}'
    assert c("{big:0xFFFFFFFFFFFFFFFFFFFFFFFFFF}") == \
        '{"big":20282409603651670423947251286015}'


def test_json5_escapes():
    assert c('{s:"a\\x42c"}') == '{"s":"aBc"}'        # \x41 hex escape
    assert c('{s:"x\\\ny"}') == '{"s":"xy"}'           # line continuation
    assert c('{v:"\\v",z:"\\0"}') == '{"v":"\\u000b","z":"\\u0000"}'


def test_lint():
    from jsoncanon import lint
    issues = lint(b"{'b':1,'a':4.0,}")
    cats = {i.category for i in issues}
    assert "single-quote" in cats
    assert "trailing-comma" in cats
    assert "key-order" in cats
    assert "number" in cats
    assert lint(b'{"a":1,"b":2}') == []  # already canonical
