---
name: virtualbox-dos-vm
description: Running GRC SpinRite and ReadSpeed against real physical drives from a Kubuntu live USB, via a FreeDOS VirtualBox VM (SRDOS) with raw disk passthrough. Use for a whole maintenance session -- checking a machine's drives, baselining with ReadSpeed, running a SpinRite Level 3 pass, reading the run log, recording the run in the tracker -- and for the VBoxManage mechanics underneath it: attaching raw physical disks or DOS utility images, driving the DOS guest by synthetic keystrokes, reading a FreeDOS/FAT guest disk from the host, and debugging VBoxManage permission, capacity or launch errors.
---

# SpinRite / ReadSpeed on the SRDOS DOS VM

A persistent Kubuntu live USB, carried between machines. On each machine: boot the
stick, hand that machine's physical disks to a FreeDOS VM, run a SpinRite
maintenance pass, record what happened. This skill is the operating manual for
driving that session.

Repo, with the long-form docs: `spinrite-vm-toolkit` (`docs/workflow.md`,
`docs/troubleshooting.md`, `docs/field-notes.md`, `docs/tracking.md`,
`docs/vm-build.md`).

## Running a full session

The order matters. Steps 1-2 are cheap and stop you wasting hours.

1. **Check the tracker first.** `~/bin/spinrite-track.py report` — has this machine's
   drives already been done? A Level 3 pass on a 1 TB drive runs 1-4 hours, so never
   start one without checking. Filter with `--computer <serial-substring>` or
   `--disk <serial-substring>`; `sudo dmidecode -s system-serial-number` gives this
   machine's tag.
2. **Check VirtualBox works on this machine.** `lsmod | grep vbox` (expect `vboxdrv`,
   `vboxnetflt`, `vboxnetadp`) and `VBoxManage list hostinfo`. If `vboxdrv` will not
   load, check `mokutil --sb-state` before suspecting DKMS — Secure Boot MOK trust
   is per-machine UEFI state and does not travel with the stick. Fix:
   `docs/troubleshooting.md` §4. Expect this once per new machine.
3. **Look at the disks.** `~/bin/spinrite-attach.sh list` — read-only. Prints every
   physical disk except the live boot USB, plus how many AHCI ports the VM has.
4. **Attach and launch.** `~/bin/spinrite-attach.sh attach --all`, or name a subset:
   `attach sdb sdc`, or `attach --all --except sde`. The script unmounts partitions,
   builds stable raw VMDK pointers, attaches them and starts the VM in GUI mode.
   Under a tool call add `--yes` (the typed-confirmation prompt has no TTY).
   Disks can be named by **serial substring** as well as device letter —
   `attach S0EXAMPLE000001`. Prefer the serial whenever the list came from the
   tracker or from an earlier session: device letters reassign every boot, serials
   do not. 4+ characters, and it must match exactly one drive or the script refuses.
   `--controller ahci|ide` picks which controller they land on (default `ahci`;
   `ide` = PIIX4, where Level 3 runs ~2-2.6x faster — see "Choosing a controller").
   Either way the script first clears **both** controllers, so a drive moved
   between them can never enumerate twice.
5. **Baseline with ReadSpeed.** At the `C:\>` prompt: `rs`. See "ReadSpeed" below.
   **Capture the results before typing anything else** — the table is only on screen.
6. **Run SpinRite Level 3**, one command per drive:
   `SPINRITE auto level 3 both exit noramtest bios <port>`. See "SpinRite via the
   command line" below.
7. **Re-run ReadSpeed** (`rs`) and compare against step 5. **Screenshot this table
   before sending any other key** — same one-shot screen, and it is the result of a
   multi-hour pass. Compare ReadSpeed to ReadSpeed only, never to SpinRite's own
   benchmark.
8. **Pull the run log.** `C:\SRLOGS\<N>.LOG` holds the before/after SpinRite
   benchmark (from the `both` token) and the defect count. Read it from the host with
   the recipe in "Reading files off the guest" (VM must be powered off).
9. **Record the run.** Four benchmark values per drive, in the formats the tracker's
   columns expect: ReadSpeed before/after as five semicolon-separated MB/s values
   (0/25/50/75/100%), SpinRite's as three (front;mid;end).
   `~/bin/spinrite-track.py add --disk-model ... --disk-serial ... --capacity ...
   --connection native-nvme --action "SpinRite Level 3" --rs-before ... --rs-after ...
   --sr-bench-before ... --sr-bench-after ... --result "Clean, 0 defects"
   --duration 2:12:26`. Computer identity auto-fills from `dmidecode`. The SpinRite
   pair needs the VM off, so logging the row with the ReadSpeed numbers first and
   filling the rest in with `spinrite-track.py update --disk-serial SERIAL --set
   spinrite_bench_after="..."` is normal. Log interrupted runs too, with the
   percentage reached — that is exactly what you will want next time. Details:
   `docs/tracking.md`.
10. **Back up the stick.** `~/bin/spinrite-backup.sh` writes a timestamped tarball to
    `~/spinrite-backups/` for the user to upload. It contains their licensed
    SpinRite — it never goes in a public repo.

### Driving this as an agent

- **A Level 3 pass runs for hours.** Do not poll it tightly. Take a progress
  screenshot well into the run (~30%) and extrapolate from that.
- **Screenshot after every keystroke.** `VBoxManage controlvm SRDOS screenshotpng
  <file>` is read-only and always safe, including on a running VM. SpinRite's screens
  redraw slowly enough that back-to-back blind keypresses get misrouted.
- **The attach script may be blocked by the harness' own classifier** ("Irreversible
  Local Destruction"), which is evaluated on the tool call, not the conversation —
  agreeing in chat does not clear it, and editing the agent's own settings to allow
  it is blocked separately as self-modification. Hand the user the exact command
  instead. Once *they* add `"permissions": {"allow": ["Bash(~/bin/spinrite-attach.sh:*)"]}`
  to `~/.claude/settings.json`, it can be invoked directly.
- **Level 3 warns on screen that it is not recommended for SSD, hybrid or SMR
  drives**, because it is a read + rewrite pass. The user runs it on SSDs and NVMe
  deliberately, as maintenance. Flag it once, then proceed — do not re-litigate it
  every session.
- **Never power off or reset the VM to suit your own investigation.** See "Safety
  rules".

## More drives than slots: run in batches

The VM's AHCI controller has a fixed `PortCount` (3 as built), and drives reach
SpinRite through the guest BIOS, which has its own ceiling. When a machine has more
disks than that:

1. `spinrite-attach.sh list` — the full inventory, with the port count.
2. Attach the first batch: `spinrite-attach.sh attach sdb sdc sdd`.
3. Work that batch end to end (steps 5-9 above), including the tracker entries.
4. Power the VM off, then attach the next set.

Record the pending batches **by serial**, not by device letter — batches routinely
span sessions and `sdb` does not survive a reboot. The serial is also what the
tracker already stores, so the next batch lifts straight out of
`spinrite-track.py report`.

The script refuses an over-capacity selection outright rather than attaching part of
it, and prints a ready-to-run first batch. Log each batch as it finishes so the next
batch is derivable from `spinrite-track.py report` rather than memory. Background on
the controller/BIOS ceiling: `docs/vm-build.md`.

## The VM

- Name `SRDOS`, config at `~/VirtualBox VMs/SRDOS/SRDOS.vbox`.
- Controllers: `Floppy` (left empty), `PIIX4`/IDE (port 0 = FreeDOS `C:` system disk
  `SRDOS-disk001.vdi`, port 1 free for temporarily attaching a DOS utility image),
  `AHCI`/SATA (raw physical disks, 3 ports).
- **Boot lands at a plain `C:\>` prompt.** The floppy is not needed. A "Boot from
  Floppy 0 failed" / "Boot from CD-ROM failed" screen is expected transient text
  before the C: disk boots — give it a few more seconds rather than reattaching the
  floppy. (Check `ps aux | grep VirtualBoxVM` if unsure it is alive.) If the floppy
  *is* attached, boot lands at `A:\>` instead; type `c:`.
- **`SPINRITE.EXE` and `RS.EXE` do not auto-run.** They are launched from the prompt,
  normally by the user. Do not screenshot-poll expecting an auto-run.
- Attach/launch script: `~/bin/spinrite-attach.sh` (see above).
- **Building it from scratch:** `~/bin/spinrite-vm-build.sh --spinrite <path>`
  imports the pre-built `SRDOS.OVA` -- a GRC *forum member's* build, not an
  official GRC release -- checks it against its own manifest, and
  installs the user's licensed SpinRite onto `C:` host-side (clonemedium to RAW,
  loop-mount the FAT16 partition, convert back to VDI -- no guest boot needed). It
  refuses to touch an existing VM of the same name, and downloads nothing: both the
  appliance and SpinRite are files the user supplies. Two things it handles that are
  easy to miss by hand -- the appliance's bundled SpinRite is an unusable
  pre-release and must be replaced, and `RS.EXE` ships only in `READSPEE\` while
  `AUTOEXEC.BAT` sets `PATH=\`, so `rs` does not work until it is copied to the
  root of `C:`. See `docs/vm-build.md`.

## SpinRite via the command line

The canonical way to run a pass. SpinRite 6.1 takes command-line tokens
(case-insensitive, order-independent, `/` prefix optional) that skip the menus
entirely. Standard command, one per drive:

```
SPINRITE auto level 3 both exit noramtest bios <port>
```

| Token | Effect |
| --- | --- |
| `AUTO` | Skip the settings/selection screens. Hold Shift to interrupt. |
| `LEVEL {1-5}` | Operating level for the session (we use 3). |
| `BOTH` | Benchmark the drive before *and* after the pass. Also `NEVER` (default), `BEFORE`, `AFTER`. |
| `EXIT` | Return to `C:\>` when done instead of stopping at a results menu. |
| `NORAMTEST` | Skip the RAM test screen. |
| `LIST` | Enumerate drives to the console and exit. |
| `DIAGS` | Also write a `.DBG` diagnostic file to `SRLOGS`. |
| `QUIET` | No ticks/beeps. |
| Drive selectors | `BIOS <n>`, `PORT <n>`, `TYPE <ahci\|ata\|ide\|bios>`, `SIZE <text>`, `MODEL <text>`, `SERIAL <text>` |
| Range | `<selector> <start%> [<end%>]` or `#<startsector> [#<endsector>]`. Percentages need a decimal point; sectors need a leading `#`. **Confirmed** for the decimal form: `bios 81 75.0 80.0` bounds the pass to that 5%, and writes only that much — verified against the host block-layer write counter. A bounded pass also gives an accurate ETA, unlike a full one. |

Two behaviors that decide how the command is written:

- **The RAM test screen precedes every invocation, not just `AUTO`** — even a
  bare `SPINRITE list exit` stops on "Testing System RAM" and waits for Enter.
  Hence `noramtest` on anything meant to run unattended, read-only ones included:
  `SPINRITE list exit noramtest`. The trade-off (raised with the user
  and accepted): it skips SpinRite's RAM-reliability check, which matters slightly
  more under Level 3 because that pass rewrites sectors.
- **`BIOS <n>` and `PORT <n>` select exactly one drive and cannot be chained.**
  `bios 81 bios 82` drops to a help screen and runs nothing — a safe no-op, but
  nothing happens. Issue one command per drive, sequentially, once the previous
  one's `exit` has returned to the prompt. SpinRite processes multiple selected
  drives one at a time anyway. (`TYPE`/`MODEL`/`SERIAL`/`SIZE` match by pattern and
  can select several; using `TYPE` to select all physical drives at once is untested
  with more than one drive attached — see `docs/field-notes.md`.)
- **On AHCI, only `BIOS`, `PORT` and `TYPE bios` can select a passthrough drive.** In
  `SPINRITE list exit noramtest` output, an AHCI-attached physical disk shows its
  Model and Serial columns as `....` — SpinRite reaches it through the BIOS and
  never reads its identity strings — so `MODEL <text>` and `SERIAL <text>` have
  nothing to match on. The FreeDOS system disk is the one row with a real identity,
  and it is Type `ATA`, Port `PM`; physical drives are Type `BIOS` with Port and
  BIOS numbers both starting at `81`.
  **Attached to `PIIX4`/IDE instead, the same drive reports Type `ATA`, Port `SM`,
  and its identity columns populate** (`VBOX HARDDISK` / `VBf9228443-…`), so
  `MODEL`/`SERIAL` do work there — but they match VirtualBox's synthetic identity,
  derived from the medium UUID, never the drive's real serial. Level 3 also runs
  ~2x faster on IDE; see `docs/field-notes.md`.

`BOTH` writes the before/after benchmark straight into the run's `.LOG` file under
"Drive's measured performance before/after running SpinRite" headers, so no
screenshot is needed for it. SpinRite's benchmark and ReadSpeed measure different
access paths and are **not comparable to each other** — compare SpinRite-before to
SpinRite-after, ReadSpeed-before to ReadSpeed-after, never across
(`docs/field-notes.md`).

The on-screen ETA shortly after a run starts can be wildly optimistic — "1:32:55
remaining" at 0.18% against an actual 4:16:14, with zero defects to explain it. Do
not schedule around it.

Command-line reference (the wiki page is a JS shell; fetch through the API):
`https://gitlab.com/api/v4/projects/GRC-Community%2Fspinrite-6.1-wiki/wikis/Command-Line?with_content=1`

## SpinRite by keystrokes (fallback)

`VBoxManage controlvm SRDOS keyboardputscancode <make> <break>` sends one keypress
using set-1 scancodes (make code, then the same byte OR'd with 0x80).
`keyboardputstring "text"` types a string.

| Key | Codes | Key | Codes |
| --- | --- | --- | --- |
| Spacebar | `39 b9` | ESC | `01 81` |
| Enter | `1c 9c` | Down arrow | `50 d0` |
| PgDn | `51 d1` | Right arrow | `4d cd` |
| Digits 1-9 | make `02`-`0a` (e.g. `3` = `04 84`) | | |

`sleep 1-2` and screenshot between keypresses.

Full menu sequence, from `C:\>`:

1. `keyboardputstring "spinrite"` + Enter. (`SPINRITE.EXE`; `RS.EXE` is ReadSpeed.)
2. Welcome and license screens: spacebar each.
3. RAM test screen: Enter immediately to skip ahead.
4. Drive discovery takes a few seconds — screenshot to confirm "System's Mass Storage
   Devices Discovered" lists the expected drives by port and size.
5. Level selection: press `3` for Level 3.
6. Main Menu: `1. Select drive(s) for level: 3` is pre-highlighted — Enter.
7. Drive picker: **the tiny (~104 MB) `ATA PM` row is the VM's own FreeDOS system
   disk — leave it unselected.** Down-arrow to each real `BIOS 8x` row and spacebar
   to toggle it on. Screenshot to confirm the `?` column shows checkmarks on exactly
   the intended rows.
8. Enter to confirm ("Before Beginning" screen), Enter again to start. Lands on the
   `Level: 3 — Graphic Status Display`.

**Interrupting a run cleanly:** ESC from any in-progress screen opens the
interruption menu (`1. Cancel any interruption / 2. Skip this sector only /
3. Finish this sector only / 4. Return to the main menu / 5. Cancel all work &
exit`). Navigate with down-arrow + Enter. **Prefer option 4** — it stops the current
drive but keeps SpinRite running so you can reselect drives. An "Operation
Interruption Notice" then reports the exact percentage reached and confirms the work
can be resumed from there; ESC acknowledges it. To exit SpinRite from the Main Menu,
press `6` (`07 87`).

**Main Menu option 3 runs a benchmark on its own** (`04 84`), with its own drive
picker: down-arrow to the drive, Enter. It reports SMART polling delay, random
sector time, and front/midpoint/end MB/s, plus an estimated full-surface-scan
duration — that estimate is read-only Level-2-style, not a Level 3 read+write
duration (47.8 min estimated vs 2:12:26 actual on one drive). ESC returns to the
Main Menu. Unlike the `BOTH` token, this benchmark is **not** written to the log.

**Multiple selected drives run sequentially**, DOS being single-tasking. The
`megabytes: remaining/completed` figures reset per drive, so match remaining+completed
against known capacities to tell which drive is active; the ETA covers only that one.

## Choosing a controller

`--controller ahci` (default) or `--controller ide`. They are not equivalent, and
the choice changes what the numbers mean:

| | AHCI | IDE (PIIX4) |
|---|---|---|
| Level 3 speed | baseline | **2.08x (SATA) / 2.58x (NVMe) faster** |
| ReadSpeed | **faster, flatter** | slower, steeper |
| ReadSpeed repeatability | 7.6-34.5% spread | 2.1-15.3% |
| Drive identity in `list` | `....` | populated (but synthetic) |
| Selector | `bios <n>`, `port <n>`, `type bios` | same `bios <n>` works |
| Slots | 3 (portcount, raisable) | 3 (fixed, C: takes the 4th) |

**The default stays AHCI** because every tracker row was measured on it and a
before/after pair is only comparable within one controller. Use `ide` when the
runtime of a long pass matters more than comparability, or when measuring the two
against each other. Full numbers: `docs/field-notes.md`.

## ReadSpeed

Normally the user runs this themselves (see `docs/workflow.md`). When asked to do it:
`keyboardputstring "rs"` + Enter from `C:\>`. No welcome screens, no drive picker, no
level selection — it discovers and benchmarks every attached non-boot drive
sequentially (the tiny FreeDOS system disk is skipped as "too small to benchmark")
and returns to `C:\>` on its own. Two ~1 TB NVMe drives take well under 30 seconds,
so sleep ~10-15s and screenshot rather than polling.

The results table (drive number, size, identity, MB/s at 0/25/50/75/100% of the
drive) stays on screen until the next command clears it — **screenshot before typing
anything else.** This applies to the after-pass run as much as the baseline; losing
it costs the whole comparison. Results also accumulate as `C:\RS0NN.TXT`, one file
per run, recoverable from the host only once the VM is powered off. How to read the
numbers: `docs/field-notes.md`.

## Attaching disks and images by hand

`spinrite-attach.sh` does this for physical disks. Doing it manually:

```
ls -la /dev/disk/by-id/ | grep -v -- -part      # find the nvme-/ata-/usb- alias
sudo -n -iu <user> -- VBoxManage createmedium disk \
  --filename "<name>.vmdk" --format=VMDK --variant RawDisk \
  --property RawDrive=/dev/disk/by-id/<id>
sudo -n -iu <user> -- VBoxManage storageattach SRDOS \
  --storagectl AHCI --port <n> --device 0 --type hdd --medium "<name>.vmdk"
```

**Never point at `/dev/sdX`** — letters reassign every boot. To identify the live
boot USB (always excluded): `findmnt -no SOURCE /cdrom`, then `lsblk -no pkname`.

**A raw `.img` file cannot be attached directly** — `storageattach --medium some.img`
fails with `VERR_NOT_SUPPORTED`. Convert first:

```
VBoxManage convertfromraw <file>.img "<vm dir>/<file>.vdi" --format VDI
VBoxManage storageattach SRDOS --storagectl PIIX4 --port 1 --device 0 --type hdd --medium "<file>.vdi"
```

Then `copy d:\whatever.exe c:\` from the DOS prompt (check `dir` for the letter),
detach with `--medium none`, delete the temp `.vdi`.

## Reading files off the guest

No Guest Additions, no shared folders. To read `C:\SRLOGS\<N>.LOG` or verify a file
landed on `C:` (**VM must be powered off**):

```
VBoxManage clonemedium "SRDOS-disk001.vdi" /tmp/check.raw --format RAW   # non-destructive
fdisk -l /tmp/check.raw                      # find the FAT partition's start sector
sudo mount -o ro,loop,offset=$((START_SECTOR*512)) /tmp/check.raw /mnt/point
ls /mnt/point                                # inspect
sudo umount /mnt/point
VBoxManage closemedium disk /tmp/check.raw   # before the rm, not after
rm /tmp/check.raw
```

**`closemedium` is not optional.** `clonemedium` registers the clone in
VirtualBox's media registry; `rm`-ing the file without unregistering it leaves a
dangling entry in `VBoxManage list hdds` forever. Clear an old one with
`VBoxManage closemedium disk <uuid>` — never with `--delete`.

This minimal FreeDOS has no `FIND.EXE`/`MORE.COM`, so a log cannot be paged or
grepped from inside DOS — pull it to the host for anything beyond what a `type`
dump's last screenful shows.

**The first command typed after SpinRite's `exit` returns is swallowed.**
Reproducible across several cycles on 2026-09-19: `keyboardputstring "rs"` + Enter
straight after a run exits leaves the prompt untouched — no `rs` echoed, nothing
run. Sending it a second time works every time. Screenshot to confirm the command
actually echoed before trusting a blank result, and treat "the screen still shows
the previous output" as a dropped keystroke rather than a finished run.

**Do not pick the newest `RS0NN.TXT` by its host-side mtime.** The FAT directory
timestamps the guest writes are offset from wall-clock time (observed 4 hours out
on 2026-09-19), so `ls -t` can mislead. Every ReadSpeed log ends with a
`Benchmarked: <day>, <date> at <time>` line — read that instead.

## Safety rules

- **Never `pkill VBoxSVC` while a VM might be running.** It crashes the VM:
  `VirtualBoxClient: detected unresponsive VBoxSVC`, then the GUI force-powers it
  off. Always check `ps aux | grep VirtualBoxVM` or `VBoxManage list runningvms`
  first. Querying or screenshotting a running VM never needs this.
  `spinrite-attach.sh` has the guard built in.
- **Never `poweroff`/`reset` the VM without checking it is not in use.** That
  destroys the DOS session state — there is no resume. The user is physically sitting
  at this machine, so a running SRDOS window may be theirs. Check
  `VBoxManage showvminfo SRDOS --machinereadable | grep VMState=` and treat `running`
  as "someone may be using this" — ask rather than powering off for your own
  investigation. `screenshotpng` is read-only and always safe.
- A VM in `aborted` state starts directly via `startvm`, exactly like `poweroff`. No
  live process — not the literal string `poweroff` — is the real precondition.

## Gotchas

**Raw access needs the `disk` group, and VBoxSVC ignores it until a fresh login.**
Symptom: `VBoxManage list hdds` shows the raw medium as `State: inaccessible` /
`Capacity: 0 MBytes`, and `storageattach`/`startvm` fail with `VERR_ACCESS_DENIED`,
even though `ls -la /dev/nvme0n1` shows `root:disk 660`. After
`sudo usermod -aG disk <user>`, `sg disk -c '...'` does **not** fix it — `sg` grants
the group only to its direct child, while VBoxSVC daemonizes with whatever
credentials it first started under. Route *every* VBoxManage call through
`sudo -n -iu <user> -- VBoxManage ...`; one unwrapped call can spawn a stale-group
VBoxSVC that then serves all the rest. Full writeup: `docs/troubleshooting.md` §1.

**`startvm --type gui` can hang under an automation harness** — `Exit code 144`,
no output, sometimes started anyway. Detach it fully:

```
nohup sudo -n -iu <user> -- VBoxManage startvm SRDOS --type gui \
  > /path/to/log 2>&1 < /dev/null &
disown
sleep 3; cat /path/to/log
VBoxManage showvminfo SRDOS --machinereadable | grep VMState=
```

**A stale raw `.vmdk` silently under-reports capacity.** The descriptor bakes in its
extent size (`RW <sectors> FLAT "<path>"`) at creation and never re-reads the device,
so a leftover pointer reused for a different, larger disk makes a 1 TB drive appear
as 256 GB — no error, no `inaccessible` state, and SpinRite then scans part of a
drive you believe was covered. Also note `createmedium --property RawDrive=<by-id>`
writes the *resolved* node (`/dev/nvme0n1`) into the descriptor, not the symlink, so
identity cannot be re-derived from it. `spinrite-attach.sh` names pointers after the
by-id basename and verifies the baked-in size against `blockdev --getsize64` before
reuse. To clear one by hand: detach with `--medium none`, `VBoxManage closemedium
disk <uuid-or-path>` (**no** `--delete` — unnecessary risk on a raw-device-backed
medium), then `rm` the descriptor.

**The media registry accumulates inaccessible entries** — one per raw pointer whose
drive is not currently plugged in, plus every `clonemedium` clone deleted without
`closemedium` first. Harmless but noisy: 19 stale against 2 live on one stick. Sweep
them with `~/bin/spinrite-attach.sh prune` (`--yes` under a tool call); it skips
media still attached to a VM and never passes `--delete`, so the `.vmdk` pointer
files survive and `attach` re-registers them when the drive returns. Note that
`list hdds` does **not** reliably print an `In use by VMs:` line on VirtualBox 7.x —
to tell what is really attached, read each VM's `ImageUUID` keys from
`showvminfo --machinereadable`.

**USB-NVMe bridges (Sabrent / Realtek RTL9210) drop off the bus under sustained
access.** A drive in such an enclosure that hits DynaStat deep recovery can make the
whole enclosure vanish from USB after a few hours — `lsusb` no longer lists it,
`/dev/sdX` and its by-id entries disappear, `dmesg` loops on `unable to enumerate USB
device`. **The fix is physical: unplug and reseat the cable**, ideally in another
port. To tell it apart from a failing drive: by-id shows two aliases for the same
device (`ata-<model>_<serial>` and `usb-Sabrent_<serial>`); if that drive grinds
through recovery for hours while a natively-attached drive in the same run sails
through, suspect the bridge, and confirm with `smartctl -a /dev/sdX` after reseating.
Short ReadSpeed checks through such an enclosure are fine; for a full Level 3 pass,
connect the drive natively. Details: `docs/troubleshooting.md` §5.

**Do not verify a Windows disk with `ntfsfix` — it may be BitLocker-encrypted.**
On a BitLocker volume `ntfsfix -n` reports `NTFS signature is missing` /
`Volume is corrupt. You should run chkdsk.` That is the tool being handed
ciphertext, **not** damage from the pass. Check with `blkid` (reports
`TYPE="BitLocker"`) or the `-FVE-FS-` magic at offset 3 of the partition. To
confirm a pass did no harm on such a disk: partition table unchanged
(`fdisk -l`), the `-FVE-FS-` header still present, the EFI partition still
mountable, any plain-NTFS recovery partition still passing `ntfsfix -n`, and
SMART `Media and Data Integrity Errors` still 0. Ultimately, only booting Windows
proves it.

**Live throughput sanity check** on a raw disk mid-pass, without touching the VM:

```
cat /sys/block/<dev>/stat; sleep 3; cat /sys/block/<dev>/stat
```

Fields (1-indexed): 1 = reads completed, 3 = sectors read, 5 = writes completed,
7 = sectors written. Diff two samples, sectors x 512 = bytes. Balanced read+write
≈ a Level 3 refresh pass; read-only ≈ a benchmark or scan.
