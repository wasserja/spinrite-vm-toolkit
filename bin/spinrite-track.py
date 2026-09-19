#!/usr/bin/env python3
"""
Tracker for SpinRite/ReadSpeed runs across computers and disks.

Data lives in ~/spinrite-tracker.csv (one row per disk-action per session).
This script only formats/reports and appends/updates rows -- the CSV itself
is the source of truth and is safe to inspect/edit directly with any
spreadsheet tool or text editor.

IMPORTANT: SpinRite's own "Perform drive benchmarks" numbers (front/mid/end
of drive rate) and ReadSpeed's numbers (0/25/50/75/100% of drive) are NOT
directly comparable to each other -- under this VM's raw-disk-passthrough
setup, SpinRite's benchmark goes through BIOS-extended access (much slower,
e.g. ~384 MB/s observed) while ReadSpeed uses a faster path (e.g. ~1500-1650
MB/s observed on the same physical drive same day). Compare SpinRite-before
to SpinRite-after, and ReadSpeed-before to ReadSpeed-after, never across
tools. See docs/tracking.md and docs/field-notes.md for detail.

Usage:
  spinrite-track.py report [--computer SERIAL] [--disk SERIAL]
      Pretty-print tracked runs, most recent first. Optionally filter.

  spinrite-track.py add --disk-model M --disk-serial S --capacity C
      --connection {native-sata,native-nvme,usb-<name>} --action A
      [--computer-mfr M] [--computer-model M] [--computer-serial S]
      [--start ISO] [--end ISO]
      [--rs-before "v;v;v;v;v"] [--rs-after "v;v;v;v;v"]
      [--sr-bench-before "front;mid;end"] [--sr-bench-after "front;mid;end"]
      [--result R] [--duration H:MM:SS] [--notes TEXT]
      Append one row. --computer-* auto-detected via dmidecode if omitted.

  spinrite-track.py update --disk-serial S [--start ISO] --set FIELD=VALUE [--set FIELD=VALUE ...]
      Update the most recent row matching --disk-serial (narrow with --start
      if that disk has more than one row). Use to attach a benchmark/result
      captured after the row was first logged.

  spinrite-track.py path
      Print the CSV path (for scripting/backup).
"""
import argparse
import csv
import os
import subprocess
import sys
from datetime import datetime

CSV_PATH = os.path.expanduser("~/spinrite-tracker.csv")
FIELDS = [
    "date_start", "date_end",
    "computer_mfr", "computer_model", "computer_serial",
    "disk_model", "disk_serial", "capacity", "connection",
    "action",
    "readspeed_before", "readspeed_after",
    "spinrite_bench_before", "spinrite_bench_after",
    "result", "duration", "notes",
]


def ensure_csv():
    if not os.path.exists(CSV_PATH):
        with open(CSV_PATH, "w", newline="") as f:
            csv.DictWriter(f, fieldnames=FIELDS).writeheader()
        return
    # Migrate forward if the file predates newer columns -- old rows just
    # get '' for any field added since they were written (DictWriter fills
    # missing keys via restval).
    with open(CSV_PATH, newline="") as f:
        reader = csv.DictReader(f)
        existing_fields = reader.fieldnames or []
        rows = list(reader)
    if existing_fields != FIELDS:
        with open(CSV_PATH, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=FIELDS, restval="")
            w.writeheader()
            for r in rows:
                w.writerow(r)


def dmidecode_field(key):
    try:
        out = subprocess.run(
            ["sudo", "-n", "dmidecode", "-s", key],
            capture_output=True, text=True, timeout=5,
        )
        val = out.stdout.strip().splitlines()[0].strip() if out.stdout.strip() else ""
        return val if val and "Not Specified" not in val else ""
    except Exception:
        return ""


def read_rows():
    ensure_csv()
    with open(CSV_PATH, newline="") as f:
        return list(csv.DictReader(f))


def write_rows(rows):
    with open(CSV_PATH, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, restval="")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def cmd_report(args):
    rows = read_rows()
    if args.computer:
        rows = [r for r in rows if args.computer.lower() in r.get("computer_serial", "").lower()]
    if args.disk:
        rows = [r for r in rows if args.disk.lower() in r.get("disk_serial", "").lower()]
    if not rows:
        print("No tracked runs found.")
        return
    rows.sort(key=lambda r: r.get("date_start", ""), reverse=True)
    for r in rows:
        computer = f'{r.get("computer_mfr", "")} {r.get("computer_model", "")}'.strip() or "unknown computer"
        if r.get("computer_serial"):
            computer += f' (S/N {r["computer_serial"]})'
        print(f'[{r.get("date_start", "")} -> {r.get("date_end") or "?"}]  {computer}')
        print(f'  Disk: {r.get("disk_model", "")}  S/N {r.get("disk_serial", "")}  ({r.get("capacity", "")}, {r.get("connection", "")})')
        print(f'  Action: {r.get("action", ""):<20} Result: {r.get("result", ""):<30} Duration: {r.get("duration", "")}')
        if r.get("readspeed_before"):
            print(f'  ReadSpeed before:      {r["readspeed_before"].replace(";", " / ")} MB/s (0/25/50/75/100%)')
        if r.get("readspeed_after"):
            print(f'  ReadSpeed after:       {r["readspeed_after"].replace(";", " / ")} MB/s (0/25/50/75/100%)')
        if r.get("spinrite_bench_before"):
            print(f'  SpinRite bench before: {r["spinrite_bench_before"].replace(";", " / ")} MB/s (front/mid/end)')
        if r.get("spinrite_bench_after"):
            print(f'  SpinRite bench after:  {r["spinrite_bench_after"].replace(";", " / ")} MB/s (front/mid/end)')
        if r.get("notes"):
            print(f'  Notes: {r["notes"]}')
        print("-" * 70)


def cmd_add(args):
    ensure_csv()
    computer_mfr = args.computer_mfr or dmidecode_field("system-manufacturer")
    computer_model = args.computer_model or dmidecode_field("system-product-name")
    computer_serial = args.computer_serial or dmidecode_field("system-serial-number")
    row = {
        "date_start": args.start or datetime.now().strftime("%Y-%m-%d %H:%M"),
        "date_end": args.end or "",
        "computer_mfr": computer_mfr,
        "computer_model": computer_model,
        "computer_serial": computer_serial,
        "disk_model": args.disk_model,
        "disk_serial": args.disk_serial,
        "capacity": args.capacity,
        "connection": args.connection,
        "action": args.action,
        "readspeed_before": args.rs_before or "",
        "readspeed_after": args.rs_after or "",
        "spinrite_bench_before": args.sr_bench_before or "",
        "spinrite_bench_after": args.sr_bench_after or "",
        "result": args.result or "",
        "duration": args.duration or "",
        "notes": args.notes or "",
    }
    with open(CSV_PATH, "a", newline="") as f:
        csv.DictWriter(f, fieldnames=FIELDS).writerow(row)
    print(f"Appended row for {row['disk_model']} (S/N {row['disk_serial']}) on {computer_model or 'unknown computer'}.")


def cmd_update(args):
    rows = read_rows()
    matches = [r for r in rows if r.get("disk_serial", "") == args.disk_serial]
    if args.start:
        matches = [r for r in matches if r.get("date_start", "") == args.start]
    if not matches:
        print(f"No row found for disk serial {args.disk_serial!r}" + (f" at {args.start!r}" if args.start else ""), file=sys.stderr)
        sys.exit(1)
    matches.sort(key=lambda r: r.get("date_start", ""))
    target = matches[-1]
    updates = {}
    for kv in args.set:
        if "=" not in kv:
            print(f"--set must be FIELD=VALUE, got: {kv}", file=sys.stderr)
            sys.exit(1)
        k, v = kv.split("=", 1)
        if k not in FIELDS:
            print(f"Unknown field: {k}. Valid fields: {', '.join(FIELDS)}", file=sys.stderr)
            sys.exit(1)
        updates[k] = v
    target.update(updates)
    write_rows(rows)
    print(f"Updated row for {target['disk_model']} (S/N {target['disk_serial']}, {target['date_start']}): {updates}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    rp = sub.add_parser("report")
    rp.add_argument("--computer")
    rp.add_argument("--disk")
    rp.set_defaults(func=cmd_report)

    ap = sub.add_parser("add")
    ap.add_argument("--computer-mfr")
    ap.add_argument("--computer-model")
    ap.add_argument("--computer-serial")
    ap.add_argument("--disk-model", required=True)
    ap.add_argument("--disk-serial", required=True)
    ap.add_argument("--capacity", required=True)
    ap.add_argument("--connection", required=True)
    ap.add_argument("--action", required=True)
    ap.add_argument("--start")
    ap.add_argument("--end")
    ap.add_argument("--rs-before")
    ap.add_argument("--rs-after")
    ap.add_argument("--sr-bench-before")
    ap.add_argument("--sr-bench-after")
    ap.add_argument("--result")
    ap.add_argument("--duration")
    ap.add_argument("--notes")
    ap.set_defaults(func=cmd_add)

    up = sub.add_parser("update")
    up.add_argument("--disk-serial", required=True)
    up.add_argument("--start")
    up.add_argument("--set", action="append", required=True)
    up.set_defaults(func=cmd_update)

    pp = sub.add_parser("path")
    pp.set_defaults(func=lambda args: print(CSV_PATH))

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
