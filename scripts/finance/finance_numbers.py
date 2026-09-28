"""Shared layout of the Finance Numbers template and helpers for reading it.

The template is the user's own spreadsheet, seeded with fake "Seed Data" rows. The app never builds
a Numbers file itself: it writes a FinanceMonthDocument JSON (schema in README.md), and
export_numbers.py has Numbers fill a copy of the template from it, so every table, chart, colour,
formula and pivot stays exactly as the user made it.

Reading goes through numbers-parser, and two of its behaviours shape it:
- Table.cell() and categorized_data() raise KeyError on this file's tables that are grouped by owner
  (Cash, Retirement, Credit Card Details, Gold + Silver…). Table.rows() works, and addresses rows in
  storage order, which is not the order Numbers shows them in. So this module only reads through
  rows().
- Writing is not done with it at all any more. Its add_row on a grouped table stores rows Numbers
  never shows, and it doesn't move the references other tables hold by position: after four rows
  went into Cash, Total Assets still read Cash::C5, by then a data row. Numbers' own scripting does
  both right, so export_numbers.py drives Numbers (numbers_fill.js). make_template.py still writes
  with numbers-parser, but only blanks cells and never adds a row.
"""

from __future__ import annotations

import datetime as dt
import warnings

# numbers-parser warns on every save that it won't modify the two pivot tables; that's intended.
warnings.filterwarnings("ignore", message="Not modifying pivot table")

TROY_OUNCE_GRAMS = 31.1035
# What the template's own CONVERT(…,"g","ozm") uses: the avoirdupois ounce, and what the app values
# metals in too (MetalValuation.gramsPerOunce), so the sheet and the app agree. Gold and silver are
# priced per troy ounce, so both come out ~9.7% above market, on purpose; --troy-fix values the
# sheet in troy ounces instead, which then DISAGREES with the app by that much.
AVOIRDUPOIS_OUNCE_GRAMS = 28.349523125

ACCOUNT_TABLES = {"Cash": "cash", "Investments": "investments", "Retirement": "retirement"}
FIXED_TABLE = "Large and Fixed Assets"
LOAN_TABLE = "Long-Term Liabilities"
CARD_TABLE = "Credit Card Details"
METAL_TABLE = "Gold + Silver"
PRICE_TABLE = "Metal Price"
TRANSACTION_TABLE = "Transactions"
BUDGET_TABLE = "Budget"  # optional; the user's sheet has none yet

JOINT = "Joint"


class TemplateError(Exception):
    """The file isn't the Finance sheet this toolkit expects."""


def open_document(path: str):
    # Imported here so export_numbers.py, which only drives Numbers, runs without numbers-parser.
    from numbers_parser import Document

    doc = Document(path)
    tables = {t.name: t for sheet in doc.sheets for t in sheet.tables}
    return doc, tables


def rows(table) -> list:
    """Every row as Cell objects, in storage order (the order write() uses)."""
    return table.rows(values_only=False)


def body_rows(table) -> list[int]:
    """Storage indices of data rows: not header rows, not the Total footer."""
    out = []
    for index, row in enumerate(rows(table)):
        if index < table.num_header_rows:
            continue
        first = row[0].value if row else None
        if isinstance(first, str) and first.strip() in ("Total", "Total assets", "Total liabilities"):
            continue
        out.append(index)
    return out


def has_formula(cell) -> bool:
    try:
        return bool(cell.formula)
    except Exception:
        return False


def value(cell):
    v = cell.value
    if isinstance(v, str) and v.strip() == "":
        return None
    return v


def number(cell) -> float:
    v = value(cell)
    if isinstance(v, (int, float)):
        return float(v)
    return 0.0


def text(cell) -> str:
    v = value(cell)
    return "" if v is None else str(v)


def split_display_name(display: str) -> tuple[str, str]:
    """ "Chase - Sapphire Preferred" -> ("Chase", "Sapphire Preferred").

    Split on the first " - " without stripping, so display_name() rebuilds the exact original,
    double spaces included ("Bank of America -  Cash Rewards")."""
    if " - " in display:
        institution, name = display.split(" - ", 1)
        return institution, name
    return "", display


def display_name(institution: str, name: str) -> str:
    return f"{institution} - {name}" if institution else name


def iso_date(v) -> str | None:
    if isinstance(v, dt.datetime):
        return v.date().isoformat()
    if isinstance(v, dt.date):
        return v.isoformat()
    if isinstance(v, str) and v:
        return v[:10]
    return None
