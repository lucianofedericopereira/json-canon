## Pure-Nim port of Ulf Adams' Ryu `d2s` — shortest round-tripping decimal for
## an IEEE-754 binary64, plus the ECMAScript `Number.prototype.toString`
## formatting that RFC 8785 (JCS) mandates for JSON numbers.
##
## Reference: https://github.com/ulfjack/ryu (d2s.c, common.h, d2s_intrinsics.h).
## The two 128-bit power-of-five tables live in `ryu_tables.nim`, regenerated
## by tools/gen_ryu_tables.py. Validated byte-for-byte against CPython's
## `repr(float)` (same shortest/closest/ties-to-even contract) — see the tests.
##
## All arithmetic is unsigned 64-bit (Nim wraps `uint64` modulo 2^64, matching C).

import ./ryu_tables

const
  DOUBLE_MANTISSA_BITS = 52
  DOUBLE_EXPONENT_BITS = 11
  DOUBLE_BIAS = 1023

type
  FloatingDecimal64 = object
    mantissa: uint64   ## decimal significand
    exponent: int32    ## value == mantissa * 10^exponent

# ---------------------------------------------------------------------------
# intrinsics (d2s_intrinsics.h)
# ---------------------------------------------------------------------------

proc umul128(a, b: uint64, productHi: var uint64): uint64 =
  ## 64x64 -> 128 multiply. Returns the low 64 bits; high 64 in productHi.
  let aLo = a and 0xFFFFFFFF'u64
  let aHi = a shr 32
  let bLo = b and 0xFFFFFFFF'u64
  let bHi = b shr 32
  let b00 = aLo * bLo
  let b01 = aLo * bHi
  let b10 = aHi * bLo
  let b11 = aHi * bHi
  let b00Hi = b00 shr 32
  let mid1 = b10 + b00Hi
  let mid1Lo = mid1 and 0xFFFFFFFF'u64
  let mid1Hi = mid1 shr 32
  let mid2 = b01 + mid1Lo
  let mid2Lo = mid2 and 0xFFFFFFFF'u64
  let mid2Hi = mid2 shr 32
  productHi = b11 + mid1Hi + mid2Hi
  (mid2Lo shl 32) or (b00 and 0xFFFFFFFF'u64)

proc shiftright128(lo, hi: uint64, dist: uint32): uint64 =
  ## Requires 0 < dist < 64 (guaranteed by the d2d call sites).
  (hi shl (64'u32 - dist)) or (lo shr dist)

proc mulShift64(m: uint64, mul: array[2, uint64], j: int32): uint64 =
  var high1: uint64
  let low1 = umul128(m, mul[1], high1)
  var high0: uint64
  discard umul128(m, mul[0], high0)
  let sum = high0 + low1
  if sum < high0: inc high1            # carry into the high limb
  shiftright128(sum, high1, uint32(j - 64))

proc mulShiftAll64(m: uint64, mul: array[2, uint64], j: int32,
                   vp, vm: var uint64, mmShift: uint32): uint64 =
  vp = mulShift64(4'u64 * m + 2, mul, j)
  vm = mulShift64(4'u64 * m - 1 - mmShift, mul, j)
  mulShift64(4'u64 * m, mul, j)

# ---------------------------------------------------------------------------
# common.h helpers
# ---------------------------------------------------------------------------

proc log10Pow2(e: int32): uint32 =
  ## floor(e * log10(2)), valid for e in [0, 1650].
  (uint32(e) * 78913'u32) shr 18

proc log10Pow5(e: int32): uint32 =
  ## floor(e * log10(5)), valid for e in [0, 2620].
  (uint32(e) * 732923'u32) shr 20

proc pow5bitsI(e: int32): int32 =
  ## ceil(log2(5^e)) == floor(e*log2 5)+1, valid for e in [0, 3528].
  int32(((uint32(e) * 1217359'u32) shr 19) + 1)

proc pow5Factor(value: uint64): uint32 =
  var v = value
  result = 0
  while true:
    let q = v div 5
    let r = v - 5'u64 * q
    if r != 0: break
    v = q
    inc result

proc multipleOfPowerOf5(value: uint64, p: uint32): bool =
  pow5Factor(value) >= p

proc multipleOfPowerOf2(value: uint64, p: uint32): bool =
  (value and ((1'u64 shl p) - 1)) == 0

# ---------------------------------------------------------------------------
# d2d — the shortest-decimal core (d2s.c)
# ---------------------------------------------------------------------------

proc d2d(ieeeMantissa: uint64, ieeeExponent: uint32): FloatingDecimal64 =
  var e2: int32
  var m2: uint64
  if ieeeExponent == 0:
    e2 = 1 - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS - 2
    m2 = ieeeMantissa
  else:
    e2 = int32(ieeeExponent) - DOUBLE_BIAS - DOUBLE_MANTISSA_BITS - 2
    m2 = (1'u64 shl DOUBLE_MANTISSA_BITS) or ieeeMantissa
  let even = (m2 and 1) == 0
  let acceptBounds = even

  let mv = 4'u64 * m2
  let mmShift = uint32(if ieeeMantissa != 0 or ieeeExponent <= 1: 1 else: 0)

  var vr, vp, vm: uint64
  var e10: int32
  var vmIsTrailingZeros = false
  var vrIsTrailingZeros = false

  if e2 >= 0:
    let q = log10Pow2(e2) - (if e2 > 3: 1'u32 else: 0'u32)
    e10 = int32(q)
    let k = DOUBLE_POW5_INV_BITCOUNT + pow5bitsI(int32(q)) - 1
    let i = -e2 + int32(q) + k
    vr = mulShiftAll64(m2, DOUBLE_POW5_INV_SPLIT[q], i, vp, vm, mmShift)
    if q <= 21:
      if mv - 5'u64 * (mv div 5) == 0:            # mv % 5 == 0
        vrIsTrailingZeros = multipleOfPowerOf5(mv, q)
      elif acceptBounds:
        vmIsTrailingZeros = multipleOfPowerOf5(mv - 1 - mmShift, q)
      else:
        vp -= (if multipleOfPowerOf5(mv + 2, q): 1'u64 else: 0'u64)
  else:
    let q = log10Pow5(-e2) - (if -e2 > 1: 1'u32 else: 0'u32)
    e10 = int32(q) + e2
    let i = -e2 - int32(q)
    let k = pow5bitsI(i) - DOUBLE_POW5_BITCOUNT
    let j = int32(q) - k
    vr = mulShiftAll64(m2, DOUBLE_POW5_SPLIT[i], j, vp, vm, mmShift)
    if q <= 1:
      vrIsTrailingZeros = true
      if acceptBounds:
        vmIsTrailingZeros = mmShift == 1
      else:
        dec vp
    elif q < 63:
      vrIsTrailingZeros = multipleOfPowerOf2(mv, q)

  # Step 4: shortest decimal representation in [vm, vp].
  var removed: int32 = 0
  var lastRemovedDigit: uint8 = 0
  var output: uint64

  if vmIsTrailingZeros or vrIsTrailingZeros:
    # General (rare) case.
    while true:
      let vpDiv10 = vp div 10
      let vmDiv10 = vm div 10
      if vpDiv10 <= vmDiv10: break
      let vmMod10 = vm - 10'u64 * vmDiv10
      let vrDiv10 = vr div 10
      let vrMod10 = vr - 10'u64 * vrDiv10
      vmIsTrailingZeros = vmIsTrailingZeros and vmMod10 == 0
      vrIsTrailingZeros = vrIsTrailingZeros and lastRemovedDigit == 0
      lastRemovedDigit = uint8(vrMod10)
      vr = vrDiv10; vp = vpDiv10; vm = vmDiv10
      inc removed
    if vmIsTrailingZeros:
      while true:
        let vmDiv10 = vm div 10
        let vmMod10 = vm - 10'u64 * vmDiv10
        if vmMod10 != 0: break
        let vpDiv10 = vp div 10
        let vrDiv10 = vr div 10
        let vrMod10 = vr - 10'u64 * vrDiv10
        vrIsTrailingZeros = vrIsTrailingZeros and lastRemovedDigit == 0
        lastRemovedDigit = uint8(vrMod10)
        vr = vrDiv10; vp = vpDiv10; vm = vmDiv10
        inc removed
    if vrIsTrailingZeros and lastRemovedDigit == 5 and (vr and 1) == 0:
      lastRemovedDigit = 4              # round to even
    output = vr + (if (vr == vm and (not acceptBounds or not vmIsTrailingZeros)) or
                      lastRemovedDigit >= 5: 1'u64 else: 0'u64)
  else:
    # Common (~99.3%) case.
    var roundUp = false
    let vpDiv100 = vp div 100
    let vmDiv100 = vm div 100
    if vpDiv100 > vmDiv100:             # remove two digits at a time
      let vrDiv100 = vr div 100
      let vrMod100 = vr - 100'u64 * vrDiv100
      roundUp = vrMod100 >= 50
      vr = vrDiv100; vp = vpDiv100; vm = vmDiv100
      removed += 2
    while true:
      let vpDiv10 = vp div 10
      let vmDiv10 = vm div 10
      if vpDiv10 <= vmDiv10: break
      let vrDiv10 = vr div 10
      let vrMod10 = vr - 10'u64 * vrDiv10
      roundUp = vrMod10 >= 5
      vr = vrDiv10; vp = vpDiv10; vm = vmDiv10
      inc removed
    output = vr + (if vr == vm or roundUp: 1'u64 else: 0'u64)

  FloatingDecimal64(mantissa: output, exponent: e10 + removed)

# ---------------------------------------------------------------------------
# ECMAScript Number::toString (ES2017 §7.1.12.1 / RFC 8785 §3.2.2.3)
# ---------------------------------------------------------------------------

proc repeat0(n: int): string =
  for _ in 0 ..< n: result.add '0'

proc ecmaFormat(neg: bool, digits: string, n: int): string =
  ## `digits` is the trailing-zero-free significand; the value is
  ## digits * 10^(n - len(digits)), i.e. the decimal point sits after the
  ## n-th significant digit. Implements the k/n case split.
  let k = digits.len
  let sign = if neg: "-" else: ""
  if k <= n and n <= 21:
    return sign & digits & repeat0(n - k)
  if 0 < n and n <= 21:
    return sign & digits[0 ..< n] & "." & digits[n ..< k]
  if -6 < n and n <= 0:
    return sign & "0." & repeat0(-n) & digits
  # exponential: one digit, optional fraction, e±(n-1)
  let mant = if k == 1: digits else: digits[0 ..< 1] & "." & digits[1 ..< k]
  let e = n - 1
  let esign = if e >= 0: "+" else: "-"
  sign & mant & "e" & esign & $abs(e)

proc ecmaScriptNumberToString*(f: float64): string =
  ## RFC 8785 number serialization: the exact string JavaScript's
  ## `String(f)` produces. `f` must be finite (NaN/Infinity have no JSON form
  ## and are handled by the caller's NaN policy).
  let bits = cast[uint64](f)
  let neg = (bits shr (DOUBLE_MANTISSA_BITS + DOUBLE_EXPONENT_BITS)) != 0
  let ieeeMantissa = bits and ((1'u64 shl DOUBLE_MANTISSA_BITS) - 1)
  let ieeeExponent = uint32((bits shr DOUBLE_MANTISSA_BITS) and
                            ((1'u64 shl DOUBLE_EXPONENT_BITS) - 1))

  # Zero (and -0) -> "0".
  if ieeeExponent == 0 and ieeeMantissa == 0:
    return "0"

  let fd = d2d(ieeeMantissa, ieeeExponent)
  var digits = $fd.mantissa
  var exp = int(fd.exponent)
  # Strip trailing zeros so `digits` is the minimal significand (n is invariant).
  var endi = digits.len
  while endi > 1 and digits[endi - 1] == '0':
    dec endi
    inc exp
  digits = digits[0 ..< endi]
  let n = exp + digits.len
  ecmaFormat(neg, digits, n)
