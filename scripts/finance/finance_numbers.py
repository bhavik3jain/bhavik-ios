"""Shared layout of the Finance Numbers template and helpers for reading and writing it.

The template is the user's own spreadsheet. The app never builds a Numbers file itself: it writes a
FinanceMonthDocument JSON (schema in README.md), and export_numbers.py fills a copy of the template
from it, so every table, chart, colour, formula and pivot stays exactly as the user made it.

Two numbers-parser behaviours shape everything here:
- Table.cell() and categorized_data() raise KeyError on this file's tables that are grouped by owner
  (Cash, Retirement, Credit Card Details, Gold + Silver…). Table.rows() and Table.write() work, and
  both address rows in storage order, which is not the order Numbers shows them in. So this module
  only ever reads through rows() and writes through write().
- numbers-parser writes values, never formulas. Formula cells are left alone wherever possible, and
  rows are never inserted into a table whose Total row another table references by cell address
  (Total Assets reads Cash::C9), because the inserted row would move that Total and the reference
  would silently point at the wrong cell. Only Transactions, which nothing references by row, grows.
"""

from __future__ import annotations

import datetime as dt
import warnings

from numbers_parser import Document

# numbers-parser warns on every save that it won't modify the two pivot tables; that's intended.
warnings.filterwarnings("ignore", message="Not modifying pivot table")

TROY_OUNCE_GRAMS = 31.1035
# What the template's own CONVERT(…,"g","ozm") uses: the avoirdupois ounce. Gold and silver are
# priced per troy ounce, so the sheet overstates metals by ~9.7%; --troy-fix corrects it.
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
    """The template can't hold the data without the user changing it in Numbers first."""


def open_document(path: str) -> tuple[Document, dict]:
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
