"""Make the blank Finance template from a filled-in copy of the spreadsheet.

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
merchant or label from the filled sheet and must print "clean" before the template is committed.
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
    found: dict[str, list[str]] = {}
    with zipfile.ZipFile(template) as z:
        for info in z.infolist():
            data = z.read(info.filename)
            if info.filename.endswith(".iwa"):
                data = _unsnappy(data)
            for needle in needles:
                if needle.encode() in data:
                    found.setdefault(needle, []).append(info.filename)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filled", nargs="?", help="the spreadsheet with real data")
    parser.add_argument("output", nargs="?", help="where to write the blank template")
    parser.add_argument("--check", nargs=2, metavar=("TEMPLATE", "FILLED"),
                        help="only scan TEMPLATE for text from FILLED")
    args = parser.parse_args(argv)
    if args.check:
        found = leftovers(*args.check)
        if found:
            print(f"NOT clean: {len(found)} value(s) from the filled sheet are still in the template:")
            for needle, where in sorted(found.items())[:30]:
                print(f"  {needle!r} in {', '.join(sorted(set(where)))}")
            print("Open the template in Numbers, save it, and check again.")
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
    if found:
        print(f"not blank yet: {len(found)} value(s) survive in the pivot tables / calculation cache.")
        print("Open it in Numbers, save it once, then run --check before committing it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
