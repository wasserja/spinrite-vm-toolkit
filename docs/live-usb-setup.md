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

Raw physical-disk passthrough needs read/write access to the block devices, which
means the `disk` group:

```
sudo usermod -aG disk "$USER"
```

**This does not take effect the way you expect.** See Gotcha 1 in
`docs/troubleshooting.md` before you conclude the permissions are broken —
`sg disk -c ...` does *not* fix VirtualBox, and the symptom (a medium showing as
`inaccessible` with `Capacity: 0 MBytes`) looks nothing like a group problem.

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
