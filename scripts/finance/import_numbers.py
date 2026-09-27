"""Read the Finance Numbers spreadsheet into a FinanceMonthDocument JSON the app can import.

    uv run --with numbers-parser scripts/finance/import_numbers.py test.numbers 2026-09 \
        -o "Finance 2026-09.json"

Everything in the sheet goes into that one month: balances, metal prices, cards, metals and every
row of Transactions (dated by their own dates; the app files each under the month it falls in).
The sheet has no owner column for metals, so they come in as Joint; change them in the app.
"""

from __future__ import annotations

import argparse
import json
import sys

import finance_numbers as fn


def read(path: str, month: str, warnings: list[str] | None = None) -> dict:
    """The month in the sheet at path. What the month JSON can only approximate is appended to
    warnings, as counts, never names or amounts."""
    _, tables = fn.open_document(path)
    missing = [
        name
        for name in [*fn.ACCOUNT_TABLES, fn.FIXED_TABLE, fn.LOAN_TABLE, fn.CARD_TABLE,
                     fn.METAL_TABLE, fn.PRICE_TABLE, fn.TRANSACTION_TABLE]
        if name not in tables
    ]
    if missing:
        raise fn.TemplateError(f"{path} has no table named {', '.join(missing)}")

    owners: list[str] = []

    def note_owner(name: str) -> str:
        name = name or fn.JOINT
        if name not in owners:
            owners.append(name)
        return name

    accounts = []
    for table_name, category in fn.ACCOUNT_TABLES.items():
        t = tables[table_name]
        all_rows = fn.rows(t)
        for i in fn.body_rows(t):
            r = all_rows[i]
            display = fn.text(r[0])
            if not display:
                continue
            institution, name = fn.split_display_name(display)
            accounts.append({
                "category": category, "institution": institution, "name": name,
                "owner": note_owner(fn.text(r[1])), "balance": fn.number(r[2]),
            })

    for table_name, category in ((fn.FIXED_TABLE, "fixed"), (fn.LOAN_TABLE, "loan")):
        t = tables[table_name]
        all_rows = fn.rows(t)
        for i in fn.body_rows(t):
            r = all_rows[i]
            display = fn.text(r[0])
            if not display:
                continue
            # Cars and loans are named without an institution ("Audi"), so keep the name whole.
            accounts.append({
                "category": category, "institution": "", "name": display,
                "owner": note_owner(fn.JOINT), "balance": fn.number(r[1]),
            })

    cards = []
    t = tables[fn.CARD_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        display = fn.text(r[0])
        if not display:
            continue
        institution, name = fn.split_display_name(display)
        cards.append({
            "institution": institution, "name": name, "owner": note_owner(fn.text(r[1])),
            "limit": fn.number(r[2]), "annualFee": fn.number(r[3]),
        })

    prices = {"gold": 0.0, "silver": 0.0}
    t = tables[fn.PRICE_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        key = fn.text(all_rows[i][0]).strip().lower()
        if key in prices:
            prices[key] = fn.number(all_rows[i][1])

    metals = []
    set_values = 0
    t = tables[fn.METAL_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        name = fn.text(r[0])
        if not name:
            continue
        metal = fn.text(r[1]).strip().lower() or "gold"
        grams = fn.number(r[3])
        current = fn.number(r[6])
        # A Current Value typed over the formula (the engagement ring) is a set value. So is a
        # formula that isn't plain Metal Price × Weight (oz): one real row adds a fixed amount to
        # it, and reading every formula as price × weight dropped that amount from the month, so
        # every export after it came out short in Personal Items, Total Assets and Total Net Worth.
        # Only a formula whose value is its own metal's price × weight, to the cent, is recomputed
        # from grams; anything else keeps the value the sheet shows.
        formula = fn.has_formula(r[6])
        recomputable = formula and abs(prices.get(metal, 0.0) * fn.number(r[2]) - current) < 0.01
        manual = None if recomputable else current
        if formula and not recomputable:
            set_values += 1
        metals.append({
            "name": name, "metal": metal, "grams": grams,
            "pricePaidPerOz": fn.number(r[4]), "purchaseValue": fn.number(r[5]),
            "manualValue": manual, "location": fn.text(r[7]), "owner": note_owner(fn.JOINT),
        })

    if set_values and warnings is not None:
        warnings.append(f"{set_values} metal(s) have a value that isn't price × weight; imported as set "
                        "values, so they won't follow the metal price")

    transactions = []
    t = tables[fn.TRANSACTION_TABLE]
    all_rows = fn.rows(t)
    for i in fn.body_rows(t):
        r = all_rows[i]
        date = fn.iso_date(fn.value(r[0]))
        if not date:
            continue
        cost = fn.number(r[1])
        # Actual Cost is =Bn unless a split was typed over it. Read the formula as Cost rather than
        # its cached value: a file this toolkit filled has stale caches until Numbers recalculates.
        actual = cost if fn.has_formula(r[2]) else fn.number(r[2])
        transactions.append({
            "date": date, "cost": cost, "actualCost": actual,
            "merchant": fn.text(r[3]), "category": fn.text(r[4]), "expense": fn.text(r[5]),
            "breakDown": fn.text(r[6]), "card": fn.text(r[7]),
        })

    budgets = []
    if fn.BUDGET_TABLE in tables:
        t = tables[fn.BUDGET_TABLE]
        all_rows = fn.rows(t)
        for i in fn.body_rows(t):
            category = fn.text(all_rows[i][0])
            if category:
                budgets.append({"category": category, "limit": fn.number(all_rows[i][1])})

    return {
        "version": 1, "month": month, "metalPrices": prices, "owners": owners,
        "accounts": accounts, "cards": cards, "metals": metals,
        "transactions": transactions, "budgets": budgets,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("numbers_file")
    parser.add_argument("month", help="yyyy-MM the balances belong to, e.g. 2026-09")
    parser.add_argument("-o", "--output", help="JSON path (default: stdout)")
    args = parser.parse_args(argv)
    warnings: list[str] = []
    try:
        doc = read(args.numbers_file, args.month, warnings)
    except fn.TemplateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    text = json.dumps(doc, indent=2, ensure_ascii=False)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
