#!/usr/bin/env python3
"""Differential fuzz of the shared regex subset (paper, Table 2 row 3).

Each randomly generated pattern/text pair is checked two ways simultaneously:
  * against CPython's re.search  -> correctness for the supported subset
  * against the Nim regexlite engine (nim/tests/regex_filter) -> Nim==Python parity

Fixed seed => reproducible. Builds the Nim filter if absent. Exits non-zero on
any correctness or parity mismatch.

    python3 tools/fuzz_regex.py [N]      # default 40000
"""
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FILTER = os.path.join(ROOT, "nim", "tests", "regex_filter")

N = int(sys.argv[1]) if len(sys.argv) > 1 else 40000
rng = random.Random(0x2024)

sys.path.insert(0, os.path.join(ROOT, "python"))
from jsoncanon._regex import search as pysearch  # noqa: E402

_ATOMS = ["a", "b", "c", "x", ".", r"\d", r"\w", r"\s",
          "[abc]", "[a-c]", "[^a-c]", "[0-9x]", "(ab)", "(a|b)"]
_QUANTS = ["", "*", "+", "?", "{2}", "{1,3}", "{0,2}", "{2,}"]


def gen(depth: int = 0) -> str:
    parts = []
    for _ in range(rng.randint(1, 4)):
        a = rng.choice(_ATOMS)
        if rng.random() < 0.25 and depth < 2:
            a = "(" + gen(depth + 1) + ")"
        parts.append(a + rng.choice(_QUANTS))
    seq = "".join(parts)
    if rng.random() < 0.25:
        seq += "|" + "".join(rng.choice(_ATOMS) + rng.choice(_QUANTS)
                              for _ in range(rng.randint(1, 2)))
    if rng.random() < 0.2:
        seq = "^" + seq
    if rng.random() < 0.2:
        seq = seq + "$"
    return seq


def ensure_built() -> None:
    if not os.path.exists(FILTER):
        subprocess.run(["nim", "c", "--hints:off", "--warnings:off", "-d:release",
                        os.path.join(ROOT, "nim", "tests", "regex_filter.nim")],
                       check=True)


def main() -> None:
    ensure_built()
    alpha = "abcx0123 _"
    samples = []
    while len(samples) < N:
        p, t = gen(), "".join(rng.choice(alpha) for _ in range(rng.randint(0, 7)))
        if "\t" in p or "\t" in t:
            continue
        try:
            w = re.search(p, t) is not None
        except re.error:
            continue
        samples.append((p, t, w))

    lines = [f"{p}\t{t}" for p, t, _ in samples]
    nim = subprocess.run([FILTER], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, check=True).stdout.splitlines()
    assert len(nim) == len(samples), (len(nim), len(samples))

    py_bad = par_bad = 0
    for (p, t, w), nl in zip(samples, nim):
        nb = nl == "1"
        g = pysearch(p, t)
        if g != w:
            py_bad += 1
            if py_bad <= 10:
                print(f"PY!=re  pat={p!r} txt={t!r} mine={g} re={w}")
        if nb != g:
            par_bad += 1
            if par_bad <= 10:
                print(f"NIM!=PY pat={p!r} txt={t!r} nim={nb} py={g}")
    print(f"regex: {len(samples)} pairs  py-vs-re={'OK' if not py_bad else py_bad}  "
          f"nim-vs-py={'OK' if not par_bad else par_bad}")
    if py_bad or par_bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
