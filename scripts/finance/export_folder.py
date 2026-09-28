"""Turn every month the app saved to iCloud Drive into a Numbers file beside it, on demand.

    uv run scripts/finance/export_folder.py            # or double-click "Export Finance to Numbers.command"
    uv run scripts/finance/export_folder.py --force    # redo every month

Looks in iCloud Drive › Multitrack › Finance (--folder to look elsewhere) for each
`Finance YYYY-MM.json` the app exported, and fills the committed template for every one that has
no `Finance YYYY-MM.numbers` yet or whose JSON is newer than it, into that same folder. Each month
goes through export_numbers.py, so it needs Numbers and takes a minute or two. A month that fails
is reported and the rest still run; a Numbers file already there is only replaced once its
replacement is complete.

On demand rather than a background watcher: nothing runs until you ask, and nothing has to be kept
installed or running on the Mac.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import export_numbers
import finance_numbers as fn

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEMPLATE = os.path.join(HERE, "Finance Template.numbers")
DEFAULT_FOLDER = os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/Multitrack/Finance")
MONTH_FILE = re.compile(r"^Finance (\d{4}-\d{2})\.json$")
# iCloud Drive leaves a file it has offloaded as ".Finance 2026-09.json.icloud" until it's asked for.
PLACEHOLDER = re.compile(r"^\.(Finance \d{4}-\d{2}\.json)\.icloud$")
DOWNLOAD_WAIT = 60


def download_placeholders(folder: str) -> list[str]:
    """Ask iCloud Drive for every offloaded month and wait for them. Returns those still missing."""
    wanted = [m.group(1) for name in os.listdir(folder) if (m := PLACEHOLDER.match(name))]
    for name in wanted:
        subprocess.run(["brctl", "download", os.path.join(folder, name)], capture_output=True)
    deadline = time.monotonic() + DOWNLOAD_WAIT
    while wanted and time.monotonic() < deadline:
        wanted = [name for name in wanted if not os.path.exists(os.path.join(folder, name))]
        if wanted:
            time.sleep(1)
    return wanted


def months_to_export(folder: str, force: bool = False) -> list[tuple[str, str, str]]:
    """(month, json path, numbers path) for each month without an up-to-date Numbers file, oldest first."""
    out = []
    for name in sorted(os.listdir(folder)):
        m = MONTH_FILE.match(name)
        if not m:
            continue
        source = os.path.join(folder, name)
        target = os.path.join(folder, f"Finance {m.group(1)}.numbers")
        if force or not os.path.exists(target) or os.path.getmtime(source) > os.path.getmtime(target):
            out.append((m.group(1), source, target))
    return out


def export_month(template: str, source: str, target: str, troy_fix: bool = False) -> list[dict]:
    with open(source, encoding="utf-8") as f:
        document = json.load(f)
    if document.get("version") != 1:
        raise fn.TemplateError(f"unsupported document version {document.get('version')!r}")
    # Filled away from the folder and moved in whole, so a failed run never costs the Numbers file
    # already there, and iCloud never syncs a half-filled one.
    work = tempfile.mkdtemp()
    try:
        scratch = os.path.join(work, os.path.basename(target))
        report = export_numbers.fill(template, document, scratch, troy_fix=troy_fix)
        if os.path.isdir(target):
            shutil.rmtree(target)
        shutil.move(scratch, target)
        return report
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--folder", default=DEFAULT_FOLDER, help="default: iCloud Drive › Multitrack › Finance")
    parser.add_argument("--template", default=DEFAULT_TEMPLATE, help="default: the committed template")
    parser.add_argument("--force", action="store_true", help="export every month, even those up to date")
    parser.add_argument("--troy-fix", action="store_true", help="write Weight (oz) in troy ounces; the sheet then disagrees with the app by ~9.7%% on metals")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.folder):
        print(f"error: there's no folder {args.folder}\n"
              "Export a month from the app first (Finance › Summary › Export, saved to iCloud Drive › "
              "Multitrack › Finance), or point --folder at where you saved it.", file=sys.stderr)
        return 1
    if not os.path.isfile(args.template):
        print(f"error: no template at {args.template}", file=sys.stderr)
        return 1

    missing = download_placeholders(args.folder)
    for name in missing:
        print(f"skipped {name}: still downloading from iCloud; run this again in a minute", file=sys.stderr)

    todo = months_to_export(args.folder, force=args.force)
    if not todo:
        print("nothing to export: every month already has an up-to-date Numbers file"
              + ("" if args.force else " (--force redoes them)"))
        return 1 if missing else 0

    done, failed = [], []
    for month, source, target in todo:
        print(f"Finance {month}: exporting…", flush=True)
        started = time.monotonic()
        try:
            report = export_month(args.template, source, target, troy_fix=args.troy_fix)
        except (fn.TemplateError, export_numbers.NumbersError, OSError, ValueError, KeyError) as error:
            failed.append(month)
            print(f"Finance {month}: failed: {error}", file=sys.stderr)
            if isinstance(error, export_numbers.NumbersError) and (
                    str(error) == export_numbers.NOT_INSTALLED or "Automation" in str(error)):
                break  # every other month would fail the same way
            continue
        rows = ", ".join(f"{r['table']} {r['written']}" for r in report if not r.get("missing"))
        print(f"Finance {month}: wrote {os.path.basename(target)} in {time.monotonic() - started:.0f}s ({rows})")
        done.append(month)

    print()
    print(f"{len(done)} exported, {len(failed)} failed, {len(todo) - len(done) - len(failed)} not tried"
          f" ({args.folder})")
    if done:
        print(export_numbers.PIVOT_NOTE)
    return 1 if failed or missing else 0


if __name__ == "__main__":
    sys.exit(main())
