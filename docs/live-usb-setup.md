# Building the live USB host

This is a summary of the host environment the rest of the repo assumes. The
authoritative build instructions are the GRC forum threads linked in
`docs/origins.md` — read those first. This page covers what matters for the
scripts here, plus the things that only show up once you start carrying the same
stick between different machines.

## What the host is

A **persistent** Kubuntu live USB — not a plain live image. Persistence matters:
the FreeDOS VM, your licensed SpinRite, the scripts and the run tracker all have
to survive a reboot, because the whole point is to carry one stick from machine
to machine.

Reference configuration this was built and tested on:

| Item | Value |
|---|---|
| Base OS | Kubuntu live USB, writable persistence overlay (~21 GB) |
| USB stick | 128 GB (93 GB live partition + 21 GB persistence) |
| Virtualizer | VirtualBox 7.0.x with DKMS kernel modules |
| Guest | FreeDOS, 128 MB RAM, named `SRDOS` |
| Host partition layout | live image on `<usb>1` mounted at `/cdrom`, persistence on `<usb>2` |

The scripts detect the boot device from the `/cdrom` mount, so that mount point
is load-bearing. If your live image mounts its media somewhere else, adjust the
`findmnt -no SOURCE /cdrom` line near the top of `bin/spinrite-attach.sh`.

## Host packages

```
sudo apt update
sudo apt install virtualbox virtualbox-dkms virtualbox-qt
```

Reference version: `7.0.16_Ubuntu`.

## Group permissions

This is the part that is easy to get wrong, because the group you actually need
is not the one with "vbox" in the name. Two groups, two different jobs:

```
sudo usermod -aG disk "$USER"          # required: raw physical-disk passthrough
sudo usermod -aG vboxusers "$USER"     # USB passthrough to the guest
```

**`disk` is the one that matters here.** Block devices are `root:disk` mode
`0660`:

```
$ ls -la /dev/sda
brw-rw---- 1 root disk 8, 0 /dev/sda
```

Without membership in `disk`, VirtualBox cannot open the raw device behind a
`.vmdk` pointer, and `bin/spinrite-attach.sh` fails at `storageattach`/`startvm`.

**`vboxusers` is not about disks.** VirtualBox's udev rules use it for USB
device nodes — `/lib/udev/rules.d/60-virtualbox.rules` runs
`VBoxCreateUSBNode.sh ... vboxusers` on USB add. You want it if you ever pass a
USB device through to the guest; it does nothing for raw disk access. Add it
anyway, it's standard and harmless.

### Do not "fix" /dev/vboxdrv

It looks broken. It isn't:

```
$ ls -la /dev/vboxdrv
crw------- 1 root root 10, 119 /dev/vboxdrv
```

Mode `0600`, owned by `root:root`, and no group can reach it. That is deliberate
— `/lib/udev/rules.d/60-virtualbox-dkms.rules` sets it explicitly, and it is
restored on every boot, so chmod/chown changes do not survive anyway.

Ubuntu ships VirtualBox's **hardened** build, where the binaries that need the
driver are setuid root:

```
$ ls -la /usr/lib/virtualbox/VirtualBoxVM
-rwsr-sr-x 1 root root ... /usr/lib/virtualbox/VirtualBoxVM
```

Those setuid stubs open `/dev/vboxdrv`, not your user. Loosening its permissions
gains you nothing and weakens a deliberate boundary. If VMs will not start, the
cause is a missing/unsigned kernel module (see Secure Boot below) or the VBoxSVC
credential gotcha (next), never this device node.

### The group change does not reach VirtualBox the way you expect

**Read Gotcha 1 in `docs/troubleshooting.md` before concluding permissions are
broken.** `sg disk -c '...'` does *not* fix VBoxManage, and the symptom — a
medium showing `State: inaccessible` with `Capacity: 0 MBytes` — looks nothing
like a group problem. `bin/spinrite-attach.sh` works around it by routing every
VBoxManage call through `sudo -iu "$(id -un)"`.

### Verify

```
id                       # expect ... 6(disk) ... 125(vboxusers) ...
getent group disk        # expect your username listed
test -r /dev/sda && echo "raw read OK"
lsmod | grep vbox        # expect vboxdrv, vboxnetflt, vboxnetadp
VBoxManage list hostinfo # expect real output, not an error
```

A fresh login is required after `usermod` — on a live USB, a reboot is simplest.

### This is per-stick, not per-machine

Group membership lives in `/etc/group` on the persistence overlay, so it is
configured once per USB stick and survives reboots on any machine. Contrast with
Secure Boot MOK enrollment below, which lives in each machine's firmware and must
be redone on every new machine you boot on.

Note that `bin/spinrite-backup.sh` does **not** capture `/etc/group` — if you
rebuild a stick from a backup archive, redo the `usermod` commands above by hand.

## Secure Boot

On a machine with Secure Boot enabled, `sudo modprobe vboxdrv` can fail with
`Key was rejected by service` even though `dkms status` shows the module built
and installed. This is not a build problem — it is MOK (Machine Owner Key)
enrollment, and MOK trust lives in **each machine's own UEFI firmware**, not on
the USB stick. Expect to hit it once per *new* machine you boot the stick on.
Full fix in `docs/troubleshooting.md`.

## Installing this repo onto the stick

```
# scripts
mkdir -p ~/bin
cp bin/spinrite-attach.sh bin/spinrite-backup.sh bin/spinrite-track.py ~/bin/
chmod +x ~/bin/spinrite-*

# optional desktop launcher (edit YOUR_USER in the Exec= line first)
cp desktop/spinrite-attach.desktop ~/Desktop/

# optional: the Claude Code skill
mkdir -p ~/.claude/skills
cp -r skills/virtualbox-dos-vm ~/.claude/skills/
```

Then build the VM — see `docs/vm-build.md`.

## Networking note

If the machine you boot on normally provides DHCP/DNS for its own network, it
cannot lease an address from itself and needs a static IP. Worth knowing because
NetworkManager has a real gotcha here: editing a connection's IPv4 settings
rewrites the saved profile but does **not** reliably push a DNS-only change to
the live interface — `resolvectl status` keeps reporting the old nameserver until
something forces a reapply (`nmcli device reapply <dev>` or
`nmcli connection up <name>`). If `resolvectl status <dev>` disagrees with
`nmcli device show <dev>`'s `IP4.DNS`, that is this gap. Not SpinRite-specific,
and not scripted here, but it will cost you an afternoon if you hit it blind.

## Keeping it backed up

A live USB is a consumable. `bin/spinrite-backup.sh` tars the scripts, the VM
definition, the FreeDOS C: disk (which holds SpinRite and every `RS0NN.TXT`
results log), the Claude skill/memory directories and the run tracker into a
single timestamped archive under `~/spinrite-backups/`, with a restore mapping in
its README. Upload that archive somewhere off the stick.

**That archive contains your licensed SpinRite. Never commit it to git** — the
`.gitignore` here blocks `*.tar.gz` and `*.vdi` for exactly this reason.
