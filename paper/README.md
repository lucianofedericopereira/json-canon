# Companion paper

`main.tex` is an arXiv-ready article (standard `article` class) with a proper
BibTeX bibliography in `references.bib` (`natbib` + `abbrvnat` style).

## Build

```bash
pdflatex main.tex
bibtex   main          # resolve references.bib
pdflatex main.tex
pdflatex main.tex      # second pass settles cross-references
```

Any TeX Live / MacTeX install works; the only packages used are standard
(`geometry`, `booktabs`, `microtype`, `xcolor`, `listings`, `natbib`,
`hyperref`, `enumitem`).

For arXiv submission, upload `main.tex` and `references.bib` (arXiv runs BibTeX
automatically), or include the generated `main.bbl` alongside `main.tex`.

## What it argues

The paper frames `jsoncanon` as a *tool / experience report* (suitable for
arXiv `cs.SE`, cross-listable `cs.PL`). Its thesis is the **dual-implementation
byte-parity contract**: two independent implementations (Python + Nim) required
to agree byte-for-byte through a written specification, with the hard components
(shortest-float printing, regex matching, half-float encoding) validated against
*external* oracles (Node.js, CPython `re`, Python `struct`). It is deliberately
honest that parity is *agreement*, not *correctness*, and that several validators
are subsets. All measured numbers and the feature table are drawn from this
repository so the claims are reproducible from `tools/check.sh` and the fuzzers.
