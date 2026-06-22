#!/usr/bin/env python3
"""Fuzz the Nim Ryu port against node's Number.prototype.toString (the ground
truth for ECMAScript number serialization, == RFC 8785).

Generates N random finite doubles (broad bit-pattern coverage) plus a fixed set
of hard edge cases, feeds their bit patterns to the compiled ryu_filter, and
compares every line to node's String(x). Exits non-zero on any mismatch.

    python3 tools/fuzz_ryu.py [N]
"""
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FILTER = os.path.join(ROOT, "nim", "tests", "ryu_filter")

N = int(sys.argv[1]) if len(sys.argv) > 1 else 2_000_000
rng = random.Random(0xC0FFEE)


def bits_to_double(b: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def double_to_bits(d: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", d))[0]


def is_finite(b: int) -> bool:
    return ((b >> 52) & 0x7FF) != 0x7FF


HARD = [
    0.0, -0.0, 1.0, -1.0, 9999999999999998.0, 1e21, 1e-7, 1e20, 1e-6,
    5e-324, 1.7976931348623157e308, 2.2250738585072014e-308, 4.9e-324,
    0.1, 0.2, 0.3, 0.5, 1.5, 100.0, 1234567890.0, 9007199254740992.0,
    9007199254740993.0, 123456789012345680.0, 3.141592653589793,
    2.718281828459045, 1e100, 1e-100, 6.022e23, 1.1, 1.2,
    8.98846567431158e307, 2.000000000000002,
]


def gen_bits() -> int:
    k = rng.random()
    if k < 0.35:
        return rng.getrandbits(64)
    if k < 0.6:
        sign = rng.getrandbits(1) << 63
        return sign | (rng.randint(1000, 1046) << 52) | rng.getrandbits(52)
    if k < 0.8:
        v = rng.randint(1, 10 ** rng.randint(1, 17))
        return double_to_bits(v / (10 ** rng.randint(0, 17)))
    sign = rng.getrandbits(1) << 63
    if rng.random() < 0.5:
        return sign | rng.getrandbits(52)
    return sign | (rng.randint(1, 2046) << 52) | rng.getrandbits(52)


def node_batch(hex_lines: list[str]) -> list[str]:
    script = (
        "const hs=require('fs').readFileSync(0,'utf8').trim().split('\\n');"
        "const dv=new DataView(new ArrayBuffer(8));"
        "const out=hs.map(h=>{dv.setBigUint64(0,BigInt('0x'+h));"
        "return String(dv.getFloat64(0));});"
        "process.stdout.write(out.join('\\n'));"
    )
    r = subprocess.run(["node", "-e", script], input="\n".join(hex_lines),
                       capture_output=True, text=True, check=True)
    return r.stdout.split("\n")


def main() -> None:
    samples = [double_to_bits(d) for d in HARD]
    while len(samples) < N:
        b = gen_bits()
        if is_finite(b):
            samples.append(b)

    hex_lines = [f"{b:016x}" for b in samples]
    nim = subprocess.run([FILTER], input="\n".join(hex_lines) + "\n",
                        capture_output=True, text=True, check=True).stdout.splitlines()
    node = node_batch(hex_lines)
    assert len(nim) == len(node) == len(samples), (len(nim), len(node), len(samples))

    mismatches = 0
    for h, g, w in zip(hex_lines, nim, node):
        if g != w:
            mismatches += 1
            print(f"MISMATCH bits={h}  nim={g!r}  node={w!r}")
            if mismatches >= 20:
                break
    if mismatches:
        sys.exit(f"\n{mismatches} mismatch(es) out of {len(samples)}")
    print(f"OK: {len(samples)} doubles match node exactly")


if __name__ == "__main__":
    main()
