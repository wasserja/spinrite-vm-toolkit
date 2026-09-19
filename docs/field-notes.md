# Field notes

Observations from running this setup across a number of machines and drives.
These are the things that are not in any manual.

## Reading a ReadSpeed result

ReadSpeed reports MB/s at five points across the drive: 0%, 25%, 50%, 75%, 100%.

On an SSD or NVMe drive, **those five numbers should be roughly consistent**.
There is no mechanical geometry to explain a slow zone — unlike a spinning disk,
where outer tracks are genuinely faster than inner ones and a declining curve is
normal physics.

So a dip at one point on an SSD is a signal, not variance. Treat a low outlier as
a candidate for a SpinRite pass rather than shrugging it off.

**Caveat, learned the hard way:** unevenness that persists *after* a clean Level 3
pass (zero defects found) is most likely inherent to that drive's controller or
flash layout, not a defect. Observed on an NVMe drive whose 75% dip survived a
full pass. At that point it is a property of the drive, and re-running will not
change it.

## SpinRite's benchmark and ReadSpeed are not comparable

This one will mislead you badly if you miss it.

On the same NVMe drive on the same day: SpinRite's own benchmark (Main Menu
option 3) reported **~384–390 MB/s** front/mid/end, while ReadSpeed reported
**~1492–1646 MB/s**.

That is not a problem with the drive. Under raw-disk passthrough in this VM,
SpinRite's drive-select screen reports the access mode as `BIOS extend v3.0` —
its benchmark drives the disk through that BIOS-extended path, which caps
throughput far below the hardware's real capability. ReadSpeed apparently uses a
faster path for the same virtualized disk.

**Compare SpinRite-before to SpinRite-after, and ReadSpeed-before to
ReadSpeed-after. Never across tools.** The tracker stores them in separate columns
for exactly this reason (`docs/tracking.md`).

## SpinRite's initial ETA is not reliable

Shortly after a Level 3 run starts, the on-screen estimate can be wildly
optimistic. Observed: "1:32:55 remaining" at 0.18% progress, against an actual
total runtime of **4:16:14** — 2.7× longer, with zero defects or errors to
explain the difference.

Do not schedule anything around the initial ETA. A progress screenshot partway
through (say 30%) extrapolates far better.

For reference: SpinRite's own benchmark screen also prints an estimated
full-surface-scan duration. That is a read-only, Level-2-style estimate, not a
Level 3 read+write duration — 47.8 minutes estimated versus 2:12:26 actual on one
drive.

## Command-line AUTO mode replaces most of the menu navigation

SpinRite 6.1 accepts command-line tokens (case-insensitive, order-independent,
`/` prefix optional) that skip nearly the entire menu sequence. The full token
table is in `skills/virtualbox-dos-vm/SKILL.md`; the working command is:

```
SPINRITE auto level 3 both exit noramtest bios <port>
```

Confirmed behaviors:

- `auto` does **not** skip the RAM test screen — add `noramtest` for that, or
  send a blind Enter. `noramtest` skips SpinRite's RAM-reliability check, which
  matters slightly more than usual under Level 3 since it rewrites sectors; bad
  host RAM could in theory corrupt data undetected. A deliberate trade-off.
- `both` writes the before/after benchmark directly into the run's log at
  `C:\SRLOGS\<N>.LOG`, under "Drive's measured performance before/after running
  SpinRite" headers — no screenshot needed. The manual Main-Menu benchmark does
  not do this.
- **`bios <n>` and `port <n>` select exactly one drive and cannot be chained.**
  `bios 81 bios 82` drops to a help/error screen and runs nothing (a safe no-op).
  The wiki's wording is the tell: `BIOS`/`PORT` say "select **drive**", while
  `TYPE`/`MODEL`/`SERIAL`/`SIZE` say "select **drive(s)**" and match by pattern.
- **Untested idea:** under this VM, physical drives report Type `BIOS` while the
  FreeDOS system disk reports Type `ATA`, so `type bios` should match exactly the
  physical drives and exclude the system disk. Verify with
  `SPINRITE list exit type bios` before ever combining `type` with
  `auto level 3` on real hardware.
- **Fallback that always works:** one command per drive, sequentially. SpinRite
  processes multiple selected drives one at a time anyway.

## Multiple selected drives run sequentially

DOS is single-tasking, so this is expected — but it affects how you read the
progress screen. The `megabytes: remaining/completed` figures **reset for each
drive** as it becomes active. Use the total (remaining + completed) matched
against known capacities to work out which drive is currently running, and expect
the on-screen ETA to cover only the active drive, not the whole job.

## The results menu can drop into an unexpected ReadSpeed run

Observed once, not fully root-caused: on the "SpinRite has concluded all pending
operations" screen, pressing SPACEBAR then a number key to pick "Detailed
Technical Log" instead landed back at a `C:\>` prompt showing a freshly-run
ReadSpeed report. Useful either way — a ReadSpeed run right after a refresh pass
is exactly the after-measurement you want — but do not assume number-key menu
navigation reliably lands where the menu says. Screenshot after each keypress.

## Live throughput sanity check from the host

To confirm a pass is actually doing work, without touching the VM:

```
cat /sys/block/<dev>/stat; sleep 3; cat /sys/block/<dev>/stat
```

Fields (space-separated, 1-indexed): 1 = reads completed, 3 = sectors read,
5 = writes completed, 7 = sectors written. Diff two samples, multiply sectors by
512 for bytes, divide by elapsed seconds.

Balanced read + write throughput ≈ a Level 3 refresh pass (read-verify-rewrite).
Read-only ≈ a benchmark or scan pass.
