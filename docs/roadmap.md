# Roadmap

What is untested, unmeasured or unbuilt. Kept here so that "we never checked" does
not quietly turn into "we know".

## Validate the batching procedure on a machine with more drives than slots

`docs/workflow.md` §3a says to work drives in batches when there are more of them
than the VM can carry, and `bin/spinrite-attach.sh` now refuses an over-capacity
selection and suggests a first batch. That path has never run against a real
over-capacity machine — it was verified with a forced disk list, not real hardware.

What to find out while doing it:

- Where the real ceiling is. AHCI `PortCount` is 3 as built and raising it is one
  command, but SpinRite sees these disks as BIOS-attached drives, so the guest BIOS
  drive table may cap them lower than `PortCount` does. Untested past 3.
- Whether raising `PortCount` to 4+ actually makes the extra drives visible to
  SpinRite, or only to VirtualBox.
- Whether SpinRite's per-drive resume state survives a drive being detached and
  re-attached in a later batch.

## Measure IDE vs AHCI throughput on the same drive

Upstream (forum part 3b) says IDE engages SpinRite's native driver and is faster,
while AHCI-attached drives are seen as BIOS-attached and *"may be an order of
magnitude slower"*. A reply in the same thread says the opposite for drives with
real errors. This repo uses AHCI, and SpinRite's own benchmark does read roughly a
quarter of ReadSpeed's figure for the same drive — consistent with the slow path.

A Level 3 pass here runs 1-4 hours per drive, so this is worth an afternoon:

1. Attach one drive to `PIIX4` (IDE) port 1 instead of AHCI.
2. Run SpinRite's benchmark, and a Level 3 pass over a bounded sector range.
3. Repeat on AHCI with the same drive and the same range.
4. If IDE wins meaningfully, the trade-off becomes 3 drives per run on the fast
   path versus more drives on the slow one — which would change the default.

## Test the `type bios` multi-drive selector

`BIOS <n>` and `PORT <n>` select exactly one drive and cannot be chained, so a
multi-drive run is currently one command per drive. Physical drives report Type
`BIOS` while the FreeDOS system disk reports Type `ATA`, so `type bios` should match
exactly the physical drives. Verify the matched set with `SPINRITE list exit type
bios` before ever combining `type` with `auto level 3`. See `docs/field-notes.md`.

## Let `attach` match disks by serial

`spinrite-attach.sh attach` takes device names, which are stable within a boot but
not across boots or machines. The tracker records serials, so selecting by serial
substring would let a batch list be carried between sessions verbatim instead of
re-derived from the current `list` output.

## Script the VM build

`docs/vm-build.md` documents the build by hand. Since GRC publishes a pre-built
`SRDOS.OVA` appliance (`docs/origins.md`), what is left worth scripting is: fetch
and verify the OVA, `VBoxManage import` it, and place the user's own licensed
`SPINRITE.EXE` on `C:`. FreeDOS installation and ReadSpeed image-building are not
needed.

The repo's standing rule applies: no GRC software is ever committed or fetched by
these scripts. The licensed SpinRite is supplied by the user at build time.
