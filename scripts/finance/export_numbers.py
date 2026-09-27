"""Fill a copy of the Finance Numbers template from a month the app exported.

    uv run scripts/finance/export_numbers.py "Finance 2026-09.json" \
        --template "scripts/finance/Finance Template.numbers" -o "Finance 2026-09.numbers"

Mac only, and Numbers does the writing: the script copies the template to the output path, opens
that copy in Numbers, fills it through Numbers' own scripting (numbers_fill.js), saves and closes it.
Every table grows to fit the month, however few rows the template has: rows are added the way
Numbers adds them by hand, so they join the right owner group, copy the row's formulas (Actual Cost
=Cost, the card SUMIFS) and every reference to a Total (Total Assets → Cash) still finds it. Rows
the month doesn't use, the template's "Seed Data" rows included, are deleted.

Formulas stay wherever the template has them, as before: Actual Cost is only overwritten by a split
and Outstanding Balance stays the SUMIFS. Every metal row gets the sheet's two formulas written into
it, Weight (oz) = CONVERT(Weight (g),"g","ozm") and Current Value = Metal Price × Weight (oz) for
its own metal, unless the item has a set value (the engagement ring, or any value that isn't
price × weight).

--troy-fix writes Weight (oz) as grams ÷ 31.1035 instead of the CONVERT(…,"g","ozm") formula,
which uses the 28.35 g avoirdupois ounce and overstates metals by ~9.7%.

The two pivot tables aren't refreshed: Numbers' scripting can't, and Numbers doesn't on open or save.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

import finance_numbers as fn

FILL_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "numbers_fill.js")


def money(v) -> float:
    # Numbers stores decimals with float noise (0.30000000000000004); a sheet of money wants cents.
    return round(float(v), 2)


# A table's rows are lists of [column, op, value], columns counted as numbers-parser counts them
# (the group column Numbers adds to a grouped table doesn't count). numbers_fill.js runs the ops in
# order, except that the grouping column (Owner, Metal, Card), whose write moves the row into that
# group, and then the token column always go last: "set" writes a number, "text" writes text as
# text (Numbers otherwise parses a merchant "76" as a number), "date" writes a yyyy-MM-dd date,
# "keep" writes unless the cell has a formula, "formula" writes a formula ({ROW} is this row,
# {COL:k} column k's header, {PRICE:gold} the Metal Price cell).


def _table(name: str, token_col: int, rows: list, width: int, group_col: int | None = None,
           optional: bool = False) -> dict:
    # With no rows the table keeps one, emptied: its formulas stay, everything else is cleared.
    # Token then group column last, like a filled row: clearing the Owner first moved the row, and
    # the token was then cleared in whichever row had slid into its place, leaving a "zzrow0zz"
    # row the importer read back as an account.
    rest = [col for col in range(width) if col not in (token_col, group_col)]
    blank = [[col, "keep", ""] for col in rest] + [[token_col, "set", ""]]
    if group_col is not None:
        blank.append([group_col, "set", ""])
    return {"name": name, "tokenCol": token_col, "groupCol": group_col, "rows": rows, "blank": blank,
            "optional": optional}


def build_spec(document: dict, output: str, troy_fix: bool = False) -> dict:
    prices = document.get("metalPrices", {})
    tables = []

    for table_name, category in fn.ACCOUNT_TABLES.items():
        rows = [
            [[2, "keep", money(a["balance"])],
             [0, "text", fn.display_name(a["institution"], a["name"])],
             [1, "text", a.get("owner") or fn.JOINT]]
            for a in document["accounts"] if a["category"] == category
        ]
        tables.append(_table(table_name, 0, rows, 3, group_col=1))

    for table_name, category in ((fn.FIXED_TABLE, "fixed"), (fn.LOAN_TABLE, "loan")):
        rows = [
            [[1, "keep", money(a["balance"])],
             [0, "text", fn.display_name(a["institution"], a["name"])]]
            for a in document["accounts"] if a["category"] == category
        ]
        tables.append(_table(table_name, 0, rows, 2))

    # Card balances are the template's own SUMIFS over Transactions; only a row that lost its
    # formula gets the same sum written as a value.
    spend: dict[str, float] = {}
    for tx in document["transactions"]:
        spend[tx["card"]] = spend.get(tx["card"], 0.0) + float(tx["actualCost"])
    rows = []
    for c in document["cards"]:
        name = fn.display_name(c["institution"], c["name"])
        rows.append([
            [2, "set", money(c["limit"])], [3, "set", money(c["annualFee"])],
            [4, "keep", money(spend.get(name, 0.0))],
            [0, "text", name], [1, "text", c.get("owner") or fn.JOINT],
        ])
    tables.append(_table(fn.CARD_TABLE, 0, rows, 5, group_col=1))

    rows = []
    for m in document["metals"]:
        grams = round(float(m["grams"]), 4)
        if troy_fix:
            weights = [[3, "set", grams], [2, "set", round(grams / fn.TROY_OUNCE_GRAMS, 6)]]
        else:
            # Weight (oz) is the sheet's CONVERT of grams, written into every row: "keep" left it to
            # the row Numbers copied, and rows added below a row with a typed weight got none, so
            # every added metal's ounces were a static number. Grams first, so a template row whose
            # Weight (g) was the CONVERT of ounces is never, even briefly, circular. A row the
            # user typed in ounces comes back as grams with the ounces worked out: same values.
            weights = [[3, "set", grams],
                       [2, "formula", '=CONVERT({COL:3} {ROW},"g","ozm")']]
        if m.get("manualValue") is not None:
            current = [6, "set", money(m["manualValue"])]
        else:
            # Written, never kept: a row Numbers adds copies its neighbour's formula, so a gold
            # row added below a silver one would be priced at the silver price.
            current = [6, "formula", "=Metal Price::{PRICE:%s}×{COL:2} {ROW}" % m["metal"].lower()]
        rows.append([
            *weights,
            [4, "set", money(m["pricePaidPerOz"]) if m.get("pricePaidPerOz") else ""],
            [5, "set", money(m.get("purchaseValue") or 0.0)],
            current,  # while the row's token is still in its Asset cell, for {ROW}
            [7, "text", m.get("location") or ""],
            [0, "text", m["name"]],
            [1, "text", m["metal"].capitalize()],
        ])
    tables.append(_table(fn.METAL_TABLE, 0, rows, 8, group_col=1))

    rows = []
    for tx in document["transactions"]:
        actual = money(tx["actualCost"])
        rows.append([
            [0, "date", tx["date"][:10]],
            [1, "set", money(tx["cost"])],
            # Actual Cost is =Cost in the template; keep it unless this one is split.
            [2, "keep" if actual == money(tx["cost"]) else "set", actual],
            [4, "text", tx["category"]], [5, "text", tx["expense"]], [6, "text", tx["breakDown"]],
            [3, "text", tx["merchant"]],
            [7, "text", tx["card"]],
        ])
    # Merchant carries the row's token: Date is a date cell and Card is the grouping column.
    tables.append(_table(fn.TRANSACTION_TABLE, 3, rows, 8, group_col=7))

    rows = [[[1, "keep", money(b["limit"])], [0, "text", b["category"]]]
            for b in document.get("budgets", [])]
    if rows:  # the user's sheet has no Budget table yet; fill one only if the template has it
        tables.append(_table(fn.BUDGET_TABLE, 0, rows, 2, optional=True))

    return {
        "path": os.path.realpath(output),
        "priceTable": {"name": fn.PRICE_TABLE, "keyCol": 0, "valueCol": 1,
                       "values": {k: money(v) for k, v in prices.items()}},
        "tables": tables,
    }


class NumbersError(Exception):
    """Numbers couldn't be driven: not installed, not allowed, or it refused an edit."""


NOT_INSTALLED = "Numbers isn't installed. Get it from the App Store, then run this again."
# A month of ~120 transactions takes one to two minutes; this is only for a Numbers that hung.
FILL_TIMEOUT = 20 * 60

PIVOT_NOTE = ("note: refresh the 'Credit Card' and 'Personal Items Pivot' pivot tables (select each, "
              "Organize sidebar › Refresh) and save; until then they show the template's seed rows")


def _explain(stderr: str) -> str:
    if "-1743" in stderr or "Not authorized" in stderr:
        return ("macOS didn't let this script control Numbers. Allow it in System Settings › "
                "Privacy & Security › Automation (under your terminal app, turn on Numbers), "
                "then run this again.")
    # JXA says "Application can't be found. (-2700)", with either apostrophe; open -b says
    # LSCopyApplicationURLsForBundleIdentifier failed. Matching "find" caught neither.
    if "-2700" in stderr and "be found" in stderr or "LSCopyApplicationURLs" in stderr or "-10814" in stderr:
        return NOT_INSTALLED
    return stderr.strip().removeprefix("execution error: ").strip()


def numbers_installed() -> bool:
    # Asks Launch Services, which neither launches Numbers nor needs Automation permission.
    check = ("ObjC.import('AppKit'); $.NSWorkspace.sharedWorkspace"
             ".URLForApplicationWithBundleIdentifier('com.apple.Numbers').isNil()")
    result = subprocess.run(["osascript", "-l", "JavaScript", "-e", check], capture_output=True, text=True)
    return result.stdout.strip() != "true"


def run_numbers(spec: dict) -> list[dict]:
    if sys.platform != "darwin":
        raise NumbersError("the export runs Numbers, so it needs a Mac")
    if not numbers_installed():
        raise NumbersError(NOT_INSTALLED)
    fd, spec_path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(spec, f, ensure_ascii=False)
        result = subprocess.run(["osascript", "-l", "JavaScript", FILL_SCRIPT, spec_path],
                                capture_output=True, text=True, timeout=FILL_TIMEOUT)
    except subprocess.TimeoutExpired:
        _close_without_saving(spec["path"])
        raise NumbersError(f"Numbers didn't finish within {FILL_TIMEOUT // 60} minutes; "
                           "quit it and run this again") from None
    finally:
        os.remove(spec_path)
    if result.returncode != 0:
        _close_without_saving(spec["path"])
        raise NumbersError(_explain(result.stderr))
    return json.loads(result.stdout)


CLOSE_JS = """
function run(argv) {
  const Numbers = Application("com.apple.Numbers");
  Numbers.documents().forEach(d => {
    try { if (d.file().toString() === argv[0]) d.close({ saving: "no" }); } catch (e) {}
  });
}
"""


def _close_without_saving(path: str) -> None:
    # numbers_fill.js closes its document even when it fails, unless Numbers stopped answering
    # (a timed-out Apple event); then try once more, so a half-filled copy isn't left open.
    # Best effort, never raising: a TimeoutExpired here once replaced the NumbersError that
    # explained the failure with a traceback.
    if not subprocess.run(["pgrep", "-x", "Numbers"], capture_output=True).stdout:
        return
    try:
        subprocess.run(["osascript", "-l", "JavaScript", "-e", CLOSE_JS, path],
                       capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        pass


def fill(template: str, document: dict, output: str, troy_fix: bool = False) -> list[dict]:
    """Copy the template to output and fill it in Numbers. Returns what went into each table."""
    if os.path.realpath(template) == os.path.realpath(output):
        raise fn.TemplateError("the output would overwrite the template; choose another -o")
    spec = build_spec(document, output, troy_fix=troy_fix)
    shutil.copyfile(template, output)
    try:
        report = run_numbers(spec)
    except BaseException:
        os.remove(output)  # a half-filled copy is worse than none
        raise
    for r in report:
        if r.get("missing"):
            print(f"note: the template has no '{r['table']}' table, so it was left out", file=sys.stderr)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("json_file", help="a month exported by the app, e.g. 'Finance 2026-09.json'")
    parser.add_argument("--template", required=True, help="the .numbers template to copy")
    parser.add_argument("-o", "--output", help="output .numbers (default: 'Finance <month>.numbers')")
    parser.add_argument("--troy-fix", action="store_true", help="write Weight (oz) in troy ounces")
    args = parser.parse_args(argv)
    with open(args.json_file, encoding="utf-8") as f:
        document = json.load(f)
    if document.get("version") != 1:
        print(f"error: unsupported document version {document.get('version')!r}", file=sys.stderr)
        return 1
    output = args.output or f"Finance {document['month']}.numbers"
    try:
        report = fill(args.template, document, output, troy_fix=args.troy_fix)
    except (fn.TemplateError, NumbersError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    rows = ", ".join(f"{r['table']} {r['written']}" for r in report if not r.get("missing"))
    print(f"wrote {output} ({rows})")
    print(PIVOT_NOTE, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
