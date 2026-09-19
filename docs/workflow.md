# Canonical session workflow

What to do, in order, each time you boot the stick on a machine and want to
maintain its drives.

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

## 2 & 3. Discover the drives and launch the VM

`bin/spinrite-attach.sh` does both in one step — it enumerates the physical disks
(excluding the live boot USB), prints a table of what it found, asks for a typed
`yes`, then unmounts, attaches and starts the VM.

```
~/bin/spinrite-attach.sh                # all discovered disks
~/bin/spinrite-attach.sh sde            # ...except /dev/sde
~/bin/spinrite-attach.sh sde sdf        # ...except those two
```

Read the printed table before typing `yes`. Every disk listed there gets its
partitions unmounted and gets handed raw to a DOS utility that will write to it
at Level 3. The exclusion arguments exist for the case where you have more disks
present than free AHCI ports, or an external drive you do not want touched.

If you prefer a desktop icon, `desktop/spinrite-attach.desktop` launches the same
script in a terminal.

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

Compare against the step 4 baseline. `docs/field-notes.md` covers what an
unchanged uneven profile means versus a real improvement.

## 7. Record the run

```
~/bin/spinrite-track.py add \
  --disk-model "..." --disk-serial "..." --capacity "1TB NVMe" \
  --connection native-nvme --action "SpinRite Level 3" \
  --rs-before "..." --rs-after "..." \
  --result "Clean, 0 defects" --duration 2:12:26
```

Computer make/model/serial are auto-detected via `dmidecode` if omitted.

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
