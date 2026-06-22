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


def test_json5_unicode_and_escaped_keys():
    import pytest
    from jsoncanon import JSONError
    assert c("{café: 1, π: 2, 中文: 3}") == '{"café":1,"π":2,"中文":3}'
    bsl = "\\"  # a single backslash, to embed literal \uXXXX escapes
    assert c("{" + bsl + "u0061bc: 1}") == '{"abc":1}'                  # escaped -> abc
    assert c("{x" + bsl + "u0303: 1}") == '{"x̃":1}'              # escaped combining mark
    assert c("{caf" + bsl + "u00e9: 1, café: 2}") == '{"café":2}'      # escaped == raw, last wins
    with pytest.raises(JSONError):                          # astral emoji not an ID start
        c("{😀: 1}")


def test_json5_hex():
    assert c("{a:0xFF, b:-0x10, c:+0x1}") == '{"a":255,"b":-16,"c":1}'
    assert c("{big:0xFFFFFFFFFFFFFFFFFFFFFFFFFF}") == \
        '{"big":20282409603651670423947251286015}'


def test_json5_escapes():
    assert c('{s:"a\\x42c"}') == '{"s":"aBc"}'        # \x41 hex escape
    assert c('{s:"x\\\ny"}') == '{"s":"xy"}'           # line continuation
    assert c('{v:"\\v",z:"\\0"}') == '{"v":"\\u000b","z":"\\u0000"}'


def test_jcs_numbers_ryu():
    from jsoncanon.ecma import ecmascript_number_to_string as es
    assert es(0.0) == "0"
    assert es(-0.0) == "0"
    assert es(12.5) == "12.5"
    assert es(1e21) == "1e+21"
    assert es(1e20) == "100000000000000000000"
    assert es(1e-7) == "1e-7"
    assert es(5e-324) == "5e-324"
    assert es(1.7976931348623157e308) == "1.7976931348623157e+308"
    assert es(333333333.33333329) == "333333333.3333333"
    # RFC 8785 Appendix B number vector.
    assert c("[333333333.33333329, 1E30, 4.50, 2e-3, 1e-27]", jcs=True) == \
        "[333333333.3333333,1e+30,4.5,0.002,1e-27]"
    assert c("[4.0, 4, 1e21, -0.0]", jcs=True) == "[4,4,1e+21,0]"


def test_jcs_utf16_key_sort():
    # code-point order is €, ￿, 😀; UTF-16 puts the astral key (leading
    # surrogate U+D83D < U+FFFF) before the max-BMP key.
    assert c('{"€":1,"￿":2,"\U0001F600":3}', jcs=True) == \
        '{"€":1,"\U0001F600":3,"￿":2}'


def test_jcs_precision_warnings():
    warns: list[str] = []
    canonicalize("[9007199254740993, 1e400, 0.1, 4.0]", jcs=True, nan="null",
                 warnings=warns)
    assert len(warns) == 2                       # only the two lossy values
    assert "9007199254740993 → 9007199254740992" in warns[0]
    assert "exceeds binary64 range" in warns[1]
    # exact values produce no warnings
    clean: list[str] = []
    canonicalize("[0.1, 4.0, 1e21, 1e-7]", jcs=True, warnings=clean)
    assert clean == []
    # warnings only collected in jcs mode
    off: list[str] = []
    canonicalize("[9007199254740993]", jcs=False, warnings=off)
    assert off == []


def test_json_seq_stream():
    def s(x):
        return canonicalize(x, json_seq=True).decode()
    assert s("\x1e{\"b\":1,\"a\":2}\n\x1e[3,4]\n") == '{"a":2,"b":1}\n[3,4]'
    assert s('{"a":1}{"b":2} 3') == '{"a":1}\n{"b":2}\n3'
    assert s("4.0 1e3") == "4\n1000"
    assert s("   ") == ""


def test_json_pointer():
    from jsoncanon import loads, dumps
    from jsoncanon.jsonpointer import get_pointer
    from jsoncanon import JSONError
    import pytest
    d = loads('{"a":{"b":[10,20]},"x/y":1,"m~n":2,"":7}')
    assert dumps(get_pointer(d, "/a/b/1")) == "20"
    assert dumps(get_pointer(d, "/x~1y")) == "1"
    assert dumps(get_pointer(d, "/m~0n")) == "2"
    assert dumps(get_pointer(d, "/")) == "7"
    assert dumps(get_pointer(d, "")) == dumps(d)
    with pytest.raises(JSONError):
        get_pointer(d, "/nope")


def test_json_patch_and_merge():
    from jsoncanon import loads, dumps, JSONError
    from jsoncanon.jsonpatch import apply_patch, apply_merge_patch
    import pytest
    d = loads('{"a":{"b":[1,2,3]},"x":5}')

    def p(patch):
        return dumps(apply_patch(d, loads(patch)))

    assert p('[{"op":"add","path":"/a/b/1","value":9}]') == '{"a":{"b":[1,9,2,3]},"x":5}'
    assert p('[{"op":"remove","path":"/x"}]') == '{"a":{"b":[1,2,3]}}'
    assert p('[{"op":"move","from":"/x","path":"/a/m"}]') == '{"a":{"b":[1,2,3],"m":5}}'
    assert p('[{"op":"copy","from":"/x","path":"/y"}]') == '{"a":{"b":[1,2,3]},"x":5,"y":5}'
    with pytest.raises(JSONError):
        p('[{"op":"test","path":"/x","value":9}]')
    assert dumps(apply_merge_patch(d, loads('{"x":null,"a":{"c":2}}'))) == '{"a":{"b":[1,2,3],"c":2}}'
    assert dumps(apply_merge_patch(d, loads("[9]"))) == "[9]"


def test_force_salvage():
    from jsoncanon import canonicalize
    from jsoncanon.parser import parse_force

    def f(s):
        return canonicalize(s, force=True).decode()

    assert f('{"a":1, "b": , "c":3}') == '{"a":1,"c":3}'
    assert f("[1, oops, 3]") == "[1,3]"
    assert f('{"a":1} junk') == '{"a":1}'
    assert f("[1,2,3") == "[1,2,3]"
    assert f('{"a":[1,{"x":}]}') == '{"a":[1,{}]}'
    assert f("garbage") == "null"
    _, ws = parse_force("[1, bad, 2]")
    assert len(ws) == 1


def test_jsonschema_anchor_and_unevaluated():
    from jsoncanon.jsonschema import validate_jsonschema as V

    def n(s, i):
        return len(V(s.encode(), i.encode()))

    assert n('{"$defs":{"P":{"$anchor":"pos","minimum":0}},"properties":{"n":{"$ref":"#pos"}}}',
             '{"n":-1}') == 1
    assert n('{"properties":{"a":{}},"unevaluatedProperties":false}', '{"a":1,"b":2}') == 1
    assert n('{"allOf":[{"properties":{"a":{}}}],"unevaluatedProperties":false}', '{"a":1,"c":3}') == 1
    assert n('{"prefixItems":[{}],"unevaluatedItems":false}', "[1,2]") == 1
    assert n('{"prefixItems":[{}],"unevaluatedItems":false}', "[1]") == 0


def test_jsonschema_format_assertion():
    from jsoncanon.jsonschema import validate_jsonschema as V

    def fmt(schema, inst):
        return len(V(schema.encode(), inst.encode(), assert_format=True))

    assert fmt('{"format":"date"}', '"2020-01-31"') == 0
    assert fmt('{"format":"date"}', '"2020-13-01"') == 1
    assert fmt('{"format":"ipv4"}', '"256.0.0.1"') == 1
    assert fmt('{"format":"ipv6"}', '"2001:db8::1"') == 0
    assert fmt('{"format":"uuid"}', '"123e4567-e89b-12d3-a456-426614174000"') == 0
    assert fmt('{"format":"email"}', '"a@b.com"') == 0
    assert fmt('{"format":"regex"}', '"["') == 1
    # without assert_format, format is annotation-only
    assert len(V('{"format":"date"}'.encode(), '"bad"'.encode())) == 0


def test_regexlite_engine():
    from jsoncanon._regex import search
    assert search("^[a-z]+$", "abc")
    assert not search("^[a-z]+$", "Ab1")
    assert search(r"\d{2,3}", "x456y")
    assert not search(r"^\d{4}$", "12")
    assert search("(ab)+c", "ababc")
    assert search("colou?r", "color")
    assert not search("[^0-9]+", "123")


def test_jsonschema_validation():
    from jsoncanon.jsonschema import validate_jsonschema as V

    def nerr(s, i):
        return len(V(s.encode(), i.encode()))

    assert nerr('{"type":"integer"}', "1.5") == 1
    assert nerr('{"type":"integer"}', "2.0") == 0
    assert nerr('{"required":["a"]}', '{"b":1}') == 1
    assert nerr('{"type":"string","pattern":"^[a-z]+$"}', '"Ab"') == 1
    assert nerr('{"type":"number","multipleOf":2}', "7") == 1
    assert nerr('{"uniqueItems":true}', "[1,2,2]") == 1
    assert nerr('{"oneOf":[{"type":"integer"},{"type":"string"}]}', "true") == 1
    assert nerr('{"$defs":{"p":{"minimum":0}},"properties":{"n":{"$ref":"#/$defs/p"}}}', '{"n":-1}') == 1
    assert nerr('{"additionalProperties":false,"properties":{"a":true}}', '{"a":1,"b":2}') == 1
    assert nerr('{"if":{"required":["t"]},"then":{"required":["x"]}}', '{"t":1}') == 1


def test_cddl_validation():
    from jsoncanon.cddl import validate_cddl

    def nerr(schema, inst):
        return len(validate_cddl(schema.encode(), inst.encode()))

    assert nerr("person = { name: tstr, age: uint, ? email: tstr }",
                '{"name":"Al","age":30}') == 0
    assert nerr("person = { name: tstr, age: uint }", '{"name":"Al","age":-1}') == 1
    assert nerr("person = { name: tstr }", '{"name":"Al","x":1}') == 1
    assert nerr("root = [* int]", "[1,2,3]") == 0
    assert nerr("root = [int, tstr, * bool]", '[1,"a",true,false]') == 0
    assert nerr("root = int / tstr", "true") == 1
    assert nerr("root = 1..10", "50") == 1
    assert nerr('color = "red" / "green"\nroot = { c: color }', '{"c":"blue"}') == 1


def test_jdata_decode():
    from jsoncanon import canonicalize, JSONError
    import pytest

    def jd(s):
        return canonicalize(s, input_format="jdata").decode()

    assert jd('{"_ArrayType_":"d","_ArraySize_":[2,3],"_ArrayData_":[1,2,3,4,5,6]}') == "[[1,2,3],[4,5,6]]"
    assert jd('{"_ArrayType_":"d","_ArraySize_":4,"_ArrayData_":[1,2,3,4]}') == "[1,2,3,4]"
    assert jd('{"k":1,"m":{"_ArrayType_":"d","_ArraySize_":[2,2],"_ArrayData_":[1,2,3,4]}}') \
        == '{"k":1,"m":[[1,2],[3,4]]}'
    assert jd('{"plain":[1,2,3]}') == '{"plain":[1,2,3]}'
    with pytest.raises(JSONError):
        jd('{"_ArrayType_":"d","_ArraySize_":[2,3],"_ArrayData_":[1,2,3]}')


def test_jtd_validation():
    from jsoncanon.jtd import validate_jtd

    def nerr(schema, inst):
        return len(validate_jtd(schema.encode(), inst.encode()))

    assert nerr('{"type":"string"}', '"hi"') == 0
    assert nerr('{"type":"string"}', "42") == 1
    assert nerr('{"type":"uint8"}', "300") == 1
    assert nerr('{"type":"timestamp"}', '"1985-04-12T23:20:50.52Z"') == 0
    assert nerr('{"enum":["A","B"]}', '"C"') == 1
    assert nerr('{"elements":{"type":"int32"}}', '[1,2,"x"]') == 1
    assert nerr('{"type":"string","nullable":true}', "null") == 0
    assert nerr('{"definitions":{"s":{"type":"string"}},"elements":{"ref":"s"}}', '["a",3]') == 1
    assert nerr('{"discriminator":"t","mapping":{"a":{"properties":{"x":{"type":"string"}}}}}',
                '{"t":"a","x":1}') == 1


def test_cbor_deterministic_encoding():
    from jsoncanon import encode_cbor, decode_cbor, loads, dumps
    assert encode_cbor(loads("0")).hex() == "00"
    assert encode_cbor(loads("-1000")).hex() == "3903e7"
    assert encode_cbor(loads("1.5")).hex() == "f93e00"          # shortest float = f16
    assert encode_cbor(loads("[1,2,3]")).hex() == "83010203"
    assert encode_cbor(loads("18446744073709551616")).hex() == "c249010000000000000000"
    # §4.2.1 key order: "a" < "z" < "aa" by encoded-key bytes
    assert encode_cbor(loads('{"z":1,"aa":2,"a":3}')).hex() == "a3616103617a01626161" + "02"


def test_msgpack_deterministic():
    from jsoncanon import loads, dumps
    from jsoncanon.msgpack import encode_msgpack, decode_msgpack
    assert encode_msgpack(loads("0")).hex() == "00"
    assert encode_msgpack(loads("-1")).hex() == "ff"
    assert encode_msgpack(loads("255")).hex() == "ccff"
    assert encode_msgpack(loads("[1,2,3]")).hex() == "93010203"
    assert encode_msgpack(loads('{"bb":2,"a":1}')).hex() == "82a16101a2626202"
    for doc in ['{"b":1,"a":2}', "[0.1,1.5,-2.5e-10]", '[true,false,null,"x"]',
                "[127,128,-33,65536,-2147483648]", "[]", "{}"]:
        assert dumps(decode_msgpack(encode_msgpack(loads(doc)))) == dumps(loads(doc))


def test_cbor_round_trip():
    from jsoncanon import encode_cbor, decode_cbor, loads, dumps
    for doc in ['{"b":1,"a":2}', "[0.1,1.5,-2.5e-10,3.14159]",
                "123456789012345678901234567890", "-99999999999999999999",
                '{"z":[true,false,null,"x"]}', "[]", "{}", '"hi"']:
        assert dumps(decode_cbor(encode_cbor(loads(doc)))) == dumps(loads(doc))


def test_diff_after_canonicalization():
    from jsoncanon import diff
    assert diff('{"a":1,"b":2}', '{"b":2,"a":1}') == []   # reorder -> identical
    assert diff('{"n":4.0}', '{"n":4}') == []             # 4.0 == 4 after canon
    assert diff('{"a":1}', '{"a":2}') == ["~ $.a: 1 => 2"]
    assert diff('{"a":1}', '{"a":1,"c":9}') == ["+ $.c: 9"]
    assert diff('{"x":7,"a":1}', '{"a":1}') == ["- $.x: 7"]
    assert diff('[1,2]', '[1,2,3]') == ["+ $[2]: 3"]
    assert diff('{"t":true}', '{"t":1}') == ["~ $.t: true => 1"]  # type change


def test_geojson_conformance():
    from jsoncanon.lint import geojson

    def gcats(raw):
        return {i.category for i in geojson(raw.encode())}

    assert geojson(b'{"type":"Point","coordinates":[100.0,0.5]}') == []
    assert geojson(b'{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}') == []
    assert "geojson-type" in gcats('{"type":"Banana"}')
    assert "geojson-coordinates" in gcats('{"type":"Point","coordinates":[1]}')
    assert "geojson-ring" in gcats('{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1]]]}')
    assert "geojson-winding" in gcats('{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[0,0]]]}')
    assert "geojson-crs" in gcats('{"type":"Point","coordinates":[1,2],"crs":{}}')
    assert "geojson-member" in gcats('{"type":"Feature","geometry":null}')


def test_ijson_conformance():
    from jsoncanon import ijson

    def cats(raw):
        return {i.category for i in ijson(raw.encode())}

    assert ijson(b'{"a":1,"b":[2,3.5]}') == []        # clean I-JSON
    assert ijson(b"[9007199254740991]") == []         # 2^53-1 is fine
    assert "number" in cats("[9007199254740992]")     # 2^53 out of safe range
    assert "number" in cats("[9007199254740993]")     # loses precision
    assert "number" in cats("[1e400]")                # overflow
    assert "duplicate-key" in cats('{"a":1,"a":2}')
    assert "unquoted-key" in cats("{x:1}")            # JSON5, not I-JSON
    assert "non-finite" in cats("[NaN]")


def test_lint():
    from jsoncanon import lint
    issues = lint(b"{'b':1,'a':4.0,}")
    cats = {i.category for i in issues}
    assert "single-quote" in cats
    assert "trailing-comma" in cats
    assert "key-order" in cats
    assert "number" in cats
    assert lint(b'{"a":1,"b":2}') == []  # already canonical
