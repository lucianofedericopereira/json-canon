import std/[unittest, strutils]
import ../src/jsoncanon
import ../src/ryu
import ../src/sha256
import ../src/cbor
import ../src/jtd
import ../src/cddl
import ../src/jsonschema
import ../src/regexlite
import ../src/msgpack
import ../src/jsonpointer
import ../src/jsonpatch

proc hex(s: string): string =
  for c in s: result.add toHex(ord(c), 2).toLowerAscii

proc c(s: string, opts = Options(), ndjson = false): string =
  canonicalize(s, opts, "", ndjson)

proc jcs(s: string): string =
  canonicalize(s, Options(jcs: true), "", false)

suite "jsoncanon":
  test "number collapse":
    check canonNumber("4.0") == "4"
    check canonNumber("4.50e1") == "45"
    check canonNumber("-0.0") == "0"
    check canonNumber("1e3") == "1000"
    check canonNumber("0.10") == "0.1"
    check canonNumber("+007") == "7"
    check canonNumber("1.5E-3") == "0.0015"
    check canonNumber(".5") == "0.5"
    check canonNumber("5.") == "5"

  test "bigint lossless":
    check canonNumber("123456789012345678901234567890") ==
          "123456789012345678901234567890"

  test "preserve number type":
    check canonNumber("4.0", true) == "4.0"
    check canonNumber("4", true) == "4"
    check canonNumber("1e3", true) == "1000.0"

  test "sort and whitespace":
    check c("{ \"b\":1, \"a\":2 }") == "{\"a\":2,\"b\":1}"

  test "python dialect":
    check c("{'ok': True, 'no': False, 'x': None,}") ==
          "{\"no\":false,\"ok\":true,\"x\":null}"

  test "unicode raw":
    check c("{\"u\":\"caf\\u00e9\"}") == "{\"u\":\"café\"}"

  test "comments":
    check c("{\"a\":1 /* c */, // line\n \"b\":2}") == "{\"a\":1,\"b\":2}"

  test "dupe last wins":
    check c("{\"a\":1,\"a\":2}") == "{\"a\":2}"

  test "nan policies":
    check c("{\"x\":NaN}", Options(nan: npNull)) == "{\"x\":null}"
    check c("{\"x\":Infinity}", Options(nan: npString)) == "{\"x\":\"Infinity\"}"

  test "bom utf8":
    check canonicalize("\xEF\xBB\xBF{\"v\":1}") == "{\"v\":1}"

  test "ndjson":
    check c("{\"b\":1,\"a\":2}\n{\"a\":3}", ndjson = true) ==
          "{\"a\":2,\"b\":1}\n{\"a\":3}"

  test "idempotent":
    let once = canonicalize("{\"b\":4.0,\"a\":[1,2.0,3]}")
    check canonicalize(once) == once

  test "number-format scientific":
    check canonNumber("4", false, nfScientific) == "4e+0"
    check canonNumber("0.1", false, nfScientific) == "1e-1"
    check canonNumber("6.022e23", false, nfScientific) == "6.022e+23"

  test "number-format auto":
    check canonNumber("1e3", false, nfAuto) == "1000"
    check canonNumber("1e21", false, nfAuto) == "1e+21"
    check canonNumber("1e-7", false, nfAuto) == "1e-7"
    check canonNumber("1e-6", false, nfAuto) == "0.000001"

  test "output encoding":
    check canonicalize("{\"v\":1}", outputEncoding = "utf-8", bom = true) ==
          "\xEF\xBB\xBF{\"v\":1}"
    check canonicalize("{\"v\":1}", outputEncoding = "utf-16-le") ==
          "{\x00\"\x00v\x00\"\x00:\x001\x00}\x00"

  test "json5 unquoted keys":
    check c("{ unquoted: 1, $id: 2, _x: 3 }") == "{\"$id\":2,\"_x\":3,\"unquoted\":1}"

  test "json5 unicode + escaped ident keys":
    check c("{café: 1, π: 2, 中文: 3}") == "{\"café\":1,\"π\":2,\"中文\":3}"
    check c("{\\u0061bc: 1}") == "{\"abc\":1}"              # escaped -> abc
    check c("{x\\u0303: 1}") == "{\"x̃\":1}"                # escaped combining mark
    check c("{caf\\u00e9: 1, café: 2}") == "{\"café\":2}"  # escaped == raw, last wins
    # astral emoji is category So, not an identifier start -> rejected
    expect JsonError: discard c("{😀: 1}")

  test "json5 hex":
    check c("{a:0xFF, b:-0x10, c:+0x1}") == "{\"a\":255,\"b\":-16,\"c\":1}"
    check c("{big:0xFFFFFFFFFFFFFFFFFFFFFFFFFF}") ==
          "{\"big\":20282409603651670423947251286015}"

  test "json5 escapes":
    check c("{s:\"a\\x42c\"}") == "{\"s\":\"aBc\"}"
    check c("{s:\"x\\\ny\"}") == "{\"s\":\"xy\"}"
    check c("{v:\"\\v\",z:\"\\0\"}") == "{\"v\":\"\\u000b\",\"z\":\"\\u0000\"}"

  test "ryu ecmascript number formatting":
    # Shortest round-tripping, ECMAScript Number::toString (RFC 8785 §3.2.2.3).
    check ecmaScriptNumberToString(0.0) == "0"
    check ecmaScriptNumberToString(-0.0) == "0"
    check ecmaScriptNumberToString(1.0) == "1"
    check ecmaScriptNumberToString(12.5) == "12.5"
    check ecmaScriptNumberToString(0.1) == "0.1"
    check ecmaScriptNumberToString(1e21) == "1e+21"
    check ecmaScriptNumberToString(1e20) == "100000000000000000000"
    check ecmaScriptNumberToString(1e-6) == "0.000001"
    check ecmaScriptNumberToString(1e-7) == "1e-7"
    check ecmaScriptNumberToString(5e-324) == "5e-324"            # min subnormal
    check ecmaScriptNumberToString(1.7976931348623157e308) == "1.7976931348623157e+308"
    check ecmaScriptNumberToString(333333333.33333329) == "333333333.3333333"
    check ecmaScriptNumberToString(-0.5) == "-0.5"

  test "jcs mode: numbers via Ryu, int/float unified":
    check jcs("[333333333.33333329, 1E30, 4.50, 2e-3, 1e-27]") ==
          "[333333333.3333333,1e+30,4.5,0.002,1e-27]"
    check jcs("[4.0, 4, 1e21, -0.0]") == "[4,4,1e+21,0]"

  test "jcs mode: UTF-16 key sort (astral before max-BMP)":
    # code-point order would be €, ￿, 😀 — UTF-16 puts the astral key first
    # because its leading surrogate (U+D83D) is below U+FFFF.
    check jcs("{\"€\":1,\"￿\":2,\"😀\":3}") ==
          "{\"€\":1,\"😀\":3,\"￿\":2}"

  test "jcs precision warnings":
    var warns: seq[string]
    discard canonicalize("[9007199254740993, 1e400, 0.1, 4.0]",
                         Options(jcs: true, nan: npNull), "", false, false,
                         "utf-8", false, addr warns)
    check warns.len == 2                          # only the two lossy values
    check "9007199254740993 → 9007199254740992" in warns[0]
    check "exceeds binary64 range" in warns[1]
    var clean: seq[string]
    discard canonicalize("[0.1, 4.0, 1e21, 1e-7]", Options(jcs: true), "",
                         false, false, "utf-8", false, addr clean)
    check clean.len == 0

  test "json-seq stream (RFC 7464 / ws-sep / concatenated)":
    proc seqc(s: string): string = canonicalize(s, Options(), "", false, false,
                                                 "utf-8", false, nil, true)
    check seqc("\x1E{\"b\":1,\"a\":2}\n\x1E[3,4]\n") == "{\"a\":2,\"b\":1}\n[3,4]"
    check seqc("{\"a\":1}{\"b\":2} 3") == "{\"a\":1}\n{\"b\":2}\n3"
    check seqc("4.0 1e3") == "4\n1000"
    check seqc("   ") == ""

  test "json pointer (RFC 6901)":
    let d = parse("{\"a\":{\"b\":[10,20]},\"x/y\":1,\"m~n\":2,\"\":7}")
    check serialize(getPointer(d, "/a/b/1")) == "20"
    check serialize(getPointer(d, "/a")) == "{\"b\":[10,20]}"
    check serialize(getPointer(d, "/x~1y")) == "1"      # ~1 -> /
    check serialize(getPointer(d, "/m~0n")) == "2"      # ~0 -> ~
    check serialize(getPointer(d, "/")) == "7"          # empty-string key
    check serialize(getPointer(d, "")) == serialize(d)  # whole doc
    expect JsonError: discard getPointer(d, "/nope")

  test "json patch + merge patch (RFC 6902/7386)":
    proc patched(doc, patch: string): string = serialize(applyPatch(parse(doc), parse(patch)))
    let d = "{\"a\":{\"b\":[1,2,3]},\"x\":5}"
    check patched(d, "[{\"op\":\"add\",\"path\":\"/a/b/1\",\"value\":9}]") == "{\"a\":{\"b\":[1,9,2,3]},\"x\":5}"
    check patched(d, "[{\"op\":\"remove\",\"path\":\"/x\"}]") == "{\"a\":{\"b\":[1,2,3]}}"
    check patched(d, "[{\"op\":\"replace\",\"path\":\"/a/b/0\",\"value\":\"r\"}]") ==
          "{\"a\":{\"b\":[\"r\",2,3]},\"x\":5}"
    check patched(d, "[{\"op\":\"move\",\"from\":\"/x\",\"path\":\"/a/m\"}]") == "{\"a\":{\"b\":[1,2,3],\"m\":5}}"
    check patched(d, "[{\"op\":\"copy\",\"from\":\"/x\",\"path\":\"/y\"}]") == "{\"a\":{\"b\":[1,2,3]},\"x\":5,\"y\":5}"
    expect JsonError: discard patched(d, "[{\"op\":\"test\",\"path\":\"/x\",\"value\":9}]")
    proc merged(doc, patch: string): string = serialize(applyMergePatch(parse(doc), parse(patch)))
    check merged(d, "{\"x\":null,\"a\":{\"c\":2}}") == "{\"a\":{\"b\":[1,2,3],\"c\":2}}"
    check merged(d, "[9]") == "[9]"   # non-object patch replaces whole

  test "force salvage parsing":
    proc f(s: string): string =
      let (node, _) = parseForce(s)
      serialize(node)
    check f("{\"a\":1, \"b\": , \"c\":3}") == "{\"a\":1,\"c\":3}"   # drop bad member
    check f("[1, oops, 3]") == "[1,3]"                              # drop bad element
    check f("{\"a\":1} junk") == "{\"a\":1}"                        # trailing garbage
    check f("[1,2,3") == "[1,2,3]"                                  # unterminated array
    check f("{\"a\":[1,{\"x\":}]}") == "{\"a\":[1,{}]}"             # nested recovery
    check f("garbage") == "null"                                    # unparseable -> null
    let (_, ws) = parseForce("[1, bad, 2]")
    check ws.len == 1                                               # one recovery note

  test "json schema $anchor + unevaluated*":
    proc nerr(s, i: string): int = validateJsonSchema(s, i).len
    check nerr("{\"$defs\":{\"P\":{\"$anchor\":\"pos\",\"minimum\":0}},\"properties\":{\"n\":{\"$ref\":\"#pos\"}}}",
               "{\"n\":-1}") == 1
    check nerr("{\"properties\":{\"a\":{}},\"unevaluatedProperties\":false}", "{\"a\":1,\"b\":2}") == 1
    check nerr("{\"allOf\":[{\"properties\":{\"a\":{}}}],\"unevaluatedProperties\":false}",
               "{\"a\":1,\"c\":3}") == 1
    check nerr("{\"prefixItems\":[{}],\"unevaluatedItems\":false}", "[1,2]") == 1
    check nerr("{\"prefixItems\":[{}],\"unevaluatedItems\":false}", "[1]") == 0

  test "json schema --format assertion":
    proc fmt(schema, inst: string): int =
      validateJsonSchema(schema, inst, "", true).len
    check fmt("{\"format\":\"date\"}", "\"2020-01-31\"") == 0
    check fmt("{\"format\":\"date\"}", "\"2020-13-01\"") == 1
    check fmt("{\"format\":\"ipv4\"}", "\"256.0.0.1\"") == 1
    check fmt("{\"format\":\"ipv6\"}", "\"2001:db8::1\"") == 0
    check fmt("{\"format\":\"uuid\"}", "\"123e4567-e89b-12d3-a456-426614174000\"") == 0
    check fmt("{\"format\":\"email\"}", "\"a@b.com\"") == 0
    check fmt("{\"format\":\"regex\"}", "\"[\"") == 1
    # without --format, format is annotation-only (not asserted)
    check validateJsonSchema("{\"format\":\"date\"}", "\"bad\"", "", false).len == 0

  test "regexlite subset engine":
    check reSearch("^[a-z]+$", "abc")
    check not reSearch("^[a-z]+$", "Ab1")
    check reSearch(r"\d{2,3}", "x456y")
    check not reSearch(r"^\d{4}$", "12")
    check reSearch("(ab)+c", "ababc")
    check reSearch("a|b|c", "zzcz")
    check reSearch("colou?r", "color")
    check not reSearch("[^0-9]+", "123")

  test "json schema validation (2020-12 / draft-07)":
    proc nerr(s, i: string): int = validateJsonSchema(s, i).len
    check nerr("{\"type\":\"integer\"}", "1.5") == 1
    check nerr("{\"type\":\"integer\"}", "2.0") == 0
    check nerr("{\"required\":[\"a\"]}", "{\"b\":1}") == 1
    check nerr("{\"type\":\"string\",\"pattern\":\"^[a-z]+$\"}", "\"Ab\"") == 1
    check nerr("{\"type\":\"number\",\"multipleOf\":2}", "7") == 1
    check nerr("{\"uniqueItems\":true}", "[1,2,2]") == 1
    check nerr("{\"oneOf\":[{\"type\":\"integer\"},{\"type\":\"string\"}]}", "true") == 1
    check nerr("{\"$defs\":{\"p\":{\"minimum\":0}},\"properties\":{\"n\":{\"$ref\":\"#/$defs/p\"}}}",
               "{\"n\":-1}") == 1
    check nerr("{\"additionalProperties\":false,\"properties\":{\"a\":true}}", "{\"a\":1,\"b\":2}") == 1
    check nerr("{\"if\":{\"required\":[\"t\"]},\"then\":{\"required\":[\"x\"]}}", "{\"t\":1}") == 1

  test "cddl validation (RFC 8610)":
    proc nerr(schema, inst: string): int = validateCddl(schema, inst).len
    check nerr("person = { name: tstr, age: uint, ? email: tstr }",
               "{\"name\":\"Al\",\"age\":30}") == 0
    check nerr("person = { name: tstr, age: uint }", "{\"name\":\"Al\",\"age\":-1}") == 1
    check nerr("person = { name: tstr }", "{\"name\":\"Al\",\"x\":1}") == 1
    check nerr("root = [* int]", "[1,2,3]") == 0
    check nerr("root = [int, tstr, * bool]", "[1,\"a\",true,false]") == 0
    check nerr("root = int / tstr", "true") == 1
    check nerr("root = 1..10", "50") == 1
    check nerr("color = \"red\" / \"green\"\nroot = { c: color }", "{\"c\":\"blue\"}") == 1

  test "jdata N-D array decode (NeuroJSON)":
    proc jd(s: string): string = serialize(decodeJdata(parse(s)))
    check jd("{\"_ArrayType_\":\"d\",\"_ArraySize_\":[2,3],\"_ArrayData_\":[1,2,3,4,5,6]}") ==
          "[[1,2,3],[4,5,6]]"
    check jd("{\"_ArrayType_\":\"d\",\"_ArraySize_\":4,\"_ArrayData_\":[1,2,3,4]}") == "[1,2,3,4]"
    check jd("{\"k\":1,\"m\":{\"_ArrayType_\":\"d\",\"_ArraySize_\":[2,2],\"_ArrayData_\":[1,2,3,4]}}") ==
          "{\"k\":1,\"m\":[[1,2],[3,4]]}"
    check jd("{\"plain\":[1,2,3]}") == "{\"plain\":[1,2,3]}"
    expect JsonError:
      discard jd("{\"_ArrayType_\":\"d\",\"_ArraySize_\":[2,3],\"_ArrayData_\":[1,2,3]}")

  test "jtd validation (RFC 8927)":
    proc nerr(schema, inst: string): int = validateJtd(schema, inst).len
    check nerr("{\"type\":\"string\"}", "\"hi\"") == 0
    check nerr("{\"type\":\"string\"}", "42") == 1
    check nerr("{\"type\":\"uint8\"}", "300") == 1
    check nerr("{\"type\":\"timestamp\"}", "\"1985-04-12T23:20:50.52Z\"") == 0
    check nerr("{\"enum\":[\"A\",\"B\"]}", "\"C\"") == 1
    check nerr("{\"elements\":{\"type\":\"int32\"}}", "[1,2,\"x\"]") == 1
    check nerr("{\"type\":\"string\",\"nullable\":true}", "null") == 0
    check nerr("{\"definitions\":{\"s\":{\"type\":\"string\"}},\"elements\":{\"ref\":\"s\"}}",
               "[\"a\",3]") == 1
    # discriminator: tag allowed in mapping schema, value field checked
    check nerr("{\"discriminator\":\"t\",\"mapping\":{\"a\":{\"properties\":{\"x\":{\"type\":\"string\"}}}}}",
               "{\"t\":\"a\",\"x\":1}") == 1

  test "cbor deterministic encoding (RFC 8949)":
    # RFC 8949 Appendix A vectors (integer-valued numbers stay integers).
    check hex(encodeCbor(parse("0"))) == "00"
    check hex(encodeCbor(parse("-1000"))) == "3903e7"
    check hex(encodeCbor(parse("1.5"))) == "f93e00"          # shortest float = f16
    check hex(encodeCbor(parse("[1,2,3]"))) == "83010203"
    check hex(encodeCbor(parse("false"))) == "f4"
    # bignum beyond 64-bit
    check hex(encodeCbor(parse("18446744073709551616"))) == "c249010000000000000000"
    # map keys sorted by §4.2.1 (bytewise on encoded key): "a"(61) < "z"(7a) < "aa"(6261)
    check hex(encodeCbor(parse("{\"z\":1,\"aa\":2,\"a\":3}"))) ==
          "a3616103617a01626161 02".replace(" ", "")

  test "msgpack deterministic encode + round-trip":
    proc h(n: JNode): string =
      for c in encodeMsgpack(n): result.add toHex(ord(c), 2).toLowerAscii
    check h(parse("0")) == "00"           # positive fixint
    check h(parse("-1")) == "ff"          # negative fixint
    check h(parse("255")) == "ccff"       # uint8
    check h(parse("[1,2,3]")) == "9301020 3".replace(" ", "")
    check h(parse("true")) == "c3"
    # map keys sorted by encoded-key bytes: "a"(a1) < "bb"(a2..)
    check h(parse("{\"bb\":2,\"a\":1}")) == "82a16101a26262 02".replace(" ", "")
    proc rt(s: string): string = serialize(decodeMsgpack(encodeMsgpack(parse(s))))
    for doc in ["{\"b\":1,\"a\":2}", "[0.1,1.5,-2.5e-10]", "[true,false,null,\"x\"]",
                "[127,128,-33,65536,-2147483648]", "[]", "{}"]:
      check rt(doc) == serialize(parse(doc))

  test "cbor round-trip (--from after --to)":
    proc rt(s: string): string = serialize(decodeCbor(encodeCbor(parse(s))))
    for doc in ["{\"b\":1,\"a\":2}", "[0.1,1.5,-2.5e-10,3.14159]",
                "123456789012345678901234567890", "-99999999999999999999",
                "{\"z\":[true,false,null,\"x\"]}", "[]", "{}", "\"hi\""]:
      check rt(doc) == serialize(parse(doc))

  test "sha256 known vectors":
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("{}") ==
      "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"

  test "diff after canonicalization":
    check diff("{\"a\":1,\"b\":2}", "{\"b\":2,\"a\":1}").len == 0   # reorder
    check diff("{\"n\":4.0}", "{\"n\":4}").len == 0                  # 4.0 == 4
    check diff("{\"a\":1}", "{\"a\":2}") == @["~ $.a: 1 => 2"]
    check diff("{\"a\":1}", "{\"a\":1,\"c\":9}") == @["+ $.c: 9"]
    check diff("{\"x\":7,\"a\":1}", "{\"a\":1}") == @["- $.x: 7"]
    check diff("[1,2]", "[1,2,3]") == @["+ $[2]: 3"]

  test "geojson conformance (RFC 7946)":
    proc gcats(raw: string): seq[string] =
      for it in geojson(raw): result.add it.category
    check geojson("{\"type\":\"Point\",\"coordinates\":[100.0,0.5]}").len == 0
    check geojson("{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1],[0,0]]]}").len == 0
    check "geojson-type" in gcats("{\"type\":\"Banana\"}")
    check "geojson-coordinates" in gcats("{\"type\":\"Point\",\"coordinates\":[1]}")
    check "geojson-ring" in gcats("{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1]]]}")
    check "geojson-winding" in gcats("{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[0,1],[1,1],[0,0]]]}")
    check "geojson-crs" in gcats("{\"type\":\"Point\",\"coordinates\":[1,2],\"crs\":{}}")
    check "geojson-member" in gcats("{\"type\":\"Feature\",\"geometry\":null}")

  test "ijson conformance (RFC 7493)":
    proc cats(raw: string): seq[string] =
      for it in ijson(raw): result.add it.category
    check ijson("{\"a\":1,\"b\":[2,3.5]}").len == 0       # clean I-JSON
    check ijson("[9007199254740991]").len == 0            # 2^53-1 is fine
    check "number" in cats("[9007199254740992]")          # 2^53 out of safe range
    check "number" in cats("[9007199254740993]")          # loses precision
    check "number" in cats("[1e400]")                     # overflow
    check "duplicate-key" in cats("{\"a\":1,\"a\":2}")
    check "unquoted-key" in cats("{x:1}")                 # JSON5, not I-JSON
    check "non-finite" in cats("[NaN]")

  test "lint":
    let issues = lint("{'b':1,'a':4.0,}")
    var cats: seq[string]
    for it in issues: cats.add it.category
    check "single-quote" in cats
    check "trailing-comma" in cats
    check "key-order" in cats
    check "number" in cats
    check lint("{\"a\":1,\"b\":2}").len == 0
