#!/usr/bin/env python3
"""Differential fuzz of --force salvage recovery (paper, Table 2 row 5).

Randomly corrupts well-formed JSON and runs both CLIs with --force, asserting
byte-identical stdout, stderr (the recovery report), and exit code. Fixed seed
=> reproducible. Builds the Nim CLI if absent.

    python3 tools/fuzz_force.py [N]      # default 4000
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NIM = os.path.join(ROOT, "nim", "jsoncanon_cli")
ENV = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "python"))
PY = [sys.executable, "-c", "import sys;from jsoncanon.cli import main;sys.exit(main())"]

N = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
rng = random.Random(0xF017CE)

_SEEDS = [
    '{"a":1,"b":[1,2,3],"c":{"d":true,"e":null}}',
    '[1,2.5,"x",[3,4],{"k":"v"}]',
    '{"n":[{"id":1},{"id":2}],"t":"hi"}',
    '[true,false,null,1e3,-0.5]',
]


def corrupt(s: str) -> str:
    b = list(s)
    for _ in range(rng.randint(1, 4)):
        op, pos = rng.random(), rng.randint(0, len(b) - 1)
        if op < 0.4 and b:
            del b[pos]
        elif op < 0.7:
            b.insert(pos, rng.choice('{}[],:"x 9.eE+-'))
        else:
            b[pos] = rng.choice('{}[],: x9.eE')
    return "".join(b)


def ensure_built() -> None:
    if not os.path.exists(NIM):
        subprocess.run(["nim", "c", "--hints:off", "--warnings:off",
                        "-o:" + NIM, os.path.join(ROOT, "nim", "src", "jsoncanon_cli.nim")],
                       check=True)


def main() -> None:
    ensure_built()
    bad = 0
    for _ in range(N):
        s = corrupt(rng.choice(_SEEDS)).encode()
        n = subprocess.run([NIM, "--force"], input=s, capture_output=True, env=ENV)
        p = subprocess.run(PY + ["--force"], input=s, capture_output=True, env=ENV)
        if (n.stdout, n.stderr, n.returncode) != (p.stdout, p.stderr, p.returncode):
            bad += 1
            if bad <= 8:
                print("MISMATCH", repr(s.decode()))
                print("  NIM", repr(n.stdout.decode()), repr(n.stderr.decode()))
                print("  PY ", repr(p.stdout.decode()), repr(p.stderr.decode()))
    print(f"force: {N} corrupted inputs  nim-vs-py={'OK' if not bad else bad}")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
