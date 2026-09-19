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
5. **Baseline with ReadSpeed.** At the `C:\>` prompt: `rs`. See "ReadSpeed" below.
   **Capture the results before typing anything else** — the table is only on screen.
6. **Run SpinRite Level 3**, one command per drive:
   `SPINRITE auto level 3 both exit noramtest bios <port>`. See "SpinRite via the
   command line" below.
7. **Re-run ReadSpeed** (`rs`) and compare against step 5.
8. **Pull the run log.** `C:\SRLOGS\<N>.LOG` holds the before/after SpinRite
   benchmark and the defect count. Read it from the host with the recipe in
   "Reading files off the guest" (VM must be powered off).
9. **Record the run.** `~/bin/spinrite-track.py add --disk-model ... --disk-serial ...
   --capacity ... --connection native-nvme --action "SpinRite Level 3"
   --rs-before ... --rs-after ... --sr-bench-before ... --sr-bench-after ...
   --result "Clean, 0 defects" --duration 2:12:26`. Computer identity auto-fills from
   `dmidecode`. Log interrupted runs too — that is exactly what you will want next
   time. Details: `docs/tracking.md`.
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
2. Attach the first batch by name: `spinrite-attach.sh attach sdb sdc sdd`.
3. Work that batch end to end (steps 5-9 above), including the tracker entries.
4. Power the VM off, then attach the next set by name.

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
| Range | `<selector> <start%> [<end%>]` or `#<startsector> [#<endsector>]`. Percentages need a decimal point; sectors need a leading `#`. |

Two behaviors that decide how the command is written:

- **`AUTO` does not skip the RAM test** — hence `noramtest`, which makes the run
  unattended straight through drive discovery. The trade-off (raised with the user
  and accepted): it skips SpinRite's RAM-reliability check, which matters slightly
  more under Level 3 because that pass rewrites sectors.
- **`BIOS <n>` and `PORT <n>` select exactly one drive and cannot be chained.**
  `bios 81 bios 82` drops to a help screen and runs nothing — a safe no-op, but
  nothing happens. Issue one command per drive, sequentially, once the previous
  one's `exit` has returned to the prompt. SpinRite processes multiple selected
  drives one at a time anyway. (`TYPE`/`MODEL`/`SERIAL`/`SIZE` match by pattern and
  can select several; using `TYPE` to select all physical drives at once is untested
  — see `docs/field-notes.md`.)

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

## ReadSpeed

Normally the user runs this themselves (see `docs/workflow.md`). When asked to do it:
`keyboardputstring "rs"` + Enter from `C:\>`. No welcome screens, no drive picker, no
level selection — it discovers and benchmarks every attached non-boot drive
sequentially (the tiny FreeDOS system disk is skipped as "too small to benchmark")
and returns to `C:\>` on its own. Two ~1 TB NVMe drives take well under 30 seconds,
so sleep ~10-15s and screenshot rather than polling.

The results table (drive number, size, identity, MB/s at 0/25/50/75/100% of the
drive) stays on screen until the next command clears it — **screenshot before typing
anything else.** Results also accumulate as `C:\RS0NN.TXT`, one file per run. How to
read the numbers: `docs/field-notes.md`.

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
ls /mnt/point                                # inspect, then umount + rm the raw file
```

This minimal FreeDOS has no `FIND.EXE`/`MORE.COM`, so a log cannot be paged or
grepped from inside DOS — pull it to the host for anything beyond what a `type`
dump's last screenful shows.

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

**Live throughput sanity check** on a raw disk mid-pass, without touching the VM:

```
cat /sys/block/<dev>/stat; sleep 3; cat /sys/block/<dev>/stat
```

Fields (1-indexed): 1 = reads completed, 3 = sectors read, 5 = writes completed,
7 = sectors written. Diff two samples, sectors x 512 = bytes. Balanced read+write
≈ a Level 3 refresh pass; read-only ≈ a benchmark or scan.
