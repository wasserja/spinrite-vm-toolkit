# Canonical session workflow

What to do, in order, each time you boot the stick on a machine and want to
maintain its drives.

You can also just hand this whole sequence to Claude Code. With the skill in
`skills/virtualbox-dos-vm/` installed, "check this machine's drives" or "run the
SpinRite workflow here" is enough — it knows this order, the AUTO command line, how
to drive the DOS guest by synthetic keystrokes and what never to do to a running VM.
See the README. You still read the disk table and decide what gets written to.

## 0. Check the tracker first

```
~/bin/spinrite-track.py report
```

The stick gets carried between machines, and a full Level 3 pass on a 1 TB drive
runs for hours. Check whether this computer's drives have already been done
before committing to a run. See `docs/tracking.md`.

## 1. Verify the VirtualBox drivers on this machine

```
lsmod | grep vbox            # expect vboxdrv, vboxnetflt, vboxnetadp
VBoxManage list hostinfo     # expect real output, not an error
```

If `vboxdrv` will not load, check `mokutil --sb-state` before assuming a DKMS or
build problem — Secure Boot MOK trust is per-machine firmware state and does not
travel with the USB stick. Fix in `docs/troubleshooting.md`. Do this check on
every new machine; sometimes it is already enrolled and nothing is needed.

## 2. Look at the drives

```
~/bin/spinrite-attach.sh list
```

Read-only. Prints every physical disk on this machine except the live boot USB —
device, size, model, serial, mounted partitions — plus how many AHCI ports the VM
has. Nothing is unmounted, attached or started. This is also the default: bare
`spinrite-attach.sh` does exactly this and nothing else.

## 3. Attach the ones you want, and launch the VM

```
~/bin/spinrite-attach.sh attach --all              # everything discovered
~/bin/spinrite-attach.sh attach sdb sdc            # only these two
~/bin/spinrite-attach.sh attach --all --except sde # everything but that one
```

The script unmounts each selected disk's partitions, builds or reuses a stable raw
VMDK pointer for it, attaches it to the VM's AHCI controller and starts the VM.

It prints the table with the selected disks marked and requires a typed `yes` first.
**Read that table.** Every marked disk is handed raw to a DOS utility that rewrites
every sector at Level 3. `--yes` skips the prompt, for scripted or agent-driven runs
that cannot answer it.

Under an automation harness, launch the whole script detached rather than waiting on
it in the foreground — the script ends in `VBoxManage startvm --type gui`, which is
the call documented in `docs/troubleshooting.md` as prone to hanging with exit
code 144 under a harness:

```
~/bin/spinrite-attach.sh attach <name> --yes > /tmp/attach.log 2>&1 < /dev/null &
disown
```

Then read `/tmp/attach.log` and confirm with `VBoxManage showvminfo SRDOS
--machinereadable | grep VMState=`. Run this way on 2026-09-19 it did not hang, so
whether the bare foreground call is still affected is untested — the detached form
costs nothing either way.

Disk names are as printed by `list`; `sdb`, `/dev/sdb` and `nvme0n1` all work. A name
that matches nothing is an error rather than a silently narrower selection.

If you prefer a desktop icon, `desktop/spinrite-attach.desktop` runs
`attach --all` in a terminal.

## 3a. More drives than slots

The AHCI controller has a fixed number of ports (3 as built) and the guest BIOS has
its own ceiling on how many drives it exposes to SpinRite — see `docs/vm-build.md`.
When a machine has more disks than that, work them in batches:

1. `~/bin/spinrite-attach.sh list` — the full inventory, with the port count.
2. Attach the first batch by name: `~/bin/spinrite-attach.sh attach sdb sdc sdd`.
3. Work that batch end to end — steps 4 through 7 below, tracker entries included.
4. Power the VM off, then attach the next set by name.

The script refuses an over-capacity selection outright rather than attaching part of
it, and prints a ready-to-run first batch when it does. Record each batch in the
tracker as it finishes, so the next batch comes from `spinrite-track.py report`
rather than from memory — batches often span sessions, and the drives are hours
apart.

## 4. Baseline with ReadSpeed

At the `C:\>` prompt, **manually**:

```
rs
```

ReadSpeed does not auto-run on boot, and it needs no drive picker or level
selection. It discovers and benchmarks every attached non-boot drive
sequentially — the tiny FreeDOS system disk is skipped as "too small to
benchmark" — then returns to `C:\>` on its own. Two ~1 TB NVMe drives take well
under 30 seconds.

The results table (drive number, size, identity, MB/s at 0/25/50/75/100% of the
drive) stays on screen until the next command clears it. **Capture it now** —
screenshot or transcribe into the tracker — because there is no second chance
once you type anything else. Results also accumulate as `C:\RS0NN.TXT`, one file
per run.

How to read those numbers: `docs/field-notes.md`.

## 5. Run SpinRite Level 3

Level 3 is a read + rewrite maintenance/refresh pass. The modern way is the
command line rather than the menu sequence:

```
SPINRITE auto level 3 both exit noramtest bios <port>
```

- `auto` — skip the settings/selection screens
- `level 3` — maintenance/refresh
- `both` — run SpinRite's own benchmark before *and* after the pass, written
  into the run's `.LOG` file
- `exit` — return to `C:\>` when done instead of stopping at a results menu
- `noramtest` — skip the RAM test screen (see the trade-off note in
  `skills/virtualbox-dos-vm/SKILL.md`)
- `bios <port>` — the drive, by the port number shown during discovery

`BIOS <n>` and `PORT <n>` select exactly **one** drive each and cannot be
chained — `bios 81 bios 82` drops to a help screen and runs nothing. For multiple
drives, issue one command per drive once the previous one's `exit` has returned
to the prompt. SpinRite runs multiple selected drives sequentially anyway (DOS is
single-tasking), so nothing is lost.

Level 3's on-screen warning that it is "NOT recommended for SSDs, Hybrid, or SMR
drives" is about it being a read+write rewrite pass. Running it on SSDs/NVMe as a
deliberate maintenance practice is a judgment call — know what you are choosing.

The full keystroke-driven menu sequence, for when you need it, is documented in
`skills/virtualbox-dos-vm/SKILL.md`.

## 6. Re-run ReadSpeed and compare

```
rs
```

**Capture this table too, before typing anything else.** Same one-shot screen as
step 4 — and this is the one you just waited hours for. Screenshot it, or read the
five numbers off it into the tracker now.

The durable fallback is on the guest: every run also writes `C:\RS0NN.TXT`, numbered
sequentially, so a lost screen is recoverable by mounting the FreeDOS disk from the
host (`docs/vm-build.md`) — but that needs the VM powered off, which means ending
the session. Cheaper to screenshot.

Compare against the step 4 baseline, ReadSpeed to ReadSpeed only. SpinRite's own
before/after benchmark is a different access path and is not comparable to these
numbers — `docs/field-notes.md` covers that, and what an unchanged uneven profile
means versus a real improvement.

Both sets of numbers have a home in the tracker, in the format its columns expect
(`docs/tracking.md`):

- **ReadSpeed** — five semicolon-separated MB/s values, at 0/25/50/75/100% of the
  drive, from this screen and the step 4 one.
- **SpinRite's own benchmark** — three values (front, midpoint, end), which the
  `both` token wrote into `C:\SRLOGS\<N>.LOG` during step 5. You do not have to
  transcribe those now; pull the log after powering the VM off and fill them in with
  `spinrite-track.py update`.

## 7. Record the run

```
~/bin/spinrite-track.py add \
  --disk-model "..." --disk-serial "..." --capacity "1TB NVMe" \
  --connection native-nvme --action "SpinRite Level 3" \
  --rs-before "1375.4;1165.5;2210.0;1154.3;1321.1" \
  --rs-after  "1776.8;1339.8;1905.3;1342.4;1681.4" \
  --sr-bench-before "603.447;610.234;609.410" \
  --sr-bench-after  "608.315;609.716;601.603" \
  --result "Clean, 0 defects" --duration 2:12:26
```

Computer make/model/serial are auto-detected via `dmidecode` if omitted.

The SpinRite benchmark pair comes out of the run log, which needs the VM powered
off — so it is normal to log the row now with the ReadSpeed numbers and fill the
rest in afterwards:

```
~/bin/spinrite-track.py update --disk-serial SERIAL \
  --set spinrite_bench_before="603.447;610.234;609.410" \
  --set spinrite_bench_after="608.315;609.716;601.603"
```

Log interrupted runs too, with the percentage reached in `--result`. An interrupted
run is exactly the thing you will want to know about next time.

## 8. Back up the stick

```
~/bin/spinrite-backup.sh
```

Writes a timestamped tarball to `~/spinrite-backups/`. Upload it somewhere off
the stick. It contains your licensed SpinRite — keep it out of any public repo.

## Safety rules that apply throughout

- **Never power off or reset the VM without checking it is not in use.**
  `poweroff`/`reset` destroys the DOS session state — there is no resume. Check
  `VBoxManage showvminfo SRDOS --machinereadable | grep VMState=` first and treat
  `running` as "someone may be using this". `screenshotpng` is read-only and
  always safe.
- **Never `pkill VBoxSVC` while a VM might be running.** It will crash the VM.
  Check `ps aux | grep VirtualBoxVM` first. `spinrite-attach.sh` has this guard
  built in.
- **To interrupt a running pass cleanly**, press ESC and choose "Return to the
  main menu" (option 4) rather than "Cancel all work & exit" (option 5). SpinRite
  reports the exact percentage reached and can resume from that point.
