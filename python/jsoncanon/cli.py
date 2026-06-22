"""Command-line interface: jsoncanon [INPUT] [-o OUTPUT] [flags]."""

from __future__ import annotations

import argparse
import hashlib
import sys

from . import canonicalize, lint, ijson, diff, JSONError
from .lint import Issue, geojson


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
    p.add_argument("--from", dest="input_format", choices=["json", "cbor", "msgpack", "jdata"],
                   default="json", help="input format (default: json); cbor = RFC 8949, "
                   "msgpack = MessagePack, jdata = NeuroJSON")
    p.add_argument("--to", dest="output_format", choices=["json", "cbor", "msgpack"], default="json",
                   help="output format (default: json); cbor = RFC 8949, msgpack = deterministic MessagePack")
    p.add_argument("--ndjson", action="store_true", help="treat input as NDJSON/JSONL")
    p.add_argument("--json-seq", dest="json_seq", action="store_true",
                   help="parse a stream of values: RFC 7464 (RS-framed), "
                        "whitespace-separated, or concatenated")
    p.add_argument("--strict-dupes", action="store_true", help="error on duplicate object keys")
    p.add_argument("--preserve-number-type", action="store_true",
                   help="keep float-vs-int distinction (4.0 stays 4.0)")
    p.add_argument("--jcs", action="store_true",
                   help="RFC 8785 mode (Ryu numbers, UTF-16 key sort)")
    p.add_argument("--log", help="write a --jcs precision-change report to this file")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="suppress --jcs warnings on stderr (requires --log)")
    p.add_argument("--number-format", default="plain", choices=["plain", "auto", "scientific"],
                   help="plain decimal (default), auto (sci for huge/tiny), or always scientific")
    p.add_argument("--nan", choices=["error", "null", "string"], default="error",
                   help="how to emit NaN/Infinity (default: error)")
    p.add_argument("--newline", action="store_true", help="append a trailing newline")
    p.add_argument("--pointer", metavar="EXPR",
                   help="extract the sub-value at a JSON Pointer (RFC 6901), then canonicalize")
    p.add_argument("--patch", metavar="FILE",
                   help="apply a JSON Patch (RFC 6902) from FILE before canonicalizing")
    p.add_argument("--merge-patch", dest="merge_patch", metavar="FILE",
                   help="apply a JSON Merge Patch (RFC 7386) from FILE before canonicalizing")
    p.add_argument("--force", action="store_true",
                   help="salvage malformed input (drop bad members/elements), warn")
    p.add_argument("--check", action="store_true",
                   help="exit 0 if input already canonical, 1 otherwise; no output")
    p.add_argument("--lint", action="store_true",
                   help="report every deviation from canonical form; exit 1 if any")
    p.add_argument("--ijson", action="store_true",
                   help="report I-JSON (RFC 7493) violations; exit 1 if any")
    p.add_argument("--geojson", action="store_true",
                   help="report GeoJSON (RFC 7946) violations; exit 1 if any")
    p.add_argument("--sha256", action="store_true",
                   help="output the SHA-256 hex digest of the canonical bytes")
    p.add_argument("--diff", metavar="FILE",
                   help="structural diff of INPUT vs FILE after canonicalization; exit 1 if they differ")
    p.add_argument("--validate", metavar="FILE",
                   help="validate INPUT against a JSON Type Definition (RFC 8927) schema FILE")
    p.add_argument("--cddl", metavar="FILE",
                   help="validate INPUT against a CDDL (RFC 8610) schema FILE")
    p.add_argument("--schema", metavar="FILE",
                   help="validate INPUT against a JSON Schema (2020-12 / draft-07) FILE")
    p.add_argument("--format", action="store_true",
                   help="with --schema: also assert the `format` vocabulary")
    return p


def _report(name: str, issues: list[Issue], clean_msg: str, dirty_tail: str) -> int:
    if not issues:
        print(f"{name}: {clean_msg}")
        return 0
    print(name)
    width = max(len(i.loc) for i in issues)
    for i in issues:
        print(f"  {i.loc:<{width}}  {i.category:<14}  {i.message}")
    print(f"{len(issues)} issue{'s' if len(issues) != 1 else ''}, {dirty_tail}")
    return 1


def _run_lint(args: argparse.Namespace, raw: bytes) -> int:
    name = args.input or "<stdin>"
    return _report(name, lint(raw, encoding=args.encoding,
                              number_format=args.number_format),
                   "already canonical", "not canonical")


def _run_ijson(args: argparse.Namespace, raw: bytes) -> int:
    name = args.input or "<stdin>"
    return _report(name, ijson(raw, encoding=args.encoding),
                   "conforms to I-JSON", "not I-JSON")


def _run_geojson(args: argparse.Namespace, raw: bytes) -> int:
    name = args.input or "<stdin>"
    return _report(name, geojson(raw, encoding=args.encoding),
                   "conforms to GeoJSON", "not GeoJSON")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # Safety: --quiet must not be a way to discard the §5 precision record.
    if args.quiet and not args.log:
        print("jsoncanon: --quiet requires --log (the --jcs precision changes "
              "must be recorded somewhere)", file=sys.stderr)
        return 2

    raw = open(args.input, "rb").read() if args.input else sys.stdin.buffer.read()

    if args.lint or args.ijson or args.geojson:
        try:
            if args.geojson:
                return _run_geojson(args, raw)
            return _run_ijson(args, raw) if args.ijson else _run_lint(args, raw)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2

    if args.validate is not None:
        from .jtd import validate_jtd
        try:
            schema = open(args.validate, "rb").read()
            issues = validate_jtd(schema, raw, encoding=args.encoding)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2
        return _report(args.input or "<stdin>", issues,
                       "valid against JTD schema", "invalid against JTD schema")

    if args.schema is not None:
        from .jsonschema import validate_jsonschema
        try:
            sch = open(args.schema, "rb").read()
            issues = validate_jsonschema(sch, raw, encoding=args.encoding,
                                         assert_format=args.format)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2
        return _report(args.input or "<stdin>", issues,
                       "valid against JSON Schema", "invalid against JSON Schema")

    if args.cddl is not None:
        from .cddl import validate_cddl
        try:
            schema = open(args.cddl, "rb").read()
            issues = validate_cddl(schema, raw, encoding=args.encoding)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2
        return _report(args.input or "<stdin>", issues,
                       "valid against CDDL schema", "invalid against CDDL schema")

    if args.diff is not None:
        try:
            other = open(args.diff, "rb").read()
            lines = diff(raw, other, encoding=args.encoding,
                         strict_dupes=args.strict_dupes, jcs=args.jcs)
        except (JSONError, ValueError, UnicodeDecodeError) as e:
            print(f"jsoncanon: {e}", file=sys.stderr)
            return 2
        for ln in lines:
            print(ln)
        return 0 if not lines else 1

    transform = None
    if args.pointer is not None:
        from .jsonpointer import get_pointer
        transform = lambda v: get_pointer(v, args.pointer)  # noqa: E731
    elif args.patch is not None:
        from .jsonpatch import apply_patch
        from . import loads
        _ops = loads(open(args.patch).read())
        transform = lambda v: apply_patch(v, _ops)  # noqa: E731
    elif args.merge_patch is not None:
        from .jsonpatch import apply_merge_patch
        from . import loads
        _mp = loads(open(args.merge_patch).read())
        transform = lambda v: apply_merge_patch(v, _mp)  # noqa: E731

    warnings: list[str] = []
    force_warnings: list[str] = []
    try:
        out = canonicalize(
            raw,
            encoding=args.encoding,
            ndjson=args.ndjson,
            strict_dupes=args.strict_dupes,
            preserve_number_type=args.preserve_number_type,
            number_format=args.number_format,
            jcs=args.jcs,
            nan=args.nan,
            newline=args.newline,
            output_encoding=args.output_encoding,
            bom=args.bom,
            warnings=warnings if args.jcs else None,
            json_seq=args.json_seq,
            input_format=args.input_format,
            output_format=args.output_format,
            force=args.force,
            force_warnings=force_warnings if args.force else None,
            transform=transform,
        )
    except (JSONError, ValueError, UnicodeDecodeError) as e:
        print(f"jsoncanon: {e}", file=sys.stderr)
        return 2

    if args.check:
        return 0 if out == raw else 1

    if args.force and force_warnings and not args.quiet:
        src = args.input or "<stdin>"
        print(f"jsoncanon: --force salvaged {src} with {len(force_warnings)} "
              "recovery action(s):", file=sys.stderr)
        for w in force_warnings:
            print(f"  {w}", file=sys.stderr)

    # SPEC.md §5 precision report: --jcs can round numbers through binary64.
    if args.jcs and (warnings or args.log):
        src = args.input or "<stdin>"
        if warnings:
            header = (f"jsoncanon: --jcs changed {len(warnings)} value(s) in {src}; "
                      "canonical output no longer round-trips to the exact input:")
        else:
            header = f"jsoncanon: --jcs conversion of {src} is exact; no values changed."
        if not args.quiet and warnings:
            print(header, file=sys.stderr)
            for w in warnings:
                print(f"  {w}", file=sys.stderr)
        if args.log:
            with open(args.log, "w", encoding="utf-8") as f:
                f.write(header + "\n")
                for w in warnings:
                    f.write(f"  {w}\n")

    if args.sha256:
        out = hashlib.sha256(out).hexdigest().encode() + b"\n"

    if args.output:
        with open(args.output, "wb") as f:
            f.write(out)
    else:
        sys.stdout.buffer.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
