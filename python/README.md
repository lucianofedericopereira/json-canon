# jsoncanon — canonical JSON

Take JSON produced by *anything* — CPython `json`, pandas `to_json`, Nim
`std/json`, JS, hand-edited files with comments and trailing commas — and emit
**one deterministic byte-stream**. Then `cmp`, `sha256`, and `git diff` on the
output actually mean something, no matter who produced the input.

This is the Python implementation. The canonical-form contract it obeys, the
companion Nim implementation, and the full project documentation live in the
[project repository](https://github.com/lucianofedericopereira/json-canon).

## Install

```sh
pip install jsoncanon
```

## Usage

```python
import jsoncanon

jsoncanon.dumps({"b": 1, "a": 2})  # canonical, deterministic bytes
```

```sh
jsoncanon < input.json > canonical.json
```

## License

MIT — see the project repository.
