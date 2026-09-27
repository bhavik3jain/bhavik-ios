"""Check that import → blank template → export → import gives back the same month.

    uv run --with numbers-parser --with pillow scripts/finance/check_roundtrip.py test.numbers

Needs a filled-in spreadsheet, which is never committed, so this runs by hand rather than in CI.
Also checks that the formulas the sheet's totals depend on survive the export.
"""

from __future__ import annotations

import json
import math
import os
import sys
import tempfile

import export_numbers
import finance_numbers as fn
import import_numbers
import make_template

# Formulas the Net Worth: Overview section is built from; losing any of them breaks the sheet.
KEY_FORMULAS = [
    ("Total Net Worth", 0, 1), ("Total Assets", 6, 1), ("Total Liabilities", 3, 1),
    ("Cash", -1, 2), ("Gold + Silver", -1, 6),
]


def same(a, b, path="") -> list[str]:
    if isinstance(a, float) or isinstance(b, float):
        ok = isinstance(a, (int, float)) and isinstance(b, (int, float)) and math.isclose(a, b, abs_tol=0.005)
        return [] if ok else [f"{path}: {a!r} != {b!r}"]
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += same(a.get(k), b.get(k), f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path}: {len(a)} items != {len(b)} items"]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += same(x, y, f"{path}[{i}]")
        return out
    return [] if a == b else [f"{path}: {a!r} != {b!r}"]


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    source = argv[0]
    work = tempfile.mkdtemp()
    template = os.path.join(work, "template.numbers")
    filled = os.path.join(work, "filled.numbers")

    original = import_numbers.read(source, "2026-09")
    make_template.blank_values(source, template)
    make_template.blank_previews(template)
    blank = import_numbers.read(template, "2026-09")
    leftovers = {k: len(v) for k, v in blank.items() if isinstance(v, list) and v}
    export_numbers.fill(template, original, filled)
    again = import_numbers.read(filled, "2026-09")

    problems = [f"blank template still has data: {leftovers}"] if leftovers else []
    problems += same(original, again, "document")
    _, tables = fn.open_document(filled)
    for name, row, col in KEY_FORMULAS:
        cell = fn.rows(tables[name])[row][col]
        if not fn.has_formula(cell):
            problems.append(f"{name} row {row} col {col} lost its formula")

    counts = {k: len(v) for k, v in original.items() if isinstance(v, list)}
    print(f"source: {counts}")
    if problems:
        print(f"{len(problems)} problem(s):")
        for p in problems[:40]:
            print(f"  {p}")
        return 1
    print("round trip OK: same month back, blank template empty, key formulas intact")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
