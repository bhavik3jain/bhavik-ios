# Finance ↔ Numbers

The Finance tracker keeps its data in the app. These scripts move one month at a time between the
app and the Numbers spreadsheet it replaced, so the sheet can still be produced, looking exactly as
it always has. They run on a Mac (the phone can't run Python) with [uv](https://docs.astral.sh/uv/):
nothing is installed, `uv run --with numbers-parser` fetches it per run. The export also needs
Numbers itself, because Numbers does the writing.

| Script | What it does |
| --- | --- |
| `Export Finance to Numbers.command` | Double-click: runs `export_folder.py` on iCloud Drive › Multitrack › Finance |
| `export_folder.py` | Every month JSON in a folder without an up-to-date `.numbers` → `export_numbers.py`, into the same folder |
| `export_numbers.py` | App month JSON + template → a filled `.numbers`, every table grown to fit, filled by Numbers (`numbers_fill.js`) |
| `import_numbers.py` | A filled `.numbers` → month JSON the app imports (one-time move off the sheet) |
| `make_template.py` | `--check` that a template holds nothing from the real sheet; also blanks a filled copy |
| `check_roundtrip.py` | import → export → import on a real sheet must give the same month back, and the same totals in Numbers |

## Monthly export

**Easiest: the Mac app.** Finance › Summary › Export › **Export September 2026 to Numbers** fills a
copy of `Finance Template.numbers` straight from iCloud — no JSON, no Terminal, no uv. It takes a
minute or two, asks where to save, and opens the result; the first time, macOS asks whether
Multitrack may control Numbers. It runs this folder's own `numbers_fill.js` and template, bundled
into the Mac app by project.yml, with a spec from `FinanceNumbersSpec.swift` — a port of
`export_numbers.build_spec` that must stay in step with it. Refresh the pivots afterwards (step 3).

Or with the scripts, from any device's JSON:

1. In the app: Finance › Summary › Export › choose the month. It saves `Finance 2026-09.json`;
   save it to iCloud Drive › Multitrack › Finance.
2. On the Mac, double-click `scripts/finance/Export Finance to Numbers.command`. It looks in
   iCloud Drive › Multitrack › Finance and writes `Finance 2026-09.numbers` beside every
   `Finance 2026-09.json` that has no Numbers file yet, or whose JSON is newer than its Numbers
   file (you exported that month again). Nothing runs in the background: it's on demand, and does
   nothing until you double-click it. The same from a terminal:

   ```sh
   uv run scripts/finance/export_folder.py            # --force redoes every month
   uv run scripts/finance/export_folder.py --folder ~/Desktop/Finance --troy-fix
   ```

   Each month takes one to two minutes (about 120 transactions); Numbers opens a copy, fills it,
   saves and closes it. Leave Numbers alone while it runs. It only touches the file it opened, so
   a spreadsheet you already have open is safe, but don't open the output until the month says
   `wrote`. A month that fails is reported and the others still run; a Numbers file already in
   the folder is only replaced once its replacement is complete.
3. Open each new file in Numbers and refresh the two pivot tables, `Credit Card` and
   `Personal Items Pivot`: select each one, and in the Organize sidebar click Refresh. Numbers
   doesn't refresh them on open or on save, and its scripting has no command for it, so until then
   they still show the template's "Seed Data" rows. Save after refreshing. The export prints this
   reminder when it finishes.

One month at a time, anywhere:

```sh
uv run scripts/finance/export_numbers.py "Finance 2026-09.json" \
    --template "scripts/finance/Finance Template.numbers" -o "Finance 2026-09.numbers"
```

### Setup, once

- **uv**: `curl -LsSf https://astral.sh/uv/install.sh | sh` (or `brew install uv`). The command
  file finds it in `~/.local/bin` or Homebrew.
- **Numbers**, from the App Store. If it's missing the export says so.
- **Automation permission.** The first run asks whether Terminal (or whichever app ran the script)
  may control Numbers; allow it. If it was refused, the export stops with a pointer to System
  Settings › Privacy & Security › Automation, where that app needs Numbers turned on.
- The first time you double-click the `.command` file, macOS may ask whether to open it; after
  that it opens straight into Terminal. When something fails, the window stays open until you
  press a key.

### Troy ounces

By default every metal row gets the sheet's own `CONVERT(Weight (g),"g","ozm")`, which uses the
28.35 g avoirdupois ounce. The app values metals in that same regular ounce
(`MetalValuation.gramsPerOunce`), so the sheet and the app agree. Gold and silver are priced per
troy ounce (31.1035 g), so both come out about 9.7% above market: a deliberate choice, to match
the sheet.

`--troy-fix` writes Weight (oz) as grams ÷ 31.1035 instead, valuing metals in troy ounces. That's
nearer the market, but the sheet then **disagrees with the app** by about 9.7% on every metal, and
on Personal Items, Total Assets and Total Net Worth with it.

## Rules the export keeps

- **Every table grows.** Rows are added with Numbers' own add-row, below the table's last data
  row, so a new row joins that owner group, copies the row's formulas, and every reference to a
  Total (Total Assets reads `Cash::Current Value Total`) still finds it. Writing a row's Owner,
  Metal or Card moves it into that group. Rows the month doesn't use are deleted, the template's
  seed rows included; a table with nothing this month keeps one empty row.
  numbers-parser can't do this: its `add_row` on a grouped table stores rows Numbers never shows,
  and leaves Total Assets pointing at the old cell, which is by then a data row.
- **Formulas stay.** Actual Cost stays `=Cost` unless a split was entered; Outstanding Balance
  stays the SUMIFS. Every metal row gets two formulas written into it: Weight (oz) is
  `CONVERT(Weight (g),"g","ozm")` (or a number, with `--troy-fix`), and Current Value is
  `Metal Price × Weight (oz)` for its own metal, since a copied formula would price a gold row
  added below silver at the silver price. A metal with a set value gets that number instead.
- **Set values.** A metal whose Current Value was typed over the formula (the engagement ring) has
  a set value. So does one whose formula isn't plain price × weight, such as price × weight plus a
  fixed amount: the month JSON can't say that, so `import_numbers.py` takes the value the sheet
  shows, warns `n metal(s) have a value that isn't price × weight; imported as set values`, and
  the export writes that number. The totals then match the sheet exactly, but that item stops
  following the metal price; change it in the app when it should.
- **Text stays text.** Numbers parses a typed value, so a merchant `76` would become a number,
  `1/2` a date and `=…` a formula. A text cell that comes back different is switched to the Text
  format and written again.
- **Formulas typed through scripting** resolve `C5`-style addresses in the file's storage order,
  not the order Numbers shows grouped rows in: `=C5` typed into a grouped row came out `#REF!`.
  That's why the metal formulas name their row by label instead.
- **Reading is storage order.** The importer reads grouped tables in the file's storage order, not
  the grouped order Numbers shows, so an exported month re-imports with the same rows in a
  different order. `Table.cell()` raises `KeyError` on those tables in numbers-parser 4.19, so
  reading only uses `rows()`.
- **Card balance** in the sheet is the SUMIFS over whatever is in Transactions. The app's export
  puts that month's transactions there, so it reads as the month's card spend.

## Month JSON (version 1)

The app's `FinanceMonthDocument` and these scripts share this shape; change both together. The
values below are made up.

```json
{ "version": 1, "month": "2026-09",
  "metalPrices": { "gold": 4500.0, "silver": 52.0 },
  "owners": ["Alex", "Sam", "Joint"],
  "accounts": [ { "category": "cash", "institution": "Example Bank", "name": "Checking", "owner": "Joint", "balance": 2500.0 } ],
  "cards": [ { "institution": "Example Card", "name": "Rewards", "owner": "Alex", "limit": 10000.0, "annualFee": 0.0 } ],
  "metals": [ { "name": "Gold - Coin", "metal": "gold", "grams": 31.1035, "pricePaidPerOz": 2000.0, "purchaseValue": 2000.0, "manualValue": null, "location": "Safe", "owner": "Joint" } ],
  "transactions": [ { "date": "2026-09-03", "cost": 12.5, "actualCost": 12.5, "merchant": "City Parking", "category": "Travel", "expense": "Parking", "breakDown": "N/A", "card": "Example Card - Rewards" } ],
  "budgets": [ { "category": "Food", "limit": 525.0 } ] }
```

`category` is `cash | investments | retirement | fixed | loan`; a transaction's `card` is the card's
sheet name, `"Institution - Name"`. Budgets are written only if the template has a `Budget` table.

## The template

`Finance Template.numbers` lives here, next to the scripts, and must never hold real data. It is
the source of truth for the sheet's look: every table, chart, colour, formula, group and pivot in
an export comes from it. It's the real sheet with a few fake **"Seed Data"** rows in each table
(owners "User 1", "User 2" and "Joint" in the grouped tables, one gold and one silver row, cards
with made-up round limits) and both pivots refreshed over them, so every grouping and formula has
a row to copy. Change the look there, in Numbers, and change numbers in it only in Numbers too, so
its calculation cache is rebuilt.

Before committing a new one, check it holds nothing from the real sheet:

```sh
uv run --with numbers-parser scripts/finance/make_template.py \
    --check "scripts/finance/Finance Template.numbers" test.numbers   # must print: clean
```

`--check` scans every stream in the file for the real sheet's names, merchants and labels, not
only the cells: pivot tables and Numbers' calculation cache kept jewelry names, card names and
merchants after every cell was cleared, until Numbers itself re-saved the file. It also compares
every cell's number with the real sheet's limits, fees, balances, weights and prices (ignoring
anything under 1): the first seeded template kept three real card limit and fee pairs on its fake
cards and still passed the text scan. It reports where it found something, never the value.
`make_template.py FILLED OUTPUT` still blanks a filled copy, as a starting point for a new
template; the export no longer needs the template's rows to fit a month. `.gitignore` here blocks
every other `.numbers` and `.json`.

To check a change to these scripts on the real sheet (prints counts and OK lines, no data):

```sh
uv run --with numbers-parser scripts/finance/check_roundtrip.py test.numbers
```

It needs the same month back, the formulas right, no seed row, seed owner, empty group or row
token left (the pivots excepted), and Total Assets, Total Liabilities and Total Net Worth equal to
the sheet's, as Numbers shows them. With `--troy-fix` it exports that way, and Total Assets and
Total Net Worth are expected to differ.
