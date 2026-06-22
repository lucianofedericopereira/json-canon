#!/usr/bin/env python3
"""Cross-language JCS parity: feed the SAME number tokens through the Nim CLI and
the Python CLI in --jcs mode and assert byte-identical output. This specifically
exercises the decimal-string -> double parse on both sides (Nim parseFloat vs
Python float), beyond the formatting fuzz in fuzz_ryu.py.

    python3 tools/parity_jcs.py [N]
"""

import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NIM = os.path.join(ROOT, "nim", "jsoncanon_cli")
PYENV = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "python"))

N = int(sys.argv[1]) if len(sys.argv) > 1 else 500_000
rng = random.Random(0xBADC0DE)


def rand_double() -> float:
    while True:
        b = rng.getrandbits(64)
        if ((b >> 52) & 0x7FF) != 0x7FF:
            return struct.unpack("<d", struct.pack("<Q", b))[0]


def token(d: float) -> str:
    """Render a double as one of several lenient JSON number token spellings."""
    k = rng.random()
    if k < 0.5:
        return repr(d)
    if k < 0.7:
        return "%.17e" % d            # verbose scientific (still same double)
    if k < 0.85:
        return "%.17g" % d
    return repr(d).upper().replace("E", "E") if "e" in repr(d) else repr(d)


FIXED = [
    "0", "-0", "0.0", "-0.0", "4.0", "4.50e1", "1e3", "0.10", "+007",
    "1.5E-3", "333333333.33333329", "1E30", "2e-3", "1e21", "1e-7",
    "1e308", "5e-324", "2.2250738585072014e-308", "9007199254740993",
    "100000000000000000000", "0.000000000000000000000000001",
]


def run(cli, jcs_input):
    return subprocess.run(cli, input=jcs_input, capture_output=True,
                         check=True, env=PYENV).stdout


def main() -> None:
    toks = list(FIXED)
    toks += [token(rand_double()) for _ in range(N)]
    payload = ("[" + ",".join(toks) + "]").encode()

    nim = run([NIM, "--jcs"], payload)
    py = run([sys.executable, "-c",
              "import sys;from jsoncanon.cli import main;sys.exit(main())", "--jcs"],
             payload)

    if nim == py:
        print(f"OK: nim == python over {len(toks)} tokens ({len(nim)} bytes)")
        return

    # locate first differing token
    na = nim.decode().strip("[]").split(",")
    pa = py.decode().strip("[]").split(",")
    for i, (x, y) in enumerate(zip(na, pa)):
        if x != y:
            sys.exit(f"MISMATCH at token {i}: input={toks[i]!r} nim={x!r} python={y!r}")
    sys.exit(f"length mismatch nim={len(nim)} python={len(py)}")


if __name__ == "__main__":
    main()
