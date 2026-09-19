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

**But not from a single run.** Measured repeatedly on 2026-09-19, one ReadSpeed
point on a clean NVMe moved **34.5% between runs** on the AHCI path — twice the
size of the 17% dip described below as worth noting. One reading cannot tell a
slow region from the instrument's own noise. Repeat the measurement, and prefer a
dip that shows up on *both* controllers, which no single access path's artifact
can explain. See "ReadSpeed's own noise is bigger than the dips it is used to
flag" below.

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

A reply in the same thread disputes the ordering: *"In my tests using VirtualBox's
AHCI Controller is actually much faster when you deal with actual errors on a SATA
drive...It's almost native speed as in DOS. VirtualBox's IDE controller took forever
to mark a bad block."*

### Measured, 2026-09-19: SpinRite is ~2x faster on IDE, ReadSpeed is faster on AHCI

One 512 GB SATA M.2 SSD, one machine, one afternoon, the same raw `.vmdk` pointer
moved between `AHCI` port 0 and `PIIX4` port 1. Same bounded region on both legs
(`75.0 80.0`, 25,605 MB) so the comparison covers identical media.

| | AHCI | IDE (PIIX4) |
|---|---|---|
| SpinRite Type / Port | `BIOS` / 81 | `ATA` / SM |
| SpinRite Model + Serial | `....` (unreadable) | `VBOX HARDDISK` / `VBf9228443-…` |
| SpinRite benchmark, front / mid / end | 184.1 / 207.1 / 143.2 MB/s | **228.5 / 328.6 / 312.6 MB/s** |
| SpinRite full-scan estimate | 45.3 min | **28.6 min** |
| Random sector time | 0.257 ms | **0.223 ms** |
| **Level 3 over 25,605 MB** | **372 s** (68.8 MB/s) | **179 s (143.0 MB/s)** |
| ReadSpeed 0/25/50/75/100% | **466.4 / 460.2 / 462.0 / 460.8 / 417.8** | 308.9 / 236.5 / 306.5 / 197.1 / 126.1 |
| Defects found | 0 | 0 |

**The two tools disagree about which controller is better, and both are right.**
SpinRite's native ATA driver engages on IDE and roughly doubles Level 3 throughput —
2.08x on the measurement that actually costs hours. ReadSpeed is the other way round,
reading ~1.5x faster on AHCI with a far flatter curve. They use different access
paths, so each is measuring its own path, not the drive.

Two consequences that bite:

- **Never compare a ReadSpeed number across controllers.** The IDE column above
  declines 308 → 126 across the drive. That is the access path, not the media —
  the same drive on AHCI is flat at ~460. A before/after ReadSpeed pair is only
  meaningful if both halves ran on the same controller.
- **`MODEL` and `SERIAL` selectors work on IDE and not on AHCI.** A
  BIOS-attached drive reports its identity columns as `....`, which is why
  `BIOS`/`PORT`/`TYPE bios` are the only selectors that can address one. On IDE the
  columns populate — though with VirtualBox's synthetic identity derived from the
  medium UUID, not the drive's real serial, so `SERIAL <real-serial>` still will not
  match.

The upstream claim that BIOS access "may be an order of magnitude slower" overstates
it here — the gap is 2x on writes, not 10x. And the forum reply arguing AHCI is
faster was about drives *with real errors*, where DynaStat recovery dominates; this
drive had none, so that case remains untested.

**Compare SpinRite-before to SpinRite-after, and ReadSpeed-before to
ReadSpeed-after. Never across tools.** The tracker stores them in separate columns
for exactly this reason (`docs/tracking.md`).

### Repeated on an NVMe, 2026-09-19: the SATA result holds, and gets bigger

The SATA measurement above was one drive, one leg each. The doubt recorded on the
roadmap was that it might not generalize -- NVMe drives reach 600-724 MB/s through
the AHCI BIOS path where that SATA SSD managed 184, so they looked like they were
nowhere near the ceiling IDE was recovering. **They are.**

One SK hynix HFS256GEM9X169N (238.5 GB NVMe, this machine's BitLocker-encrypted
Windows system disk), same bounded region `75.0 80.0` (11.92 GiB, verified at the
host block layer on every single leg), **three Level 3 legs per controller**, run
**alternating A/I/A/I/A/I** so thermal and drive-state drift is shared between the
legs rather than landing on whichever ran second.

| | AHCI | IDE (PIIX4) |
|---|---|---|
| SpinRite Type / Port | `BIOS` / 81 | `ATA` / PS |
| SpinRite Model + Serial | `....` (unreadable) | `VBOX HARDDISK` / `VB8fd2cfb3-…` |
| SpinRite benchmark, front / mid / end (median of 4) | 367.4 / 622.1 / 627.6 MB/s | **453.2 / 1219.0 / 1229.5 MB/s** |
| ...its run-to-run spread | 1.8% / 2.0% / 1.7% | 0.9% / 6.2% / 7.4% |
| **Level 3 over 11.92 GiB** | 62 / 62 / 62 s (**196.9 MB/s**) | **24 / 26 / 24 s (508.7 MB/s)** |
| ReadSpeed 0/25/50/75/100% (median) | **2670 / 1768 / 3467 / 2854 / 2467** | 1161 / 414 / 1204 / 766 / 586 |
| Defects found | 0 (4 runs) | 0 (4 runs) |

**IDE is 2.58x faster at Level 3 here, against 2.08x on the SATA drive.** The
NVMe-has-headroom hypothesis is dead: the BIOS path caps this drive at ~197 MB/s
effective even though the same drive sustains ~509 MB/s through SpinRite's ATA
driver. Level 3 timing is also almost perfectly reproducible -- three AHCI legs at
62 s each -- so the controller effect is far larger than the run-to-run noise.

Both directions of the SATA finding reproduced: SpinRite faster on IDE, ReadSpeed
faster on AHCI, `MODEL`/`SERIAL` readable only on IDE (and synthetic there).
Attaching at PIIX4 port 0 device 1 reports Port `PS` rather than the `SM` the SATA
test saw at port 1 device 0; `bios 81` selects the drive on either controller, so
the selector does not change when you switch.

Two details only the IDE logs carry: an ATA identity block (`max transfer: ultraDMA
133 MB/s`, `ultradma modes: 2/6 (33.33 MB/s)`, `sector count: 500,118,192`), absent
from every AHCI log. **Ignore the advertised UDMA mode** -- it says 33.33 MB/s while
the same run measures 1.2 GB/s. It describes VirtualBox's emulated PIIX4, not the
hardware.

### ReadSpeed's own noise is bigger than the dips it is used to flag

This is the finding that changes how the numbers should be read, and it only shows
up once the same drive is measured repeatedly on the same day.

| ReadSpeed point | AHCI spread over 8 runs | IDE spread over 6 runs |
|---|---|---|
| 0% | 11.5% | 13.4% |
| 25% | 14.2% | **2.1%** |
| 50% | 10.7% | 10.9% |
| 75% | **34.5%** | 15.3% |
| 100% | 7.6% | **2.9%** |

**A single ReadSpeed point on AHCI moved 34.5% across runs of an unchanged, clean,
zero-defect drive.** For comparison, the dip that `docs/roadmap.md` proposes to
treat as a pass-worthy signal -- the SATA M.2's 100% mark -- was **17% low**. The
measurement noise is twice the size of the signal. Any threshold rule that fires on
one AHCI reading is firing on noise.

Three consequences:

- **Never decide from a single ReadSpeed run.** Repeat it; the repeats cost seconds.
- **SpinRite's own benchmark is the more stable instrument** -- 1.7-2.0% spread on
  AHCI against ReadSpeed's 7.6-34.5% on the same drive, same session. It is slower
  to obtain and measures a different path, but if the question is "has this drive
  changed", it answers it with far less noise.
- **A dip on both controllers is the drive; a dip on one is the access path.** This
  drive's 25% point sits 49% below its 50% point on AHCI *and* 66% below on IDE.
  Two unrelated access paths agreeing is hard to explain as an artifact of either,
  so that region is a genuine property of the drive -- and a real candidate for a
  bounded pass, which is a much stronger basis than one low number on one run.

For the record, 24 Level 3 passes' worth of rewriting (8 runs x 11.92 GiB = 95 GiB)
over the same region produced no measurable degradation and no defects, and the
drive's SMART `Media and Data Integrity Errors` stayed at 0.

### Two bounded-pass questions, answered

- **The log distinguishes a bounded pass from a full one.** Every bounded run wrote
  `From  75.0000% sect: 375,088,640      To  80.0000% sect: 400,094,552`, where a
  whole-drive run in the same `SRLOGS` directory reads `From   0.0000% sect: 0
  To 100.0000% sect: 1,953,525,167`. A later reader cannot mistake one for the
  other, so the range does not have to be carried in the tracker's notes -- though
  the tracker's `action` column should still say so, since nobody reads the log
  first.
- **`both` benchmarks the whole drive regardless of the range.** On a pass bounded
  to 75-80%, the logged benchmark still reports *front / midpoint / end* of the
  drive. So a before/after pair stays comparable with full-pass rows, and it is
  **not** a measurement of the bounded region.

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
