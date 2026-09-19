# Tracking runs across machines

One USB stick, many machines, and passes that run for hours. Without a record you
end up re-scanning a drive that was already clean last month, or forgetting that
one drive was interrupted partway.

`bin/spinrite-track.py` manages a CSV that answers "what has this stick already
done, and to which drive on which computer".

## The data

Lives at `~/spinrite-tracker.csv` by default. The CSV is the source of truth —
the script only formats, appends and updates. Open it in a spreadsheet or a text
editor whenever you like.

One row per disk-action per session:

```
date_start, date_end,
computer_mfr, computer_model, computer_serial,
disk_model, disk_serial, capacity, connection,
action,
readspeed_before, readspeed_after,
spinrite_bench_before, spinrite_bench_after,
result, duration, notes
```

`examples/spinrite-tracker.example.csv` has the header plus one sample row.

### Computer identity is `dmidecode`, not hostname

Deliberately. This live USB always boots as the same hostname regardless of which
physical machine it is plugged into, so the hostname identifies nothing. The
script auto-fills manufacturer / product-name / serial-number from `dmidecode`.

Get a machine's serial yourself with:

```
sudo dmidecode -s system-serial-number
```

### The two benchmark column pairs are different formats, and not interchangeable

- `readspeed_*` — five semicolon-separated MB/s values, at 0/25/50/75/100% of the
  drive.
- `spinrite_bench_*` — three semicolon-separated MB/s values: front, midpoint,
  end of drive.

**Never compare a `readspeed_*` number to a `spinrite_bench_*` number.** They
measure different access paths and differ by roughly 4× on the same drive on the
same day. They are separate columns precisely so that nobody does this by
accident. Full explanation in `docs/field-notes.md`.

## Commands

**Check before you scan.** At the start of a session on any machine:

```
~/bin/spinrite-track.py report
~/bin/spinrite-track.py report --computer <serial-substring>
~/bin/spinrite-track.py report --disk <serial-substring>
```

Prints tracked runs most recent first, optionally filtered.

**Log a run** when it completes (or when it gets interrupted — an interrupted run
is exactly the thing worth recording):

```
~/bin/spinrite-track.py add \
  --disk-model "Example SSD 1TB" --disk-serial "SERIAL" \
  --capacity "1TB NVMe" --connection native-nvme \
  --action "SpinRite Level 3" \
  --rs-before "1500;1490;1210;1480;1495" \
  --rs-after  "1502;1498;1495;1490;1499" \
  --sr-bench-before "388;385;384" --sr-bench-after "390;389;387" \
  --result "Clean, 0 defects" --duration 2:12:26 \
  --notes "..."
```

`--connection` is one of `native-sata`, `native-nvme`, or `usb-<name>` — worth
being accurate about, since drives behind USB bridges behave differently under
sustained access (see `docs/field-notes.md`).

Computer identity auto-fills from `dmidecode`. Pass `--computer-mfr`,
`--computer-model` and `--computer-serial` explicitly when logging a run for a
*different* machine than the one you are sitting at — e.g. backfilling history.

**Fill in a value captured later**, such as an "after" benchmark taken once the
pass finished:

```
~/bin/spinrite-track.py update --disk-serial SERIAL \
  --set readspeed_after="1502;1498;1495;1490;1499" \
  --set result="Clean, 0 defects"
```

Matches the most recent row for that disk serial; narrow with `--start ISO` if
that disk has more than one row.

**Print the CSV path** (for scripting or backup):

```
~/bin/spinrite-track.py path
```

## Privacy

The real CSV contains drive serial numbers and computer service tags. It is in
`.gitignore` and is not part of this repo — ship
`examples/spinrite-tracker.example.csv` instead. `bin/spinrite-backup.sh` does
include it in the backup tarball, which is another reason that tarball must never
be committed.
