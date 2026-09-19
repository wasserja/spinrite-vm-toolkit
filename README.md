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

`bin/spinrite-attach.sh attach` **unmounts every partition on every disk you give
it** and hands those disks raw to a DOS utility that, at Level 3, rewrites every
sector. That is the intended behavior. It is also exactly what you do not want
pointed at the wrong drive.

- **Listing is the default and is read-only.** `spinrite-attach.sh` with no
  arguments, or `spinrite-attach.sh list`, only prints what it found. Nothing is
  unmounted, attached or started without the word `attach`.
- `attach` prints the table with the selected disks marked and **requires you to
  type `yes`**. Read the table first.
- Say which disks explicitly — `attach sdb sdc` attaches only those;
  `attach --all` attaches everything discovered; `attach --all --except sde` leaves
  one out.
- Disks can be named by **serial substring** instead of device letter —
  `attach S0EXAMPLE000001`. Device letters reassign on every boot; serials do not,
  and they are what the tracker records, so a batch list written down in one
  session can be replayed verbatim in the next. A substring must be at least 4
  characters and match exactly one drive, or the script refuses rather than
  guessing.
- The live boot USB is always excluded automatically (identified via its
  `/cdrom` mount, not a hardcoded device letter).
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
- Membership in the `disk` group (for raw disk access) and `vboxusers` (for USB
  passthrough) — see [docs/live-usb-setup.md](docs/live-usb-setup.md), and note
  the `disk` change does not take effect the way you expect
  ([docs/troubleshooting.md](docs/troubleshooting.md))
- A FreeDOS VM named `SRDOS` — `bin/spinrite-vm-build.sh` builds it from GRC's
  pre-built appliance, see [docs/vm-build.md](docs/vm-build.md)
- Your own licensed SpinRite 6.1

## Quick start

```bash
# 1. get the repo
git clone https://github.com/wasserja/spinrite-vm-toolkit.git
cd spinrite-vm-toolkit

# 2. install the scripts
mkdir -p ~/bin
cp bin/spinrite-vm-build.sh bin/spinrite-attach.sh bin/spinrite-backup.sh \
   bin/spinrite-track.py ~/bin/
chmod +x ~/bin/spinrite-*

# 3. optional: desktop launcher (edit YOUR_USER in the Exec= line first)
cp desktop/spinrite-attach.desktop ~/Desktop/

# 4. optional: the Claude Code skill
mkdir -p ~/.claude/skills && cp -r skills/virtualbox-dos-vm ~/.claude/skills/

# 5. build the SRDOS VM (once per stick) -- needs GRC's SRDOS.OVA and your
#    own licensed SpinRite; neither is downloaded for you
~/bin/spinrite-vm-build.sh --spinrite ~/Downloads/SpinRite.img

# 6. check what this stick has already done, look, then run
~/bin/spinrite-track.py report
~/bin/spinrite-attach.sh list
~/bin/spinrite-attach.sh attach --all

# 7. occasional housekeeping: clear stale VirtualBox media registry entries
~/bin/spinrite-attach.sh prune
```

Then follow [docs/workflow.md](docs/workflow.md): ReadSpeed baseline → SpinRite
Level 3 → ReadSpeed again → record the run → back up the stick. Or hand the whole
sequence to Claude Code — see [Let Claude Code drive it](#let-claude-code-drive-it).

## What's here

```
bin/
  spinrite-vm-build.sh   build the SRDOS VM from GRC's appliance + your SpinRite
  spinrite-attach.sh     list physical disks; attach the chosen ones and launch;
                         prune the stale VirtualBox media registry
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
  roadmap.md             what is untested or unbuilt, and why it matters
```

## Let Claude Code drive it

[`skills/virtualbox-dos-vm/SKILL.md`](skills/virtualbox-dos-vm/SKILL.md) is the
largest single artifact here, and it is not just reference material — it is the
session itself, written down. Copy it to `~/.claude/skills/virtualbox-dos-vm/` and
you can stop running the steps by hand:

> check this machine's drives

> run the SpinRite workflow here, skip the external USB drive

The skill carries the order of operations (tracker first, then the driver check,
then attach), the SpinRite command line, how to drive the DOS guest by synthetic
keystrokes, how to read the run log off a FreeDOS disk from the host, what to put in
the tracker, and the two things that must never happen to a running VM.

Two practical notes:

- An agent's own safety classifier may refuse to run the attach script, since it
  unmounts and hands over whole physical disks. Adding
  `{ "permissions": { "allow": ["Bash(~/bin/spinrite-attach.sh:*)"] } }` to
  `~/.claude/settings.json` yourself clears that — the agent cannot grant it to
  itself. See [docs/troubleshooting.md](docs/troubleshooting.md).
- Use `--yes` for agent-driven attaches; the typed confirmation has no terminal to
  read from under a tool call.

**The division of labour stays put.** The agent drives the VM, reads screens,
extracts numbers and writes the tracker row. You read the disk table and decide
which drives get written to. Nothing in the skill changes who confirms that.

It is useful as plain reading material too — it is where most of the sharp edges are
written down.

## Privacy note

Nothing in this repo carries drive serial numbers, computer service tags,
credentials or host state. The `.gitignore` blocks the categories that would:
VM disk images (`*.vdi`), raw disk pointers (`*.vmdk`), backup tarballs
(`*.tar.gz`), the real tracker CSV, and `.claude/`. If you fork this and start
committing your own run history, check what is in it first.

## License

MIT — see [LICENSE](LICENSE). Covers only the scripts, skill and documentation
here. SpinRite and ReadSpeed remain GRC's.
