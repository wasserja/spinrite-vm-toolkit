# SpinRite VM Toolkit

<https://github.com/wasserja/spinrite-vm-toolkit>

Scripts, documentation and a Claude Code skill for running **GRC SpinRite** and
**ReadSpeed** against real physical drives from a persistent Kubuntu live USB —
by giving a FreeDOS VirtualBox VM raw passthrough access to the host's disks.

One USB stick, carried between machines. Boot it on a computer, let it discover
that machine's drives, attach them to the DOS VM, and run a maintenance pass.

This builds on the GRC forums' "how to run SpinRite on a UEFI-only machine, Linux
as base OS" series — see **[docs/origins.md](docs/origins.md)** for those threads
and for what this repo adds on top of them (automatic disk discovery, stable
`by-id`-keyed raw VMDK pointers, a staleness check that catches a real
data-integrity trap, and operational knowledge encoded as a skill).

---

## ⚠️ Read this before running anything

`bin/spinrite-attach.sh` **unmounts every partition on every disk it discovers**
and hands those disks raw to a DOS utility that, at Level 3, rewrites every
sector. That is the intended behavior. It is also exactly what you do not want
pointed at the wrong drive.

- The script prints a table of what it found and **requires you to type `yes`**.
  Read the table first.
- The live boot USB is always excluded automatically (identified via its
  `/cdrom` mount, not a hardcoded device letter).
- Exclude anything else by name: `spinrite-attach.sh sde sdf`.
- **Have backups.** SpinRite is a maintenance and recovery tool, not a backup
  strategy.
- Level 3 warns on-screen that it is not recommended for SSD, hybrid or SMR
  drives, because it is a read + rewrite pass. Running it on SSDs anyway is a
  deliberate choice — make it knowingly.

## SpinRite is not included

SpinRite and ReadSpeed are commercial products of
[Gibson Research Corporation](https://www.grc.com/spinrite.htm). **No GRC
software is in this repository and none ever will be.** You supply your own
licensed copy and place it on the FreeDOS VM's `C:` drive — see
[docs/vm-build.md](docs/vm-build.md).

## Requirements

- A persistent Kubuntu (or similar) live USB — see
  [docs/live-usb-setup.md](docs/live-usb-setup.md)
- VirtualBox 7.x with working DKMS kernel modules
- Membership in the `disk` group (with the caveat in
  [docs/troubleshooting.md](docs/troubleshooting.md) — it does not take effect
  the way you expect)
- A FreeDOS VM named `SRDOS` — see [docs/vm-build.md](docs/vm-build.md)
- Your own licensed SpinRite 6.1

## Quick start

```bash
# 1. get the repo
git clone https://github.com/wasserja/spinrite-vm-toolkit.git
cd spinrite-vm-toolkit

# 2. install the scripts
mkdir -p ~/bin
cp bin/spinrite-attach.sh bin/spinrite-backup.sh bin/spinrite-track.py ~/bin/
chmod +x ~/bin/spinrite-*

# 3. optional: desktop launcher (edit YOUR_USER in the Exec= line first)
cp desktop/spinrite-attach.desktop ~/Desktop/

# 4. optional: the Claude Code skill
mkdir -p ~/.claude/skills && cp -r skills/virtualbox-dos-vm ~/.claude/skills/

# 5. check what this stick has already done, then run
~/bin/spinrite-track.py report
~/bin/spinrite-attach.sh
```

Then follow [docs/workflow.md](docs/workflow.md): ReadSpeed baseline → SpinRite
Level 3 → ReadSpeed again → record the run → back up the stick.

## What's here

```
bin/
  spinrite-attach.sh     discover physical disks, attach to the VM, launch it
  spinrite-backup.sh     tar the whole setup into a timestamped archive
  spinrite-track.py      the run tracker (CSV report / add / update)
desktop/
  spinrite-attach.desktop   launcher template for the attach script
skills/
  virtualbox-dos-vm/     Claude Code skill: VBoxManage operations and gotchas
vm/
  SRDOS.vbox.example     sanitized VM definition, for reference
examples/
  spinrite-tracker.example.csv
docs/
  origins.md             the GRC forum threads this extends, and what's new here
  live-usb-setup.md      building the live USB host
  vm-build.md            creating SRDOS and getting SpinRite onto C:
  workflow.md            the canonical per-machine session, start to finish
  troubleshooting.md     five problems that cost real time to diagnose
  field-notes.md         benchmark interpretation, AUTO mode, hardware findings
  tracking.md            the run tracker
```

## The Claude Code skill

[`skills/virtualbox-dos-vm/SKILL.md`](skills/virtualbox-dos-vm/SKILL.md) is the
largest single artifact here. It encodes the VBoxManage-level operational
knowledge: the permission and crash footguns, attaching raw disks and images,
reading the FreeDOS guest disk from the host, driving SpinRite and ReadSpeed by
synthetic keystrokes, and SpinRite's command-line AUTO mode.

Copy it to `~/.claude/skills/virtualbox-dos-vm/` and Claude Code will load it when
you start working on the VM. It is useful as plain reading material too — it is
where most of the sharp edges are written down.

## Privacy note

Nothing in this repo carries drive serial numbers, computer service tags,
credentials or host state. The `.gitignore` blocks the categories that would:
VM disk images (`*.vdi`), raw disk pointers (`*.vmdk`), backup tarballs
(`*.tar.gz`), the real tracker CSV, and `.claude/`. If you fork this and start
committing your own run history, check what is in it first.

## License

MIT — see [LICENSE](LICENSE). Covers only the scripts, skill and documentation
here. SpinRite and ReadSpeed remain GRC's.
