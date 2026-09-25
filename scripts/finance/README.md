# Finance ↔ Numbers

The Finance tracker keeps its data in the app. These scripts move one month at a time between the
app and the Numbers spreadsheet it replaced, so the sheet can still be produced, looking exactly as
it always has. They run on a Mac (the phone can't run Python) with [uv](https://docs.astral.sh/uv/):
nothing is installed, `uv run --with numbers-parser` fetches it per run.

| Script | What it does |
| --- | --- |
| `export_numbers.py` | App month JSON + template → a filled `.numbers`, formulas, charts and pivots intact |
| `import_numbers.py` | A filled `.numbers` → month JSON the app imports (one-time move off the sheet) |
| `make_template.py` | A filled `.numbers` → the blank template, plus `--check` that it really is blank |
| `check_roundtrip.py` | import → blank → export → import on a real sheet must give the same month back |

## Monthly export

1. In the app: Finance › Summary › Export › choose the month. It saves `Finance 2026-09.json`
   (suggested folder: iCloud Drive › Multitrack › Finance).
2. On the Mac:

   ```sh
   uv run --with numbers-parser scripts/finance/export_numbers.py \
       ~/Library/Mobile\ Documents/com~apple~CloudDocs/Multitrack/Finance/Finance\ 2026-09.json \
       --template "scripts/finance/Finance Template.numbers" -o "Finance 2026-09.numbers"
   ```

   Add `--troy-fix` to write Weight (oz) in troy ounces. Without it the template's own
   `CONVERT(…,"g","ozm")` stays, which uses the 28.35 g avoirdupois ounce and overstates gold and
   silver by about 9.7%. The app always values metals in troy ounces.
3. Open the file in Numbers; it recalculates the totals and refreshes both pivot tables on open.

## Rules the export keeps

- **Values only.** numbers-parser can't write formulas, so it never replaces one it doesn't have to.
  Actual Cost stays `=Bn` unless a split was entered; Outstanding Balance stays the SUMIFS; Current
  Value stays `Metal Price × weight` unless the item has a set value (the engagement ring).
- **No inserted rows**, except in Transactions. Total Assets reads `Cash::C9` and similar by cell
  address, so a row inserted above a Total would silently shift it. If a month has more accounts,
  cards or metals than the template has rows, the script stops and names the table: add rows there
  in Numbers (above Total) and rerun. Spare rows are blanked.
- **Storage order.** Tables grouped by owner read and write rows in the file's storage order, not
  the grouped order Numbers shows. `Table.cell()` raises `KeyError` on those tables in
  numbers-parser 4.19, so the scripts only use `rows()` and `write()`.
- **Card balance** in the sheet is the SUMIFS over whatever is in Transactions. The app's export
  puts that month's transactions there, so it reads as the month's card spend.

## Month JSON (version 1)

The app's `FinanceMonthDocument` and these scripts share this shape; change both together.

```json
{ "version": 1, "month": "2026-09",
  "metalPrices": { "gold": 4500.0, "silver": 52.0 },
  "owners": ["Bhavik", "Saloni", "Joint"],
  "accounts": [ { "category": "cash", "institution": "Capital One", "name": "Checkings", "owner": "Joint", "balance": 3000.0 } ],
  "cards": [ { "institution": "Chase", "name": "Sapphire Preferred", "owner": "Bhavik", "limit": 41900.0, "annualFee": 95.0 } ],
  "metals": [ { "name": "Gold - Bar 1", "metal": "gold", "grams": 28.35, "pricePaidPerOz": 1600.0, "purchaseValue": 1600.0, "manualValue": null, "location": "Locker", "owner": "Joint" } ],
  "transactions": [ { "date": "2026-09-03", "cost": 4.35, "actualCost": 4.35, "merchant": "Park Duluth", "category": "Travel", "expense": "Parking", "breakDown": "N/A", "card": "Chase - Sapphire Preferred" } ],
  "budgets": [ { "category": "Food", "limit": 600.0 } ] }
```

`category` is `cash | investments | retirement | fixed | loan`; a transaction's `card` is the card's
sheet name, `"Institution - Name"`. Budgets are written only if the template has a `Budget` table.

## The blank template

`Finance Template.numbers` lives here, next to the scripts, and must never hold real data. It's
made from the real sheet, then cleaned by Numbers itself:

```sh
uv run --with numbers-parser --with pillow scripts/finance/make_template.py test.numbers \
    "scripts/finance/Finance Template.numbers"
# open it in Numbers, change nothing, save (this rebuilds the pivots and calculation cache)
uv run --with numbers-parser scripts/finance/make_template.py \
    --check "scripts/finance/Finance Template.numbers" test.numbers   # must print: clean
```

The save step is not optional. numbers-parser can't touch pivot tables or Numbers' calculation
cache, and on the real sheet both still held jewelry names, card names and merchants after every
cell was cleared. `.gitignore` here blocks every other `.numbers` and `.json`.
