import std/unittest
import ../src/jsoncanon

proc c(s: string, opts = Options(), ndjson = false): string =
  canonicalize(s, opts, "", ndjson)

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

  test "json5 hex":
    check c("{a:0xFF, b:-0x10, c:+0x1}") == "{\"a\":255,\"b\":-16,\"c\":1}"
    check c("{big:0xFFFFFFFFFFFFFFFFFFFFFFFFFF}") ==
          "{\"big\":20282409603651670423947251286015}"

  test "json5 escapes":
    check c("{s:\"a\\x42c\"}") == "{\"s\":\"aBc\"}"
    check c("{s:\"x\\\ny\"}") == "{\"s\":\"xy\"}"
    check c("{v:\"\\v\",z:\"\\0\"}") == "{\"v\":\"\\u000b\",\"z\":\"\\u0000\"}"

  test "lint":
    let issues = lint("{'b':1,'a':4.0,}")
    var cats: seq[string]
    for it in issues: cats.add it.category
    check "single-quote" in cats
    check "trailing-comma" in cats
    check "key-order" in cats
    check "number" in cats
    check lint("{\"a\":1,\"b\":2}").len == 0
