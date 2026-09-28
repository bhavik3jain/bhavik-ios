"""Check that import → export into the seeded template → import gives back the same month.

    uv run --with numbers-parser scripts/finance/check_roundtrip.py test.numbers

Needs a filled-in spreadsheet, which is never committed, and Numbers, which fills the export; so
this runs by hand on a Mac rather than in CI. Prints counts and OK/problem lines, never names or
amounts. Beyond the month coming back unchanged it checks what only Numbers can get right:

- the formulas the totals hang on survive, and the rows Numbers added price each metal at its own
  metal's price, keep Actual Cost = Cost and sum each card's own transactions;
- no "Seed Data" row, no seed owner ("User 1", "User 2", "User") and no row token (zzrowNzz) is
  left in any table but the two pivots, and no grouped table keeps a seed-owner or empty group, as
  Numbers shows its groups (numbers-parser can't see group rows);
- Total Assets, Total Liabilities and Total Net Worth, as Numbers shows them, match the source's
  exactly. Both files are opened in Numbers for that, the source as a temporary copy. A metal
  whose value isn't price × weight (a formula with a fixed amount added) comes through as a set
  value, so it matches too.

    uv run --with numbers-parser scripts/finance/check_roundtrip.py test.numbers --troy-fix

exports with --troy-fix instead: the month and the formulas must still come back right, and Total
Liabilities must match, but Total Assets and Total Net Worth are expected to differ, since every
metal is then valued in troy ounces (unlike the source sheet and the app, which use regular ones).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

import export_numbers
import finance_numbers as fn
import import_numbers

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEMPLATE = os.path.join(HERE, "Finance Template.numbers")

# Formulas the Net Worth: Overview section is built from; losing any of them breaks the sheet.
KEY_FORMULAS = [
    ("Total Net Worth", 0, 1), ("Total Assets", 6, 1), ("Total Liabilities", 3, 1),
    ("Cash", -1, 2), ("Gold + Silver", -1, 6),
]
PIVOTS = ("Credit Card", "Personal Items Pivot")

# (label, table, row, column) as Numbers' scripting counts them, from 1, and whether the metals'
# value is part of it (which --troy-fix changes on purpose).
TOTALS = [("Total Assets", "Total Assets", 7, 2, True),
          ("Total Liabilities", "Total Liabilities", 4, 2, False),
          ("Total Net Worth", "Total Net Worth", 1, 2, True)]

# The template's fake owners. Checking only for "seed" missed them: an owner cell or group left
# behind reads "User 1", with no "seed" in it.
SEED_OWNERS = {"User 1", "User 2", "User"}

READ_TOTALS_JS = r"""
ObjC.import("Foundation");
// Each grouped table's groups as Numbers shows them, [name, data rows]: in a grouped table cell 1
// of a row reads only on a group row (it's the group's name) and throws on every other row. The
// summary label row above the groups reads too ("Metal:", beside "Sum:"); it isn't a group.
function groups(t) {
  try { t.rows[0].cells[0].value(); return null; } catch (e) {}
  const out = [];
  for (let r = t.headerRowCount() + 1; r <= t.rowCount() - t.footerRowCount(); r++) {
    let name, group = true;
    try { name = t.rows[r - 1].cells[0].value(); } catch (e) { group = false; }
    if (group && /:$/.test(String(name))) continue;
    if (group) out.push([name == null ? "" : String(name), 0]);
    else if (out.length) out[out.length - 1][1]++;
  }
  return out;
}
function run(argv) {
  const Numbers = Application("com.apple.Numbers");
  const shell = Application.currentApplication();  // opens through Launch Services, as numbers_fill.js does
  shell.includeStandardAdditions = true;
  const cells = JSON.parse(argv[0]);
  const real = p => $(p).stringByResolvingSymlinksInPath.js;
  const out = [];
  for (const path of argv.slice(1)) {
    const find = () => Numbers.documents().find(d => {
      try { return real(d.file().toString()) === real(path); } catch (e) { return false; }
    });
    if (find()) throw new Error(path + " is already open in Numbers");
    shell.doShellScript("open -g -b com.apple.Numbers '" + path.replace(/'/g, "'\\''") + "'");
    let d = null;
    for (let i = 0; i < 120 && !d; i++) { d = find(); if (!d) delay(0.5); }
    if (!d) throw new Error("Numbers didn't open " + path);
    d = Numbers.documents.byId(d.id());
    try {
      const tables = {};
      d.sheets().forEach(s => s.tables().forEach(t => { tables[t.name()] = t; }));
      const totals = cells.map(([table, r, c]) => tables[table].rows[r - 1].cells[c - 1].formattedValue());
      const grouped = {};
      Object.entries(tables).forEach(([name, t]) => { const g = groups(t); if (g) grouped[name] = g; });
      out.push({ totals, groups: grouped });
    } finally {
      d.close({ saving: "no" });
    }
  }
  return JSON.stringify(out);
}
"""


def same(a, b, path="") -> list[str]:
    if isinstance(a, float) or isinstance(b, float):
        ok = isinstance(a, (int, float)) and isinstance(b, (int, float)) and math.isclose(a, b, abs_tol=0.005)
        return [] if ok else [f"{path}: values differ"]
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
    return [] if a == b else [f"{path}: values differ"]


def canonical(document: dict) -> dict:
    """The month with every list sorted. The importer reads a grouped table (Cash, cards, metals)
    in the file's storage order, and in an export Numbers picks that order: the same seven Cash
    accounts came back with the first two swapped. Order isn't part of the month."""
    key = lambda item: json.dumps(item, sort_keys=True)
    return {k: sorted(v, key=key) if isinstance(v, list) else v for k, v in document.items()}


def sheet_problems(path: str) -> tuple[list[str], list[str]]:
    """Formula and leftover checks on a filled file, from the values Numbers cached when it saved."""
    doc, tables = fn.open_document(path)
    problems, notes = [], []
    for name, row, col in KEY_FORMULAS:
        if not fn.has_formula(fn.rows(tables[name])[row][col]):
            problems.append(f"{name} row {row} col {col} lost its formula")

    t = tables[fn.PRICE_TABLE]
    all_rows = fn.rows(t)
    prices = {fn.text(all_rows[i][0]).strip().lower(): fn.number(all_rows[i][1]) for i in fn.body_rows(t)}
    t = tables[fn.METAL_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        if fn.has_formula(r[6]):
            expected = prices.get(fn.text(r[1]).strip().lower(), 0.0) * fn.number(r[2])
            if not math.isclose(expected, fn.number(r[6]), abs_tol=0.01):
                problems.append(f"{fn.METAL_TABLE} row {i}: Current Value isn't its own metal's price × weight")

    spend: dict[str, float] = {}
    t = tables[fn.TRANSACTION_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        if fn.has_formula(r[2]) and not math.isclose(fn.number(r[1]), fn.number(r[2]), abs_tol=0.005):
            problems.append(f"{fn.TRANSACTION_TABLE} row {i}: Actual Cost formula isn't its own Cost")
        spend[fn.text(r[7])] = spend.get(fn.text(r[7]), 0.0) + fn.number(r[2])
    t = tables[fn.CARD_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        if not math.isclose(spend.get(fn.text(r[0]), 0.0), fn.number(r[4]), abs_tol=0.01):
            problems.append(f"{fn.CARD_TABLE} row {i}: Outstanding Balance isn't that card's spend")

    for sheet in doc.sheets:
        for table in sheet.tables:
            texts = [v for row in fn.rows(table) for v in map(fn.value, row) if isinstance(v, str)]
            seeds = sum("seed" in v.lower() or v.strip() in SEED_OWNERS for v in texts)
            tokens = sum(bool(re.fullmatch(r"zzrow\d+zz", v)) for v in texts)
            if tokens:
                problems.append(f"{table.name}: {tokens} row token(s) left behind")
            if seeds and table.name in PIVOTS:
                notes.append(f"pivot '{table.name}' shows the template's seed rows until it's refreshed")
            elif seeds:
                problems.append(f"{table.name}: {seeds} seed value(s) left behind")
    return problems, notes


def group_problems(groups: dict[str, list]) -> tuple[list[str], list[str]]:
    """Seed-owner and empty groups in an export, from the groups Numbers shows. Counts only: the
    other group names are the user's owners and cards."""
    problems, notes = [], []
    for table, found in sorted(groups.items()):
        seeds = sum(name.strip() in SEED_OWNERS or "seed" in name.lower() for name, _ in found)
        empty = sum(count == 0 for _, count in found)
        if table in PIVOTS:
            if seeds:
                notes.append(f"pivot '{table}' shows the template's seed groups until it's refreshed")
            continue
        if seeds:
            problems.append(f"{table}: {seeds} seed group(s) left behind")
        if empty:
            problems.append(f"{table}: {empty} empty group(s)")
    return problems, notes


def read_totals(paths: list[str]) -> list[dict]:
    """For each file, as Numbers shows it: the TOTALS cells' text and every grouped table's groups."""
    fd, script = tempfile.mkstemp(suffix=".js")
    with os.fdopen(fd, "w") as f:
        f.write(READ_TOTALS_JS)
    try:
        cells = json.dumps([[table, r, c] for _, table, r, c, _ in TOTALS])
        result = subprocess.run(["osascript", "-l", "JavaScript", script, cells, *paths],
                                capture_output=True, text=True)
    finally:
        os.remove(script)
    if result.returncode != 0:
        raise export_numbers.NumbersError(export_numbers._explain(result.stderr))
    return json.loads(result.stdout)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filled", help="a filled-in copy of the spreadsheet")
    parser.add_argument("--template", default=DEFAULT_TEMPLATE, help="default: the committed template")
    parser.add_argument("--month", default="2026-09")
    parser.add_argument("--troy-fix", action="store_true",
                        help="export with --troy-fix; metal totals are then expected to differ")
    args = parser.parse_args(argv)

    work = tempfile.mkdtemp()
    try:
        source = os.path.join(work, "source.numbers")
        filled = os.path.join(work, "exported.numbers")
        shutil.copyfile(args.filled, source)  # Numbers only ever opens this copy

        warnings: list[str] = []
        original = import_numbers.read(source, args.month, warnings)
        report = export_numbers.fill(args.template, original, filled, troy_fix=args.troy_fix)
        again = import_numbers.read(filled, args.month)

        problems = same(canonical(original), canonical(again), "month")
        sheet, notes = sheet_problems(filled)
        problems += sheet

        before, after = read_totals([source, filled])
        grouped, group_notes = group_problems(after["groups"])
        problems += grouped
        notes += group_notes
        totals = []
        for (label, *_, has_metals), a, b in zip(TOTALS, before["totals"], after["totals"]):
            if a == b:
                totals.append(f"{label}: match")
            elif args.troy_fix and has_metals:
                totals.append(f"{label}: differs, as expected with --troy-fix")
            else:
                totals.append(f"{label}: MISMATCH")
                problems.append(f"{label} differs from the source")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    counts = {k: len(v) for k, v in original.items() if isinstance(v, list)}
    print(f"month: {counts}")
    print("rows written: " + ", ".join(f"{r['table']} {r['written']}" for r in report if not r.get("missing")))
    for line in totals:
        print(line)
    for warning in warnings:
        print(f"import warning: {warning}")
    for note in notes:
        print(f"note: {note}")
    if problems:
        print(f"{len(problems)} problem(s):")
        for p in problems[:40]:
            print(f"  {p}")
        return 1
    print("round trip OK: same month back, formulas right, no seed rows or tokens left")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
