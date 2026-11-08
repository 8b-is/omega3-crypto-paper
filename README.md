# Ω₃ — Balanced-Ternary Encoding, Exact Dyadic Arithmetic, and Capability-Sealed Reconciliation

**A construction paper for the 8b-is × Vaked × Aurora constellation.**

This repository holds the paper, the engineering blog, and the reproducible build for
the Ω₃ family of primitives that already ship (and are tested) across the constellation:

- **SPQT `base-243`** — packing 5 balanced trits `{-1, 0, +1}` into one byte (`3^5 = 243 ≤ 256`).
- **`LitanyWireFrame`** — a 64-byte, cache-line-aligned, `0x62`-gated integrity frame.
- **Exact dyadic arithmetic** — `ℤ[1/2]` scalars (`q = m / 2^k`) with zero floating-point drift.
- **Capability ABI** — `VirtualCapHandle64` + the 7-gate IOMMU check + Charm XVIII (`CAP_ROOT_SEAL`) isolation.
- **DEC / Cartan-torsion CRDT** — discrete-exterior-calculus reconciliation of concurrent branches.

Every claim here is backed by a test that runs in the source repos
(`8b-is/wupz`, `8b-is/upz`, `8b-is/spherepop-kernel`). This paper is documentation of
what is *built and verified*, not a claim of breaking anyone else's cryptography.

## Layout

```
paper/omega3.md      the paper (Markdown, canonical)
paper/omega3.tex     the paper (LaTeX, for PDF)
blog/2026-11-omega3.md   the engineering blog / walkthrough
scripts/build_pdf.sh     reproducible PDF build (pandoc or pdflatex)
```

## Build the PDF

```bash
./scripts/build_pdf.sh          # tries pandoc, falls back to pdflatex
```

## License

AGPL-3.0-only, matching the source repos.

`{<3,<3,<3}+1`
