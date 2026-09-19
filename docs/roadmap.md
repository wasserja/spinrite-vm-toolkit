# Roadmap

What is untested, unmeasured or unbuilt. Kept here so that "we never checked" does
not quietly turn into "we know".

## Validate the batching procedure on a machine with more drives than slots

`docs/workflow.md` §3a says to work drives in batches when there are more of them
than the VM can carry, and `bin/spinrite-attach.sh` now refuses an over-capacity
selection and suggests a first batch. That path has never run against a real
over-capacity machine — it was verified with a forced disk list, not real hardware.

**The rest of the reworked CLI is now verified on real hardware** (2026-09-19, a
single-disk Lenovo laptop with a mounted SATA M.2 SSD). `attach <name> --yes` ran
end to end: it refused nothing it should have allowed, detached two stale media left
on the AHCI controller by a previous machine's session, unmounted the live
filesystem, reused the existing size-matched raw pointer, attached to port 0 and
launched the VM to a `C:\>` prompt, where ReadSpeed saw exactly the one physical
drive. All thirteen read-only and error paths were re-checked first and none of them
touched a disk. What is still unverified is specifically the **multi-disk** case:
that `attach sdb sdc` attaches exactly those two and no others, and the batching
procedure below.

What to find out while doing it:

- Where the real ceiling is. AHCI `PortCount` is 3 as built and raising it is one
  command, but SpinRite sees these disks as BIOS-attached drives, so the guest BIOS
  drive table may cap them lower than `PortCount` does. Untested past 3.
- Whether raising `PortCount` to 4+ actually makes the extra drives visible to
  SpinRite, or only to VirtualBox.
- Whether SpinRite's per-drive resume state survives a drive being detached and
  re-attached in a later batch.

## Decide whether to move physical disks from AHCI to IDE

**The measurement is done, twice** (2026-09-19, `docs/field-notes.md`): SpinRite's
Level 3 runs **2.08x faster** on `PIIX4`/IDE than on `AHCI` on a SATA SSD (179 s
versus 372 s), and **2.58x faster** on an NVMe (24 s versus 62 s, median of three
alternated legs each). Its native ATA driver engages instead of the BIOS path. Two
drives on two buses agree and the per-leg timings barely vary, so the effect is no
longer in doubt. What is left is the decision.

The capacity argument that justified AHCI is weaker than it looked. `PIIX4` has
2 ports x 2 devices = 4 slots, one taken by the FreeDOS `C:` disk, leaving **3** —
exactly what `AHCI` is configured for today. So at the current setting IDE costs
nothing in drive count and halves the runtime. AHCI only wins if its portcount can
actually go past 3, which is itself unverified (see the PortCount item below).

### Done: repeated on an NVMe, 2026-09-19 -- the result got bigger

**The SATA finding generalizes.** One SK hynix HFS256GEM9X169N (238.5 GB NVMe),
three Level 3 legs per controller, alternating A/I/A/I/A/I, same bounded region
(`75.0 80.0`, 11.92 GiB verified at the block layer on every leg):
**IDE is 2.58x faster** -- 24 s median against 62 s -- versus 2.08x on the SATA
drive.

The doubt recorded here, that NVMe drives reaching 600-724 MB/s through the AHCI
BIOS path were nowhere near the ceiling the SATA drive hit, was wrong. The BIOS
path caps this drive at ~197 MB/s effective while SpinRite's own ATA driver
sustains ~509 MB/s over the identical region. Full numbers in
`docs/field-notes.md`.

Two things settled on the way past:

- **The benchmark predicts pass throughput better than feared.** Level 3 ran at 32%
  of SpinRite's own midpoint benchmark here (197 against 622 MB/s), close to the
  37% seen on the SATA drive. That ratio looks stable enough to estimate from --
  unlike SpinRite's on-screen ETA, which the tracker records missing by 2.7x.
- **Level 3 timing barely varies.** Three AHCI legs took 62 s each. Whatever makes
  a multi-hour full pass overrun its estimate, it is not run-to-run noise in the
  pass itself.

`bin/spinrite-attach.sh` now takes `--controller ahci|ide`, so switching is a flag
rather than a source edit and the two can be compared without hand-run
`storageattach` commands. The **default is still AHCI**. What stands between the
measurement and changing that default:

- **A spinning disk has never been measured.** Both data points are solid state.
- **Neither drive had a single defect.** The forum reply arguing AHCI wins is
  specifically about drives *with* errors, where DynaStat recovery dominates and
  the access path may matter differently there. Completely untested.
- Confirm 3 drives attach and enumerate correctly across `PIIX4` port 0 device 1,
  port 1 device 0 and port 1 device 1. Only single-drive IDE has been exercised.
- Decide what happens to ReadSpeed. It reads *faster* on AHCI (flat ~460 MB/s versus
  a 308 -> 126 decline on IDE), so moving to IDE makes the ReadSpeed baseline both
  slower and less flat. Since before/after pairs are only comparable within one
  controller, switching mid-fleet would break comparisons against every row already
  in the tracker.

## Test the `type bios` multi-drive selector

`BIOS <n>` and `PORT <n>` select exactly one drive and cannot be chained, so a
multi-drive run is currently one command per drive.

**Half of this is now answered** (2026-09-19). `SPINRITE list exit noramtest` does
report the AHCI-passthrough physical disk as Type `BIOS` (Port and BIOS both `81`)
and the FreeDOS system disk as Type `ATA` (Port `PM`), so `type bios` describes
exactly the physical drives. Two things came out of the same check:

- `list` **also** stops on the RAM test screen — the command above needs
  `noramtest`, which the previous version of this item was missing.
- The physical drive's Model and Serial columns read `....`, so `MODEL`/`SERIAL`
  selectors cannot address a passthrough drive at all. `BIOS`, `PORT` and
  `TYPE bios` are the only ways in.

What remains is the part that would actually save time: whether `type bios` selects
**several** physical drives in one command when several are attached. Verify the
matched set with `SPINRITE list exit noramtest type bios` before ever combining
`type` with `auto level 3`. See `docs/field-notes.md`.

## Decide from ReadSpeed whether a pass is needed, and how much of one

Right now the decision to run Level 3 is a judgement call made by eye from
ReadSpeed's five numbers. It could be a rule, and the rule could also choose a
*bounded* region instead of the whole drive — which matters because Level 3 is a
read **and rewrite** pass, and SpinRite's own drive-select screen warns it is not
recommended for SSDs. Every percent not rewritten is write endurance not spent.

The shape of it:

1. Take the five ReadSpeed points (0/25/50/75/100%), which
   `spinrite-track.py` already stores as `readspeed_before`.
2. Compare each against the others — deviation from the median is probably the
   right statistic, not the mean, so one bad point cannot drag the baseline.
3. Below some threshold, report "no pass needed" and stop.
4. Above it, map the offending sample point(s) to a percentage range and emit the
   ready-to-run command, now that the `Range` token is confirmed to work
   (`bios <n> 75.0 80.0`, see below).

The open questions are what make this worth doing carefully rather than quickly:

- **What threshold? Bigger than you think — the noise floor is now measured.**
  Repeating ReadSpeed on one clean NVMe the same afternoon (8 runs on AHCI, 6 on
  IDE, `docs/field-notes.md`) gave per-point run-to-run spreads of **7.6% to 34.5%
  on AHCI** and 2.1% to 15.3% on IDE. The worst AHCI point moved **34.5%** on a
  drive with zero defects that had not changed. That is *twice* the 17% dip this
  item was originally written to catch, so a threshold anywhere near 17% would fire
  almost entirely on noise.

  Three things follow, and they change the design rather than just the number:

  1. **Require repeats.** A single reading cannot distinguish a slow region from
     the instrument. The rule should take a median of N runs, not one sample.
  2. **Use cross-controller agreement as the real signal.** The test drive's 25%
     point sat 49% below its 50% point on AHCI *and* 66% below on IDE. Two
     unrelated access paths agreeing cannot be an artifact of either one. Now that
     `spinrite-attach.sh --controller` makes the second measurement cheap, "dips on
     both paths" is a far stronger trigger than any single-path threshold — and it
     does not need a threshold calibrated per bus.
  3. **Consider driving the rule from SpinRite's benchmark instead.** On the same
     drive and session it repeated to within **1.7-2.0%** on AHCI, against
     ReadSpeed's 7.6-34.5%. It only gives three points (front/mid/end) rather than
     five, and it costs a SpinRite invocation, but it is an order of magnitude
     quieter. A rule built on a noisy instrument will spend hours of rewriting on
     measurement error.
- **A sample point is a spot, not a region.** ReadSpeed measures at five
  locations; a dip at the 75% sample does not establish where the slow region
  starts or ends. Scanning the midpoints to each neighbour (62.5-87.5% for a bad
  75%) is the obvious first guess and is exactly that — a guess.
- **Spinning disks need a different rule entirely.** A declining outer-to-inner
  curve is normal physics on an HDD, so "should be flat" only holds for SSD and
  NVMe (`docs/field-notes.md`). An HDD rule has to compare against an expected
  decline, not against flatness.
- **Do not recommend a re-run on a drive that already passed clean.**
  `docs/field-notes.md` records unevenness surviving a clean Level 3 pass, which
  makes it a property of the drive's controller or flash layout rather than a
  defect. The tracker already knows which drives have passed; the rule has to
  consult it instead of re-recommending the same drive forever.
- **The rule may need to recommend *nothing*, and that is now the likeliest
  outcome for a clean SSD.** Tested directly on 2026-09-19: a genuine slow region
  (confirmed on both controllers) was given the bounded pass this item proposes to
  emit, and came back **8-9% slower on both paths** with zero defects found
  (`docs/field-notes.md`). One drive, one region, one pass -- but it inverts the
  premise. Before this becomes an `advise` verb that tells someone to spend hours
  rewriting, it needs to answer whether a pass on a defect-free solid-state region
  ever *helps*, because right now the only controlled measurement says it hurts.

Natural home: a new verb on `bin/spinrite-track.py`, which already owns the
benchmark columns and the per-drive history — something like
`spinrite-track.py advise --disk <serial>`, printing either "no pass needed" or
the bounded command to run.

## Find out whether the post-pass slowdown recovers

A bounded Level 3 over a clean NVMe's slow region left it reading 8-9% slower on
both controllers (2026-09-19, `docs/field-notes.md`). Unknown, and cheap to learn:
**does it come back?** An SSD may re-optimise over hours or days of normal use, or
during idle garbage collection, in which case the measurement above is a transient
cost rather than a permanent one -- which changes the advice completely.

The drive is this machine's own system disk (SK hynix HFS256GEM9X169N, S/N
5SE4N503314104K5B), so it is reachable again on any later visit. Roughly 5 minutes:

```
~/bin/spinrite-attach.sh attach 5SE4N503 --controller ahci --yes
#   in the guest: rs, three times; then --controller ide and rs three times
```

Compare the 25% point against the post-pass medians (AHCI 1579.9, IDE 381.0) and
the pre-pass ones (AHCI 1743.3, IDE 415.2). Worth doing after the machine has been
running Windows normally for a while, not straight off a cold boot.

Two things to settle at the same time:

- Whether the *other* four points stayed where they were, which is what makes the
  25% reading attributable to the pass rather than to drift.
- Whether the SLC-cache-folding hypothesis in `docs/field-notes.md` predicts
  recovery at all. If the data is now in TLC it may simply stay there.

## Target a Level 3 pass at a bounded region of a drive

`skills/virtualbox-dos-vm/SKILL.md` documents a `Range` token —
`<selector> <start%> [<end%>]`, or `#<startsector> [#<endsector>]`, percentages
requiring a decimal point — so

```
SPINRITE auto level 3 both exit noramtest bios 81 75.0 100.0
```

should refresh only the last quarter of a drive.

**The syntax is confirmed** (2026-09-19). `spinrite auto level 3 exit noramtest
bios 81 75.0 80.0` ran twice, and the Graphic Status Display opened at `75.0554%`
with 25,605 MB of work queued — 5% of a 512 GB drive. The host's
`/sys/block/sda/stat` write counter moved by exactly 25.6 GB per run, so the bound
is real at the block layer and not just on screen. SpinRite's Main Menu confirms it
in words too: *"Selected items may be resumed after interruption by specifying a
starting and ending percentage, other than 0% and 100%."* The ETA was accurate to
within ~10 s on a bounded pass, unlike the wild first estimates a full pass gives.

It is worth confirming because a whole-drive Level 3 costs 1-4 hours while the
interesting region is often a fraction of the drive. `docs/field-notes.md` records
exactly such a case: a 512 GB SATA M.2 reading
`465.5 / 461.9 / 460.9 / 463.1 / 384.3` MB/s — four points at the SATA III ceiling
and a **100% mark ~17% low**. A targeted pass on that last quarter, re-benchmarked,
would take minutes instead of hours, and would settle whether the dip is a defect
or inherent to the drive (see the caveat in `docs/field-notes.md`).

What to find out:

- What a percentage written **without** a decimal point does. Only the decimal
  form has been exercised.
- Whether `100.0` as an end bound behaves like any other value — the Main Menu help
  says resumption works "other than 0% and 100%", which hints those two are special.
- ~~Whether the `both` benchmark still means anything on a bounded pass.~~
  **Answered 2026-09-19: it benchmarks the whole drive regardless of the range.**
  A pass bounded to 75-80% still logs front / midpoint / end of drive. So the
  before/after pairing the tracker stores stays comparable with full-pass rows —
  but it is *not* a measurement of the bounded region, and must not be read as one.
- Whether `#<startsector>` and the percentage form can be mixed.
- ~~Whether the log entry distinguishes a bounded pass from a full one.~~
  **Answered 2026-09-19: it does.** A bounded run logs
  `From  75.0000% sect: 375,088,640      To  80.0000% sect: 400,094,552`, where a
  whole-drive run reads `From   0.0000% sect: 0  To 100.0000% sect: ...`. The
  tracker's `action`/`notes` columns should still say so, since nobody consults the
  log before reading the row.

## Raise `AHCI` PortCount past 3 and find the guest BIOS ceiling

`bin/spinrite-vm-build.sh` leaves the appliance's `AHCI` portcount at 3, because
that is what has been tested. Raising it is one command
(`VBoxManage storagectl <vm> --name AHCI --portcount <n>`, up to 30), but SpinRite
reaches these disks as BIOS-attached drives, so the guest BIOS drive table may cap
them lower than `PortCount` does. Until that is tested on a machine with enough
drives, the batching procedure in `docs/workflow.md` §3a stays the documented
answer. Same unknown as the first item on this page, approached from the other
side.
