# Troubleshooting

Five problems that cost real time to diagnose, each with the symptom that
actually shows up rather than the cause.

---

## 1. VBoxSVC ignores new group membership until a genuinely fresh login

**Symptom:** `VBoxManage list hdds` shows a raw disk's medium as
`State: inaccessible` with `Capacity: 0 MBytes`, and `storageattach`/`startvm`
fail with `VERR_ACCESS_DENIED` opening the medium — even though
`ls -la /dev/nvme0n1` shows `root:disk 660`, the user is in the `disk` group, and
a manual `sg disk -c "test -r ..."` check says permissions are fine.

**Cause:** raw physical-disk access needs the `disk` group, but after
`sudo usermod -aG disk <user>`, **`sg disk -c '...'` does not fix VBoxManage**.
`sg` grants the new group only to its direct child. VirtualBox's backing service
(`VBoxSVC`) gets reparented and daemonized, and ends up with whatever credentials
existed when it — or whatever first spawned it — started, not the `sg` wrapper's.

**Fix**, and this is the part that matters: run *every* VBoxManage call through a
genuinely fresh login-equivalent context, not just the ones touching raw devices.
One unwrapped call can spawn or reuse a VBoxSVC with stale groups that then
serves every subsequent call too.

```
pkill -f VBoxSVC; sleep 1
sudo -n -iu <user> -- VBoxManage <subcommand> ...
```

> ### Never run this while a VM might be running
> Killing VBoxSVC while a VM is live **will crash it** — `VirtualBoxClient:
> detected unresponsive VBoxSVC` followed by the GUI force-powering the VM off.
> That is a real, unrequested crash, not a harmless loss of introspection.
> **Always check `ps aux | grep VirtualBoxVM` or `VBoxManage list runningvms`
> first.** Querying or screenshotting a running VM never needs this fix; it is
> only relevant right after a `usermod -aG disk` when starting a fresh session.

`bin/spinrite-attach.sh` implements both halves: a `pgrep -f "VirtualBoxVM.*--startvm"`
guard that refuses to run if a VM process is alive, and a `VBM()` wrapper that
routes every single VBoxManage call through `sudo -iu`.

**Related:** a VM in `aborted` state (e.g. after a crash) starts directly via
`VBoxManage startvm` exactly like `poweroff` does. No live process — not the
literal string `poweroff` — is the real precondition.

---

## 2. `VBoxManage startvm --type gui` can hang under an automation harness

**Symptom:** the command returns a mysterious `Exit code 144` with zero captured
output, unpredictably — sometimes the VM actually started, sometimes not.

**Cause:** job control. The GUI process does not detach cleanly from a captured
subprocess.

**Fix:** fully detach it.

```
nohup sudo -n -iu <user> -- VBoxManage startvm SRDOS --type gui \
  > /tmp/startvm.log 2>&1 < /dev/null &
disown
sleep 3
cat /tmp/startvm.log        # "VM ... has been successfully started."
VBoxManage showvminfo SRDOS --machinereadable | grep VMState=
```

---

## 3. A stale raw-disk `.vmdk` silently under-reports capacity

**Symptom:** a real 1 TB drive shows up in DOS/SpinRite as 256 GB (or some other
wrong size). No error. No `inaccessible` state. Just a quietly wrong disk — which
means SpinRite scans only part of it and you believe the whole drive was covered.

**Cause:** a raw-disk VMDK descriptor stores its extent size
(`RW <sectors> FLAT "<path>"`) at `createmedium` time and **never re-reads it**
from the live device. If a `.vmdk` from a previous machine or boot is still
sitting in `~/VirtualBox VMs/` and gets reused for what is now a different,
larger physical disk, the guest reports the old size.

The trap underneath the trap: `VBoxManage createmedium --property RawDrive=<by-id path>`
writes the **resolved** device node (`/dev/nvme0n1`) into the descriptor's FLAT
line, not the by-id symlink. So anything that re-derives disk identity by reading
the descriptor's stored path is really just comparing ephemeral kernel device
names — the same `/dev/sdX` letter-reuse trap, one level down.

**Fix:** name pointer files after the by-id basename (model + serial, stable
across boots and machines), and verify the baked-in sector count against the live
device before reusing one:

```
desc_sectors=$(grep -oP '(?<=^RW )\d+' "$vmdk" | head -1)
desc_bytes=$(( desc_sectors * 512 ))
live_bytes=$(sudo blockdev --getsize64 "/dev/$dev")
[ "$desc_bytes" = "$live_bytes" ] || { VBoxManage closemedium disk "$vmdk" 2>/dev/null; rm -f "$vmdk"; }
```

`bin/spinrite-attach.sh` does this automatically. To clear a stale pointer by
hand: detach with `storageattach ... --medium none`, then
`VBoxManage closemedium disk <uuid-or-path>` — **without** `--delete`, which is
unnecessary risk on a raw-device-backed medium. Once unregistered, just `rm` the
descriptor; it is a small text file, not the physical device.

---

## 4. Secure Boot rejects the VirtualBox kernel modules on a new machine

**Symptom:** `sudo modprobe vboxdrv` fails with
`modprobe: ERROR: could not insert 'vboxdrv': Key was rejected by service`, while
`dkms status` cheerfully reports `virtualbox/7.0.16, <kernel>, x86_64: installed`
for the running kernel. Looks like a DKMS problem. Is not.

**Cause:** Secure Boot is enabled, and the self-signed key DKMS uses to sign
`vboxdrv`/`vboxnetflt`/etc. (`/var/lib/shim-signed/mok/MOK.der`) is not trusted on
this machine. **MOK enrollment lives in each machine's own UEFI NVRAM, not on the
USB stick** — so a machine that has already had the blue MOK Manager screen
completed on it loads the module fine, while a machine booting the same stick for
the first time rejects it. Expect this once per new machine.

**Diagnose before assuming:**

```
mokutil --sb-state
sudo mokutil --list-enrolled     # grep for the kubuntu/DKMS cert, not just Canonical's
```

Note the `sudo`: unprivileged `mokutil --list-new` silently prints nothing even on
success.

**Fix:**

1. `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` — prompts twice for a
   password. **Choose any password you can retype in a few minutes**; it is used
   once, at the MOK Manager screen on the next boot, and never again. Do not
   reuse a real password, and do not write it down anywhere permanent.
   With no TTY available, pipe it: `printf 'pw\npw\n' | sudo mokutil --import ...`
2. Verify it queued: `sudo mokutil --list-new`
3. **Reboot and complete the blue MOK Manager screen by hand** — Enroll MOK →
   Continue → Yes → enter that password. This happens pre-OS and cannot be
   scripted.
4. Confirm: `lsmod | grep vbox` and `sudo modprobe vboxdrv`.

---

## 5. Sabrent NVMe-to-USB enclosures drop off the bus under sustained access

**Symptom:** a drive in a USB enclosure hits an unrecovered sector early in a
Level 3 pass and enters DynaStat deep recovery (thousands of read attempts per
sector, ~5 minutes per sector). After a few hours of that the enclosure
**disappears from the USB bus entirely** — not slow, gone. `lsusb` no longer
lists it, `/dev/sdX` and its `/dev/disk/by-id/*` entries vanish, and `dmesg`
shows a loop of `Timeout while waiting for setup device command` /
`device not accepting address` / `unable to enumerate USB device`, cycling every
~90 seconds indefinitely.

**Cause:** the USB-to-NVMe bridge chip (Realtek RTL9210 in the observed case),
not the drive's media.

**How to tell it apart from a genuinely failing drive:** by-id shows *two*
aliases for the same device — an `ata-<model>_<serial>` one (the real drive
identity via SAT passthrough) and a `usb-Sabrent_<serial>` one (the bridge's own
identity) — both pointing at the same `/dev/sdX`. If a drive behind that alias
pair grinds through DynaStat recovery for hours while a natively-attached drive
in the same run sails through clean, suspect the bridge. Confirm once
reconnected with `smartctl -a /dev/sdX`: if overall-health is PASSED and
Media/Data Integrity Errors are not elevated, the flash is probably fine.

**Fix: physical.** No software workaround exists — the sysfs port node itself is
gone, not merely unauthorized, and forcing a controller-level reset risks taking
down other devices on the same xhci host controller (keyboard, mouse). Unplug and
reseat the enclosure's USB cable, ideally into a different port. It re-enumerates
cleanly.

**Going forward:** a quick ReadSpeed or short scan through such an enclosure is
fine. A full multi-hour Level 3 deep-recovery pass is what triggers the dropout —
for that, connect the drive natively (spare M.2 slot, or a more robust enclosure)
rather than fighting the same bridge repeatedly.

---

## Bonus: automation harnesses may block the attach script

Running `spinrite-attach.sh` through an AI coding agent can be refused by the
agent's own safety classifier ("Irreversible Local Destruction") — reasonably, it
unmounts and hands over whole physical disks. That block is evaluated on the tool
call, not the conversation, so agreeing in chat does not clear it; and trying to
work around it by having the agent edit its own permission settings is blocked
separately as self-modification.

Run the script yourself in a terminal, or add the permission rule yourself. For
Claude Code, that is in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["Bash(~/bin/spinrite-attach.sh:*)"] } }
```

Once the rule exists the agent can invoke it — but the script's
`read -rp "...Type 'yes' to continue: "` prompt has no TTY under a tool call, so
it exits right after printing the discovered-disks table. Pipe the confirmation
in: `echo "yes" | ~/bin/spinrite-attach.sh [exclude-args...]`. Read the table in
the output before doing that, not after.
