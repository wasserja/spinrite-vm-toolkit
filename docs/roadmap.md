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

**The measurement is done** (2026-09-19, `docs/field-notes.md`): SpinRite's Level 3
runs **2.08x faster** on `PIIX4`/IDE than on `AHCI` — 179 s versus 372 s over the
same 25,605 MB region of the same SSD — because its native ATA driver engages
instead of the BIOS path. What is left is the decision, which one drive on one
machine does not settle.

The capacity argument that justified AHCI is weaker than it looked. `PIIX4` has
2 ports x 2 devices = 4 slots, one taken by the FreeDOS `C:` disk, leaving **3** —
exactly what `AHCI` is configured for today. So at the current setting IDE costs
nothing in drive count and halves the runtime. AHCI only wins if its portcount can
actually go past 3, which is itself unverified (see the PortCount item below).

### Queued: repeat the measurement on an NVMe (next machine with a spare one)

The SATA result may not generalize, and the tracker is the reason to doubt it. The
Toshiba SATA SSD benchmarked **184 / 207 / 143 MB/s** through the AHCI BIOS path,
but NVMe drives already in the tracker reach **600-724 MB/s** through that same
path (Samsung 980 1TB, 970 EVO Plus 2TB). They are plainly not hitting the ceiling
the SATA drive hit, so the headroom IDE recovered may simply not be there.

Roughly 15 minutes, on any machine with an NVMe that is not the repo disk:

```
~/bin/spinrite-attach.sh attach <serial-substring> --yes     # lands on AHCI
#   in the guest:
SPINRITE list exit noramtest                                  # expect Type BIOS
rs                                                            # ReadSpeed, screenshot
spinrite auto level 3 exit noramtest bios 81 75.0 80.0        # time it

#   then, VM off, move the SAME .vmdk to IDE and repeat identically:
VBoxManage storageattach SRDOS --storagectl AHCI  --port 0 --device 0 --type hdd --medium none
VBoxManage storageattach SRDOS --storagectl PIIX4 --port 1 --device 0 --type hdd --medium <the .vmdk>
#   expect Type to flip to ATA / Port SM, with Model+Serial populated
```

Record wall-clock for each Level 3 leg and cross-check against the host's
`awk '{print $7}' /sys/block/<dev>/stat` delta, which should equal the region size
on both legs (it did here: 25.6 GB each, exactly 5% of 512 GB).

Two traps from doing it the first time: use `--type gui` via the detached `nohup`
form, and do **not** leave a `showvminfo` wait-loop polling, or `startvm` fails with
"already locked by a session" (`docs/troubleshooting.md` §2 and §2a).

One more thing worth capturing while there: today's Level 3 ran at 68.8 MB/s
effective against a 184 MB/s read benchmark, ~37%. Applying that ratio to the 980's
600 MB/s predicts a 1 TB pass in ~1h15m, but the tracker records 4:16:14. So the
benchmark is a poor predictor of pass duration and something else dominates a long
run. Whatever that is, it may matter more than the controller.

Before changing `CONTROLLER` in `bin/spinrite-attach.sh`:

- Repeat on at least one spinning disk and one NVMe — the NVMe leg is queued above
  with a ready-to-run procedure. The DynaStat behaviour the forum reply describes
  only appears on drives with real errors, where the reply claims AHCI wins;
  untested here, since this drive was clean.
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

- **What threshold?** Unknown, and a single reading is not enough to set one. The
  512 GB SATA M.2 in the reference machine measured its 100% point **17% below**
  the other four on 2026-09-19, and **~10% below** on the same drive, same
  machine, a few hours later with no pass in between (384.3 then 417.8 MB/s,
  against ~460-466 across the rest). So run-to-run variance is real and a rule
  that fires on one sample will fire inconsistently. The rule may need to require
  a repeat measurement before recommending hours of rewriting.
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

Natural home: a new verb on `bin/spinrite-track.py`, which already owns the
benchmark columns and the per-drive history — something like
`spinrite-track.py advise --disk <serial>`, printing either "no pass needed" or
the bounded command to run.

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
- Whether the `both` benchmark still means anything on a bounded pass, or whether it
  benchmarks the whole drive regardless — which would break the before/after pairing
  the tracker stores.
- Whether `#<startsector>` and the percentage form can be mixed.
- Whether the log entry in `C:\SRLOGS\<N>.LOG` distinguishes a bounded pass from a
  full one. If it does not, the range has to go in the tracker's `notes` column, or a
  later reader will take a "Clean, 0 defects" row for a full pass.

## Raise `AHCI` PortCount past 3 and find the guest BIOS ceiling

`bin/spinrite-vm-build.sh` leaves the appliance's `AHCI` portcount at 3, because
that is what has been tested. Raising it is one command
(`VBoxManage storagectl <vm> --name AHCI --portcount <n>`, up to 30), but SpinRite
reaches these disks as BIOS-attached drives, so the guest BIOS drive table may cap
them lower than `PortCount` does. Until that is tested on a machine with enough
drives, the batching procedure in `docs/workflow.md` §3a stays the documented
answer. Same unknown as the first item on this page, approached from the other
side.
