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
// - Writing a number into a currency cell turns the cell's format to automatic: the template's
//   "$20,000" came out "20,000", a set metal value "2,413.4", and a Total over a mix of the two lost
//   its format entirely ("113820.6462…", clipped). So a cell op can name the format to put back.

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
    const layouts = doc.sheets().map(measureLayout);
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
    layouts.forEach(restoreLayout);
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
  // Two minutes: a cold start of Numbers on a busy Mac, with iCloud documents
  // reopening, can take more than the one this used to allow.
  for (let i = 0; i < 240; i++) {  // open returns before the document exists
    const d = find();
    if (d) return Numbers.documents.byId(d.id());
    delay(0.5);
  }
  throw new Error(`Numbers didn't open ${path} within two minutes`);
}

// Layout. A table that grows pushes down everything whose horizontal span overlaps it, by however
// much, not just what sits under it. Gold + Silver, in the right-hand column of Assets, overlaps the
// Liabilities heading by a sliver, so its growth pushed the whole Liabilities section ~800pt below
// the end of Assets. Moving each section back by one amount wasn't enough either: its members had
// been pushed by different amounts, and the rule under the Liabilities heading (a line, which that
// pass never measured) was left ~750pt down, striking through Credit Card Details.
//
// So the whole sheet is measured in the template before filling, and every item is placed again
// afterwards from those positions and the tables' new heights:
// - A section is a text box (the template's only text boxes are its headings: Net Worth: Overview,
//   Assets, Liabilities) and everything below it, up to the next one. A heading keeps the gap it
//   had to the lowest thing above it.
// - Anything else moves with its heading, and further down below anything in its section that sits
//   above it and genuinely shares its column (a sliver of overlap doesn't count), keeping the gap
//   it had to that.
// - Items in a section whose tops lined up stay lined up: the Credit Card table beside Transactions
//   follows Transactions down when Credit Card Details grows above it.
const LAYOUT_KINDS = ["textItems", "tables", "charts", "shapes", "images", "groups", "lines"];
const ALIGNED = 2;  // pt between tops that count as one row; Cash sits 4pt below Gold + Silver

function measureLayout(sheet) {
  const items = [];
  LAYOUT_KINDS.forEach(kind => {
    let list = [];
    try { list = sheet[kind](); } catch (e) { return; }
    list.forEach((item, index) => {
      const p = item.position();
      items.push({ kind, index, x: p.x, y: p.y, w: item.width(), h: item.height() });
    });
  });
  return { sheet, items };
}

function placeItems(items, heightOf) {
  items.forEach(m => { m.newH = heightOf(m); });
  const headings = items.filter(m => m.kind === "textItems").sort((a, b) => a.y - b.y);
  const sectionOf = m => headings.filter(h => h !== m && h.y <= m.y + 0.5).pop() || null;
  const sharesColumn = (a, b) =>
    Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > Math.max(1, 0.2 * Math.min(a.w, b.w));
  const placed = [];
  const settle = m => { placed.push(m); };

  const order = [...items].sort((a, b) => a.y - b.y || a.x - b.x);
  for (let i = 0; i < order.length;) {
    const first = order[i];
    if (headings.includes(first)) {
      const above = placed.filter(p => p.y < first.y);
      first.newY = first.y;
      if (above.length) {
        const gap = first.y - Math.max(...above.map(p => p.y + p.h));
        first.newY = Math.max(first.y, Math.max(...above.map(p => p.newY + p.newH)) + gap);
      }
      settle(first);
      i++;
      continue;
    }
    const section = sectionOf(first);
    const row = [first];
    while (i + row.length < order.length) {
      const next = order[i + row.length];
      if (headings.includes(next) || next.y - first.y > ALIGNED || sectionOf(next) !== section) break;
      row.push(next);
    }
    const shift = Math.max(...row.map(m => {
      let y = m.y + (section ? section.newY - section.y : 0);
      placed.forEach(p => {
        if (sectionOf(p) !== section && p !== section) return;
        if (p.y + p.h > m.y + 0.5 || !sharesColumn(p, m)) return;
        y = Math.max(y, p.newY + p.newH + (m.y - (p.y + p.h)));
      });
      return y - m.y;
    }));
    row.forEach(m => { m.newY = m.y + shift; settle(m); });
    i += row.length;
  }
  return items;
}

function restoreLayout({ sheet, items }) {
  const item = m => sheet[m.kind][m.index];
  placeItems(items, m => item(m).height());
  // Top down, and checked: an item moved into a gap can be shoved again by one moved after it.
  for (let pass = 0; pass < 3; pass++) {
    let moved = false;
    [...items].sort((a, b) => a.newY - b.newY).forEach(m => {
      const it = item(m), p = it.position();
      if (Math.abs(p.y - m.newY) < 0.5 && Math.abs(p.x - m.x) < 0.5) return;
      it.position = { x: m.x, y: m.newY };
      moved = true;
    });
    if (!moved) return;
  }
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

// Money is typed the way this Mac writes an amount ("$173,902.21"), and checked like a date. The
// template's money cells (and so every row Numbers copies from them) are currency with two places
// and a thousands separator, and a typed amount keeps that; a number written in turned the cell
// automatic. Typed into an automatic cell, an amount without a separator ("$0.08") made a Total
// over it lose its own ("$228856.00"), and a whole-dollar currency format hid the cents
// ("$173,902" for $173,902.21). Anything that doesn't read back as the same amount is written as a
// number in the currency format after all.
const currencyText = (() => {
  const f = $.NSNumberFormatter.alloc.init;
  f.numberStyle = $.NSNumberFormatterCurrencyStyle;
  return f;
})();

function setMoney(c, v) {
  if (typeof v === "number") {
    c.value = currencyText.stringFromNumber($.NSNumber.numberWithDouble(v)).js;
    let back = null;
    try { back = c.value(); } catch (e) {}
    if (typeof back === "number" && Math.abs(back - v) < 0.005) return;
  }
  c.value = v == null ? "" : v;
  c.format = "currency";
}

// Metal Price: fixed rows found by their label; also tells the metal formulas which row is which.
// A metal with a formula in ls.formulas gets it (the sheet's live =STOCK("GC=F")), its number only
// if Numbers won't take the formula.
function fillLookup(tables, ls) {
  const t = tables[ls.name];
  if (!t) throw new Error(`the template has no table named '${ls.name}'`);
  const offset = isGrouped(t) ? 1 : 0;
  const formulas = ls.formulas || {};
  const rows = {};
  dataRows(t, offset === 1).forEach(r => {
    const label = t.rows[r - 1].cells[ls.keyCol + offset].value();
    const key = typeof label === "string" ? label.trim().toLowerCase() : "";
    if (!key) return;
    rows[key] = r;
    const c = t.rows[r - 1].cells[ls.valueCol + offset];
    if (key in formulas) {
      c.value = formulas[key];
      if (c.formula() && !/#REF!/.test(c.formula())) {
        if (ls.format) c.format = ls.format;
        return;
      }
    }
    if (!(key in ls.values)) return;
    if (ls.format === "currency") setMoney(c, ls.values[key]);
    else c.value = ls.values[key];
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

// A date goes in typed, as this Mac writes a short date ("9/3/26"), and is checked: written as a
// JavaScript Date, a cell in a row Numbers added showed "9/3/26 12:00 AM", clipped to "9/3/26 12:0"
// in the template's Date column (only the template's own row, typed by hand, showed the date
// alone). Anything that doesn't read back as that same day is written as a Date after all.
const shortDate = (() => {
  const f = $.NSDateFormatter.alloc.init;
  f.dateStyle = $.NSDateFormatterShortStyle;
  f.timeStyle = $.NSDateFormatterNoStyle;
  return f;
})();

function setDate(c, iso) {
  const [y, m, d] = iso.split("-").map(Number);
  const parts = $.NSDateComponents.alloc.init;
  parts.year = y; parts.month = m; parts.day = d;
  c.value = shortDate.stringFromDate($.NSCalendar.currentCalendar.dateFromComponents(parts)).js;
  let back = null;
  try { back = c.value(); } catch (e) {}
  if (back instanceof Date && back.getFullYear() === y && back.getMonth() === m - 1 && back.getDate() === d) return;
  c.value = new Date(y, m - 1, d);
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

  // An op's optional fourth element is the format the cell ends up in ("currency"), set after the
  // value, since writing a number is what loses it; money is typed with its cents (setMoney). A
  // kept template formula keeps its own format.
  const write = (r, token, [col, op, v, format]) => {
    const c = cell(r, col);
    if ((op === "set" || op === "keep") && format === "currency") {
      if (op === "keep" && c.formula()) return;  // leave a template formula
      setMoney(c, v);
      return;
    }
    switch (op) {
      case "set": c.value = v == null ? "" : v; break;
      case "text": setText(c, v); break;
      case "date": setDate(c, v); break;
      case "keep": if (c.formula()) return; c.value = v == null ? "" : v; break;  // leave a template formula
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
    if (format) c.format = format;
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
