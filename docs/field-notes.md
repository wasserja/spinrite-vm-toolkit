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

A SATA SSD reads far lower than an NVMe one and that is just the bus, not a
finding: a 512 GB SATA M.2 measured `465.5 / 461.9 / 460.9 / 463.1 / 384.3` MB/s
(2026-09-19) — the first four sit right at the SATA III ceiling, and it is the
**384.3 at the 100% mark**, ~17% below the rest, that is worth noting. Compare the
shape of the five numbers, never their absolute level against a different bus.

**Caveat, learned the hard way:** unevenness that persists *after* a clean Level 3
pass (zero defects found) is most likely inherent to that drive's controller or
flash layout, not a defect. Observed on an NVMe drive whose 75% dip survived a
full pass. At that point it is a property of the drive, and re-running will not
change it.

## SpinRite's benchmark and ReadSpeed are not comparable

This one will mislead you badly if you miss it.

On the same NVMe drive on the same day: SpinRite's own benchmark reported
**~384-390 MB/s** front/mid/end, while ReadSpeed reported **~1492-1646 MB/s**.

That is not a problem with the drive — it is the controller choice. Under raw-disk
passthrough here, SpinRite's drive-select screen reports the access mode as
`BIOS extend v3.0`, and the upstream guide (forum part 3b) says why. Of the two
controller options it compares:

- **IDE** — *"Can only add up to 3 drives, as IDE only supports 4 total"*, but
  *"Faster operation (SpinRite native IDE driver works)"*.
- **AHCI** — *"Can have up to 30 drives (ports 0 to 29)"*, but *"Drives are seen as
  BIOS attached; SpinRite native AHCI doesn't work for some reason"* and *"BIOS
  access may be an order of magnitude slower than IDE (or the same speed, you need
  to test and see!!)"*.

This toolkit attaches to AHCI, so SpinRite drives the disk through that
BIOS-attached path rather than its own driver, which caps throughput far below the
hardware. ReadSpeed evidently uses a faster path for the same virtualized disk.

Worth noting that a reply in the same thread disputes the ordering: *"In my tests
using VirtualBox's AHCI Controller is actually much faster when you deal with actual
errors on a SATA drive...It's almost native speed as in DOS. VirtualBox's IDE
controller took forever to mark a bad block."* Nobody here has measured it either
way — see `docs/roadmap.md`.

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

- **The RAM test screen comes up for *every* invocation, not just `auto`** — it
  precedes even a pure enumeration. `SPINRITE list exit` stops on "Testing System
  RAM" and waits for Enter; `SPINRITE list exit noramtest` goes straight to the
  table. Verified 2026-09-19. Put `noramtest` in any command you expect to run
  unattended, including read-only ones. `noramtest` skips SpinRite's
  RAM-reliability check, which matters slightly more than usual under Level 3 since
  it rewrites sectors; bad host RAM could in theory corrupt data undetected. A
  deliberate trade-off.
- `both` writes the before/after benchmark directly into the run's log at
  `C:\SRLOGS\<N>.LOG`, under "Drive's measured performance before/after running
  SpinRite" headers — no screenshot needed. The manual Main-Menu benchmark does
  not do this.
- **`bios <n>` and `port <n>` select exactly one drive and cannot be chained.**
  `bios 81 bios 82` drops to a help/error screen and runs nothing (a safe no-op).
  The wiki's wording is the tell: `BIOS`/`PORT` say "select **drive**", while
  `TYPE`/`MODEL`/`SERIAL`/`SIZE` say "select **drive(s)**" and match by pattern.
- **The Type split is confirmed** (2026-09-19, one physical disk attached).
  `SPINRITE list exit noramtest` prints:

  ```
  Type |Port|BIOS|Runtime|Size|        Model         |      Serial
  -----+----+----+-------+----+----------------------+------------------
  ATA  | PM | 80 |  ...  |105M|VBOX HARDDISK         |VBxxxxxxxx-xxxxxxxx
  BIOS | 81 | 81 |  ...  |512G|        ....          |       ....
  ```

  The FreeDOS system disk on the IDE controller reports Type `ATA` (Port `PM`,
  primary master); the AHCI-passthrough physical disk reports Type `BIOS`, with
  Port and BIOS both `81`. So `type bios` does describe exactly the physical
  drives and excludes the system disk. Still unverified with **more than one**
  physical drive attached — that is the part that would actually collapse one
  command per drive into one command, and it is still on the roadmap. Check the
  matched set with `SPINRITE list exit noramtest type bios` before ever combining
  `type` with `auto level 3`. Not while another DOS operation is running: DOS is
  single-tasking.
- **`MODEL`, `SERIAL` and `SIZE`-by-text selectors are unusable on passthrough
  drives.** In the table above the physical drive's Model and Serial columns are
  literally `....` — SpinRite reaches AHCI-attached disks through the BIOS and
  never sees their identity strings. Only `BIOS <n>`, `PORT <n>` and `TYPE bios`
  can select them. (Host-side selection by serial, i.e. the `spinrite-attach.sh`
  roadmap item, is unaffected — that runs on Linux, which does see the serial.)
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

## Corrections worth remembering

Things that were believed here and turned out to be wrong. Kept because the wrong
version is plausible enough to be re-invented.

**`SPINRITE.EXE` and `RS.EXE` do not auto-run on boot.** An early session recorded
that they did — either a misreading or a since-changed `AUTOEXEC.BAT`. They are
launched from the `C:\>` prompt, normally by the user. Do not screenshot-poll a
freshly booted VM expecting a benchmark to already be in flight.

**An interrupted pass did not resume where it stopped.** A drive interrupted at
1.4116% restarted from 0% on the next session rather than continuing. The likely
cause is that the attach script created its VMDK pointer under a different by-id
alias than the interrupted run used, so SpinRite's resume-state tracking did not
recognise it as the same drive. If resuming matters, force it explicitly with a
start percentage rather than trusting the "Before Beginning" screen's default:

```
SPINRITE auto level 3 exit bios 81 1.4116 100.0
```
