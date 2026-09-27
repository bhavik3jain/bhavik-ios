"""Check a Finance template holds nothing from the real sheet; or blank a filled-in copy of it.

The committed template is the user's sheet seeded with fake "Seed Data" rows, made in Numbers:
it's the source of truth now, and --check is what gates committing a new one. Blanking a filled
copy (below) is only a starting point for making another.

    uv run --with numbers-parser --with pillow scripts/finance/make_template.py test.numbers \
        "scripts/finance/Finance Template.numbers"
    uv run --with numbers-parser scripts/finance/make_template.py \
        --check "scripts/finance/Finance Template.numbers" test.numbers

Clears every value that isn't a formula or a header in the data tables, keeping each table's rows,
groups, formulas, styling and charts, then swaps the three preview images Numbers stores inside the
file (they are pictures of the filled-in sheet) for blank ones.

What this can't clear: numbers-parser won't touch the two pivot tables ('Credit Card',
'Personal Items Pivot') or Numbers' calculation cache, and both keep copies of the old names and
merchants. Tried on the real sheet: jewelry names, card names, "MBTA" all survived. So the output is
only blank after you open it in Numbers and save it once, which rebuilds both. Then run
`make_template.py --check TEMPLATE FILLED`: it scans every stream in the template for any name,
merchant or label from the filled sheet, and every cell for any of its limits, fees, balances,
weights and prices, and must print "clean" before the template is committed. It says where it found
something, never what.
"""

from __future__ import annotations

import argparse
import io
import os
import shutil
import sys
import tempfile
import zipfile

import finance_numbers as fn

DATA_TABLES = [
    *fn.ACCOUNT_TABLES, fn.FIXED_TABLE, fn.LOAN_TABLE, fn.CARD_TABLE,
    fn.METAL_TABLE, fn.PRICE_TABLE, fn.TRANSACTION_TABLE,
]
SUMMARY_TABLES = {"Total Assets", "Total Liabilities", "Total Net Worth"}


def blank_values(source: str, output: str) -> None:
    doc, tables = fn.open_document(source)
    for name in DATA_TABLES:
        if name not in tables:
            raise fn.TemplateError(f"{source} has no table named {name}")
        t = tables[name]
        all_rows = fn.rows(t)
        for i in fn.body_rows(t):
            for col, cell in enumerate(all_rows[i]):
                if name == fn.PRICE_TABLE and col == 0:
                    continue  # the Gold / Silver labels are layout, not data
                if not fn.has_formula(cell) and fn.value(cell) is not None:
                    t.write(i, col, "")
    doc.save(output)


def blank_previews(path: str) -> None:
    from PIL import Image

    def white_jpeg(data: bytes) -> bytes:
        size = Image.open(io.BytesIO(data)).size
        out = io.BytesIO()
        Image.new("RGB", size, "white").save(out, "JPEG", quality=80)
        return out.getvalue()

    fd, tmp = tempfile.mkstemp(suffix=".numbers")
    os.close(fd)
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as dst:
        for info in src.infolist():
            data = src.read(info.filename)
            if info.filename.startswith("preview") and info.filename.endswith(".jpg"):
                data = white_jpeg(data)
            dst.writestr(info, data)
    shutil.move(tmp, path)


def _unsnappy(data: bytes) -> bytes:
    """Numbers' .iwa streams are chunked Snappy; decode what decodes, keep the rest as is."""
    import cramjam

    out, i = bytearray(), 0
    while i + 4 <= len(data):
        n = int.from_bytes(data[i + 1:i + 4], "little")
        chunk = data[i + 4:i + 4 + n]
        i += 4 + n
        try:
            out += bytes(cramjam.snappy.decompress_raw(chunk))
        except Exception:
            out += chunk
    return bytes(out)


def leftovers(template: str, filled: str) -> dict[str, list[str]]:
    """Every text value from the filled sheet's data tables still present anywhere in the template."""
    _, tables = fn.open_document(filled)
    needles = set()
    for name in DATA_TABLES:
        if name not in tables:
            continue
        t = tables[name]
        all_rows = fn.rows(t)
        for i in fn.body_rows(t):
            for cell in all_rows[i]:
                v = fn.value(cell)
                if isinstance(v, str) and len(v.strip()) >= 4 and v.strip() not in ("N/A", "Gold", "Silver", "Joint"):
                    needles.add(v.strip())
    # A word inside one of the template's own labels is layout, not leftover data: the real
    # sheet's "Personal" category was flagged on every template because the "Personal Items" row
    # label contains it, and no re-save can clear a label. Only header rows and the summary tables
    # count as labels; a data cell never does, or a real name left in one would pass as layout.
    template_doc, _ = fn.open_document(template)
    labels = []
    for sheet in template_doc.sheets:
        for table in sheet.tables:
            rows = fn.rows(table)
            if table.name not in SUMMARY_TABLES:
                rows = rows[:table.num_header_rows]
            labels += [v for row in rows for v in map(fn.value, row) if isinstance(v, str)]
    needles = {n for n in needles if not any(n in label for label in labels)}
    found: dict[str, list[str]] = {}
    with zipfile.ZipFile(template) as z:
        for info in z.infolist():
            # Numbers' own build history ("Apple Numbers 14.4 …") is not sheet data;
            # scanning it flagged the merchant "Apple" on every template.
            if info.filename == "Metadata/BuildVersionHistory.plist":
                continue
            data = z.read(info.filename)
            if info.filename.endswith(".iwa"):
                data = _unsnappy(data)
            for needle in needles:
                if needle.encode() in data:
                    found.setdefault(needle, []).append(info.filename)
    return found


# Columns of the filled sheet whose numbers identify the user: a card's limit and annual fee, a
# balance, a metal's weight, price paid, purchase and current value, the metal prices. The first
# seeded template kept three real (limit, fee) pairs on its fake cards and still printed "clean",
# because only text was searched for. Transaction costs aren't needles: a seed $4.35 parking fee
# matches some real $4.35, which says nothing about anyone, and every cost derived from the seed
# rows (the card SUMIFS, the totals, the pivot) would then be flagged along with it.
NUMBER_NEEDLES = {
    **{name: (2,) for name in fn.ACCOUNT_TABLES},
    fn.FIXED_TABLE: (1,), fn.LOAN_TABLE: (1,),
    fn.CARD_TABLE: (2, 3),
    fn.METAL_TABLE: (2, 3, 4, 5, 6),
    fn.PRICE_TABLE: (1,),
}
# Below this an equal number is coincidence (a 0.5 oz coin), not a fingerprint.
TRIVIAL = 1.0


def _amount(v) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or abs(v) < TRIVIAL:
        return None
    return round(float(v), 2)


def number_leftovers(template: str, filled: str) -> list[str]:
    """Where the template holds a number that is also one of the filled sheet's amounts
    (NUMBER_NEEDLES), in any table, the pivots and totals included. Locations only, never values."""
    _, tables = fn.open_document(filled)
    needles = set()
    for name, cols in NUMBER_NEEDLES.items():
        if name not in tables:
            continue
        all_rows = fn.rows(tables[name])
        for i in fn.body_rows(tables[name]):
            for col in cols:
                if col < len(all_rows[i]) and (v := _amount(fn.value(all_rows[i][col]))) is not None:
                    needles.add(v)
    template_doc, _ = fn.open_document(template)
    found = []
    for sheet in template_doc.sheets:
        for table in sheet.tables:
            for i, row in enumerate(fn.rows(table)):
                if i < table.num_header_rows:
                    continue
                for col, cell in enumerate(row):
                    if _amount(fn.value(cell)) in needles:
                        found.append(f"{table.name} row {i} column {col}")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filled", nargs="?", help="the spreadsheet with real data")
    parser.add_argument("output", nargs="?", help="where to write the blank template")
    parser.add_argument("--check", nargs=2, metavar=("TEMPLATE", "FILLED"),
                        help="only scan TEMPLATE for text and amounts from FILLED")
    args = parser.parse_args(argv)
    if args.check:
        found = leftovers(*args.check)
        numbers = number_leftovers(*args.check)
        if found or numbers:
            if found:
                # Where, never what: the value is the user's, and this output ends up in logs.
                print(f"NOT clean: {len(found)} value(s) from the filled sheet are still in the template:")
                streams: dict[str, int] = {}
                for where in found.values():
                    for stream in set(where):
                        streams[stream] = streams.get(stream, 0) + 1
                for stream, count in sorted(streams.items()):
                    print(f"  {count} in {stream}")
                print("Open the template in Numbers, save it, and check again.")
            if numbers:
                # Where, never what: this output ends up in logs.
                print(f"NOT clean: {len(numbers)} cell(s) hold an amount from the filled sheet "
                      "(a limit, fee, balance, weight or price):")
                for where in numbers[:30]:
                    print(f"  {where}")
                print("Change those to made-up numbers in Numbers. In a pivot ('Credit Card', "
                      "'Personal Items Pivot') it's the old seed data: click Refresh in the Organize "
                      "sidebar, save, and check again.")
            return 1
        print("clean")
        return 0
    if not (args.filled and args.output):
        parser.error("give FILLED and OUTPUT, or --check TEMPLATE FILLED")
    try:
        blank_values(args.filled, args.output)
    except fn.TemplateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    blank_previews(args.output)
    found = leftovers(args.output, args.filled)
    print(f"wrote {args.output}")
    numbers = number_leftovers(args.output, args.filled)
    if found or numbers:
        print(f"not blank yet: {len(found) + len(numbers)} value(s) survive in the pivot tables / "
              "calculation cache.")
        print("Open it in Numbers, save it once, then run --check before committing it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
