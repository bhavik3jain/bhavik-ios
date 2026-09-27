// Fills a copy of the Finance template inside Numbers itself, so every table can grow.
//
//     osascript -l JavaScript numbers_fill.js spec.json
//
// export_numbers.py writes spec.json (which rows go in which table, cell by cell) and runs this;
// it isn't meant to be run by hand. The Mac app runs it too (App/Sources/MacFinanceNumbers.swift,
// with a spec from FinanceNumbersSpec.swift, a port of build_spec), through OSAKit rather than
// osascript, having opened the copy in Numbers itself (spec.opened). It opens the file at spec.path, fills it, saves and closes it,
// and never touches any other document Numbers has open.
//
// Why Numbers and not numbers-parser: numbers-parser's add_row on a table grouped by owner stores
// rows Numbers never shows, and it doesn't move the references other tables hold (Total Assets
// kept pointing at Cash::C5, which became a data row). Numbers' own "add row" does both, and copies
// the row's formulas (Actual Cost =Cost, the card SUMIFS) into the new row.
//
// Things about Numbers' scripting this depends on, each found the hard way:
// - In a grouped (categorized) table, cell 1 of every row is the group column. Reading it on a
//   data, header or footer row throws "The cell value cannot be retrieved"; on a group row it gives
//   the group's name. So a data row is one whose cell 1 throws, and real columns start at cell 2.
// - Row indexes count group rows, and writing a row's group column (Owner, Metal, Card) moves the
//   row into that group. Rows are therefore found by a token written into them, never by position,
//   and the group column is written after every other cell but the token itself.
// - A formula typed as text resolves A1 addresses in the file's storage order, not the order
//   Numbers shows: "=C5" typed into a grouped row came out #REF!. A named reference,
//   'Weight (oz)' 'token', resolves by the row's label instead, which is why metal rows are
//   written while the token is still in their Asset cell.

ObjC.import("Foundation");

const Numbers = Application("com.apple.Numbers");  // "Numbers Creator Studio" answers to this id

function readFile(path) {
  const data = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (data.isNil()) throw new Error("can't read " + path);
  return data.js;
}

function run(argv) {
  const spec = JSON.parse(readFile(argv[0]));
  const doc = openDocument(spec.path, spec.opened);
  const report = [];
  try {
    const tables = {};
    doc.sheets().forEach(sheet => sheet.tables().forEach(t => { tables[t.name()] = t; }));
    const priceRows = spec.priceTable ? fillLookup(tables, spec.priceTable) : {};
    spec.tables.forEach(ts => {
      const t = tables[ts.name];
      if (!t && ts.optional) { report.push({ table: ts.name, missing: true }); return; }
      if (!t) throw new Error(`the template has no table named '${ts.name}'`);
      try {
        report.push(fillTable(t, ts, priceRows));
      } catch (e) {
        throw new Error(`'${ts.name}': ${e.message}`);
      }
    });
    doc.save();
  } finally {
    doc.close({ saving: "no" });
  }
  return JSON.stringify(report);
}

function openDocument(path, opened) {
  const target = $(path).stringByResolvingSymlinksInPath.js;
  const find = () => Numbers.documents().find(d => {
    try { return $(d.file().toString()).stringByResolvingSymlinksInPath.js === target; } catch (e) { return false; }
  });
  // The Mac app opens the copy itself, with NSWorkspace: its sandbox would stop `open` handing
  // Numbers a file in the app's container. Then it's expected to be open, and only waited for.
  if (!opened) {
    if (find()) throw new Error(`${path} is already open in Numbers; close it and run this again`);
    // Through Launch Services, not Numbers' own open command: that Apple event sometimes never
    // replied (AppleEvent timed out, -1712) though the document had opened. -g keeps Numbers behind.
    const shell = Application.currentApplication();
    shell.includeStandardAdditions = true;
    shell.doShellScript("open -g -b com.apple.Numbers '" + path.replace(/'/g, "'\\''") + "'");
  }
  for (let i = 0; i < 120; i++) {  // open returns before the document exists
    const d = find();
    if (d) return Numbers.documents.byId(d.id());
    delay(0.5);
  }
  throw new Error(`Numbers didn't open ${path} within a minute`);
}

function isGrouped(t) {
  try { t.rows[0].cells[0].value(); return false; } catch (e) { return true; }
}

function dataRows(t, grouped) {
  const first = t.headerRowCount() + 1, last = t.rowCount() - t.footerRowCount();
  const out = [];
  for (let r = first; r <= last; r++) {
    if (!grouped) { out.push(r); continue; }
    try { t.rows[r - 1].cells[0].value(); } catch (e) { out.push(r); }  // throws only on data rows
  }
  return out;
}

// Metal Price: fixed rows found by their label; also tells the metal formulas which row is which.
function fillLookup(tables, ls) {
  const t = tables[ls.name];
  if (!t) throw new Error(`the template has no table named '${ls.name}'`);
  const offset = isGrouped(t) ? 1 : 0;
  const rows = {};
  dataRows(t, offset === 1).forEach(r => {
    const label = t.rows[r - 1].cells[ls.keyCol + offset].value();
    const key = typeof label === "string" ? label.trim().toLowerCase() : "";
    if (!key) return;
    rows[key] = r;
    if (key in ls.values) t.rows[r - 1].cells[ls.valueCol + offset].value = ls.values[key];
  });
  return rows;
}

// Text goes in as typed input, so Numbers parses it: a merchant "76" became the number 76, "1/2"
// a date, "=…" a failed formula. Only a cell that came back different is switched to the text
// format, so the Owner and Card pop-up menus keep theirs. A group cell has moved by the time it can
// be read back; fillRow checks those itself (setText's third argument skips the check).
function isText(c, v) {
  try { return c.value() === v; } catch (e) { return false; }
}

function setText(c, v, force) {
  v = v == null ? "" : String(v);
  if (!force) {
    c.value = v;
    if (v === "" || isText(c, v)) return;
  }
  c.format = "text";
  c.value = v;
}

function fillTable(t, ts, priceRows) {
  const started = Date.now();
  const grouped = isGrouped(t);
  const offset = grouped ? 1 : 0;
  const cell = (r, col) => t.rows[r - 1].cells[col + offset];
  const header = col => { const v = cell(1, col).value(); return v == null ? "" : String(v); };
  const tokenColumn = () => t.columns[ts.tokenCol + offset].cells.value();
  const need = Math.max(ts.rows.length, 1);  // a table keeps one (blank) row even with no data

  let rows = dataRows(t, grouped);
  if (rows.length === 0) throw new Error("has no data rows to copy; add one in the template");
  // New rows go below the last data row, so they join its group and copy its formulas. Each lands
  // directly below the one before; rescanning the table after every add took minutes on Transactions.
  if (rows.length < need) {
    let last = rows[rows.length - 1];
    for (let have = rows.length; have < need; have++, last++) Numbers.addRowBelow(t.rows[last - 1]);
    rows = dataRows(t, grouped);
    if (rows.length !== need) throw new Error(`has ${rows.length} data rows after adding, not ${need}`);
  }

  // Mark every data row, in the order Numbers shows them, so each can be found after rows move.
  const tokens = rows.map((r, i) => `zzrow${i}zz`);
  rows.forEach((r, i) => { cell(r, ts.tokenCol).value = tokens[i]; });

  const rowOf = token => {
    const values = tokenColumn();
    const i = values.indexOf(token);
    if (i < 0) throw new Error(`lost track of row ${token}`);
    return i + 1;
  };

  const write = (r, token, [col, op, v]) => {
    const c = cell(r, col);
    switch (op) {
      case "set": c.value = v == null ? "" : v; break;
      case "text": setText(c, v); break;
      case "date": { const [y, m, d] = v.split("-").map(Number); c.value = new Date(y, m - 1, d); break; }
      case "keep": if (!c.formula()) c.value = v == null ? "" : v; break;  // leave a template formula
      case "formula": {
        const text = v
          .replace(/\{ROW\}/g, `'${token}'`)
          .replace(/\{COL:(\d+)\}/g, (_, k) => `'${header(Number(k))}'`)
          .replace(/\{PRICE:(\w+)\}/g, (_, key) => {
            if (!(key in priceRows)) throw new Error(`Metal Price has no ${key} row`);
            return `$B$${priceRows[key]}`;
          });
        c.value = text;
        if (!c.formula() || /#REF!/.test(c.formula())) throw new Error(`Numbers rejected the formula ${text}`);
        break;
      }
      default: throw new Error(`unknown cell op ${op}`);
    }
  };

  // The group column (Owner, Metal, Card) moves the row when written, so it goes after every other
  // cell and the row is found again by its token; the token column goes last of all, which is also
  // what a {ROW} formula needs. Clearing a blank row's Owner before its token once left a
  // "zzrow0zz" row behind: the token was then cleared in whichever row had slid into its place.
  const fillRow = (token, ops) => {
    const last = col => ops.filter(op => op[0] === col);
    const ordered = [...ops.filter(op => op[0] !== ts.groupCol && op[0] !== ts.tokenCol),
                     ...last(ts.groupCol), ...last(ts.tokenCol)];
    let r = rowOf(token);
    ordered.forEach(op => {
      // A group cell can't be read back where it was written: the row has moved by then.
      write(r, token, op[0] === ts.groupCol && op[1] === "text" ? [op[0], "set", op[2]] : op);
      if (op[0] === ts.groupCol) {
        r = rowOf(token);
        if (op[1] === "text" && !isText(cell(r, op[0]), op[2])) {
          setText(cell(r, op[0]), op[2], true);  // moves the row again
          r = rowOf(token);
        }
      }
    });
  };
  ts.rows.forEach((ops, i) => fillRow(tokens[i], ops));
  if (ts.rows.length === 0) fillRow(tokens[0], ts.blank);

  // Delete what the month didn't use, seed rows included, bottom-up so rows above keep their index.
  const spare = tokens.slice(need);
  for (;;) {
    const values = tokenColumn();
    let last = -1;
    values.forEach((v, i) => { if (spare.includes(v)) last = i; });
    if (last < 0) break;
    t.rows[last].delete();
  }
  return { table: ts.name, written: ts.rows.length, dataRows: dataRows(t, grouped).length,
           seconds: Math.round((Date.now() - started) / 100) / 10 };
}
