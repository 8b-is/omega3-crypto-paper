#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
if command -v pandoc >/dev/null 2>&1 && command -v xelatex >/dev/null 2>&1; then
  echo "building with pandoc..."
  pandoc paper/omega3.md -o build/omega3.pdf --pdf-engine=xelatex -V geometry:margin=1in
elif command -v pdflatex >/dev/null 2>&1; then
  echo "building with pdflatex..."
  (cd paper && pdflatex -output-directory=../build omega3.tex >/dev/null && pdflatex -output-directory=../build omega3.tex >/dev/null)
else
  echo "no pandoc+xelatex or pdflatex found; install one to build the PDF" >&2
  exit 1
fi
echo "ok: build/omega3.pdf"
