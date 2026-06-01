"""Command-line interface: jsoncanon [INPUT] [-o OUTPUT] [flags]."""

from __future__ import annotations

import argparse
import sys

from . import canonicalize, lint, JSONError


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="jsoncanon",
        description="Normalize, lint, and re-encode JSON to a deterministic canonical form.",
    )
    p.add_argument("input", nargs="?", help="input file (default: stdin)")
    p.add_argument("-o", "--output", help="output file (default: stdout)")
    p.add_argument("--encoding", help="force input encoding instead of BOM autodetect")
    p.add_argument("--output-encoding", default="utf-8",
                   choices=["utf-8", "utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be", "latin-1"],
                   help="encode output in this charset (default: utf-8)")
    p.add_argument("--bom", action="store_true", help="prepend a BOM to the output")
    p.add_argument("--ndjson", action="store_true", help="treat input as NDJSON/JSONL")
    p.add_argument("--strict-dupes", action="store_true", help="error on duplicate object keys")
    p.add_argument("--preserve-number-type", action="store_true",
                   help="keep float-vs-int distinction (4.0 stays 4.0)")
    p.add_argument("--number-format", default="plain", choices=["plain", "auto", "scientific"],
                   help="plain decimal (default), auto (sci for huge/tiny), or always scientific")
    p.add_argument("--nan", choices=["error", "null", "string"], default="error",
                   help="how to emit NaN/Infinity (default: error)")
    p.add_argument("--newline", action="store_true", help="append a trailing newline")
    p.add_argument("--check", action="store_true",
                   help="exit 0 if input already canonical, 1 otherwise; no output")
    p.add_argument("--lint", action="store_true",
                   help="report every deviation from canonical form; exit 1 if any")
    return p


def _run_lint(args: argparse.Namespace, raw: bytes) -> int:
    issues = lint(raw, encoding=args.encoding, number_format=args.number_format)
    name = args.input or "<stdin>"
    if not issues:
        print(f"{name}: already canonical")
        return 0
    print(name)
    width = max(len(i.loc) for i in issues)
    for i in issues:
        print(f"  {i.loc:<{width}}  {i.category:<14}  {i.message}")
    print(f"{len(issues)} issue{'s' if len(issues) != 1 else ''}, not canonical")
    return 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    raw = open(args.input, "rb").read() if args.input else sys.stdin.buffer.read()

    if args.lint:
        try:
            return _run_lint(args, raw)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2

    try:
        out = canonicalize(
            raw,
            encoding=args.encoding,
            ndjson=args.ndjson,
            strict_dupes=args.strict_dupes,
            preserve_number_type=args.preserve_number_type,
            number_format=args.number_format,
            nan=args.nan,
            newline=args.newline,
            output_encoding=args.output_encoding,
            bom=args.bom,
        )
    except (JSONError, ValueError, UnicodeDecodeError) as e:
        print(f"jsoncanon: {e}", file=sys.stderr)
        return 2

    if args.check:
        return 0 if out == raw else 1

    if args.output:
        with open(args.output, "wb") as f:
            f.write(out)
    else:
        sys.stdout.buffer.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
