"""Fill a copy of the Finance Numbers template from a month the app exported.

    uv run --with numbers-parser scripts/finance/export_numbers.py "Finance 2026-09.json" \
        --template "scripts/finance/Finance Template.numbers" -o "Finance 2026-09.numbers"

Only cell values are written. Every formula the template has keeps working (the totals, net worth,
the SUMIFS card balances, Metal Price × weight), the charts follow them, and the two pivot tables
are left untouched for Numbers to refresh when the file opens.

Rows: data goes into each table's existing rows in order and leftover rows are blanked. A table
with too few rows is an error, except Transactions, which grows: see finance_numbers.py for why.

--troy-fix writes Weight (oz) as grams ÷ 31.1035 instead of leaving the template's
CONVERT(…,"g","ozm"), which uses the 28.35 g avoirdupois ounce and overstates metals by ~9.7%.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys

import finance_numbers as fn


def money(v) -> float:
    # Numbers stores decimals with float noise (95.00000000000001); a sheet of money wants cents.
    return round(float(v), 2)


def _fill(table, items: list, write_row, blank_cols: range, grow: bool = False) -> None:
    targets = fn.body_rows(table)
    if len(items) > len(targets):
        if not grow:
            raise fn.TemplateError(
                f"'{table.name}' has {len(targets)} rows but this month needs {len(items)}. "
                f"Add {len(items) - len(targets)} row(s) to that table in the template in Numbers "
                f"(above its Total row) and run this again."
            )
        extra = len(items) - len(targets)
        table.add_row(num_rows=extra)
        targets = fn.body_rows(table)
    all_rows = fn.rows(table)
    for index, item in zip(targets, items):
        write_row(index, all_rows[index], item)
    for index in targets[len(items):]:
        for col in blank_cols:
            if not fn.has_formula(all_rows[index][col]):
                table.write(index, col, "")


def _set(table, row_index: int, cell, col: int, new_value, keep_formula: bool = True) -> None:
    """Write unless the cell holds a formula we mean to keep."""
    if keep_formula and fn.has_formula(cell):
        return
    table.write(row_index, col, "" if new_value is None else new_value)


def fill(template: str, document: dict, output: str, troy_fix: bool = False) -> None:
    doc, tables = fn.open_document(template)
    prices = document.get("metalPrices", {})

    for table_name, category in fn.ACCOUNT_TABLES.items():
        t = tables[table_name]
        items = [a for a in document["accounts"] if a["category"] == category]

        def write_account(i, row, a, t=t):
            t.write(i, 0, fn.display_name(a["institution"], a["name"]))
            t.write(i, 1, a.get("owner") or fn.JOINT)
            _set(t, i, row[2], 2, money(a["balance"]))

        _fill(t, items, write_account, range(3))

    for table_name, category in ((fn.FIXED_TABLE, "fixed"), (fn.LOAN_TABLE, "loan")):
        t = tables[table_name]
        items = [a for a in document["accounts"] if a["category"] == category]

        def write_simple(i, row, a, t=t):
            t.write(i, 0, fn.display_name(a["institution"], a["name"]))
            _set(t, i, row[1], 1, money(a["balance"]))

        _fill(t, items, write_simple, range(2))

    t = tables[fn.PRICE_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        key = fn.text(all_rows[i][0]).strip().lower()
        if key in prices:
            t.write(i, 1, money(prices[key]))

    # Card balances are the template's own SUMIFS over Transactions; only a row that lost its
    # formula gets the same sum written as a value.
    spend: dict[str, float] = {}
    for tx in document["transactions"]:
        spend[tx["card"]] = spend.get(tx["card"], 0.0) + float(tx["actualCost"])
    t = tables[fn.CARD_TABLE]

    def write_card(i, row, c, t=t):
        name = fn.display_name(c["institution"], c["name"])
        t.write(i, 0, name)
        t.write(i, 1, c.get("owner") or fn.JOINT)
        t.write(i, 2, money(c["limit"]))
        t.write(i, 3, money(c["annualFee"]))
        _set(t, i, row[4], 4, money(spend.get(name, 0.0)))

    _fill(t, document["cards"], write_card, range(5))

    t = tables[fn.METAL_TABLE]

    def write_metal(i, row, m, t=t):
        grams = round(float(m["grams"]), 4)
        metal = m["metal"].capitalize()
        price = float(prices.get(m["metal"], 0.0))
        t.write(i, 0, m["name"])
        t.write(i, 1, metal)
        if troy_fix:
            t.write(i, 2, round(grams / fn.TROY_OUNCE_GRAMS, 6))
            t.write(i, 3, grams)
        elif fn.has_formula(row[3]) and not fn.has_formula(row[2]):
            # A row the user typed in ounces (Gold - Bar 1): Weight (g) is its formula.
            t.write(i, 2, round(grams / fn.AVOIRDUPOIS_OUNCE_GRAMS, 6))
        else:
            _set(t, i, row[2], 2, round(grams / fn.AVOIRDUPOIS_OUNCE_GRAMS, 6))
            t.write(i, 3, grams)
        t.write(i, 4, money(m["pricePaidPerOz"]) if m.get("pricePaidPerOz") else "")
        t.write(i, 5, money(m.get("purchaseValue") or 0.0))
        if m.get("manualValue") is not None:
            t.write(i, 6, money(m["manualValue"]))
        else:
            ounces = grams / (fn.TROY_OUNCE_GRAMS if troy_fix else fn.AVOIRDUPOIS_OUNCE_GRAMS)
            _set(t, i, row[6], 6, money(ounces * price))
        t.write(i, 7, m.get("location") or "")

    _fill(t, document["metals"], write_metal, range(8))

    t = tables[fn.TRANSACTION_TABLE]

    def write_tx(i, row, tx, t=t):
        t.write(i, 0, dt.datetime.fromisoformat(tx["date"]))
        t.write(i, 1, money(tx["cost"]))
        # Actual Cost is =Bn in the template; keep it unless this one is split.
        _set(t, i, row[2], 2, money(tx["actualCost"]),
             keep_formula=money(tx["actualCost"]) == money(tx["cost"]))
        t.write(i, 3, tx["merchant"])
        t.write(i, 4, tx["category"])
        t.write(i, 5, tx["expense"])
        t.write(i, 6, tx["breakDown"])
        t.write(i, 7, tx["card"])

    _fill(t, document["transactions"], write_tx, range(8), grow=True)

    if fn.BUDGET_TABLE in tables and document.get("budgets"):
        t = tables[fn.BUDGET_TABLE]

        def write_budget(i, row, b, t=t):
            t.write(i, 0, b["category"])
            _set(t, i, row[1], 1, money(b["limit"]))

        _fill(t, document["budgets"], write_budget, range(2))

    doc.save(output)


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
        fill(args.template, document, output, troy_fix=args.troy_fix)
    except fn.TemplateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"wrote {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
