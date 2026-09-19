# Origins — what this extends

This repo is an extension of an existing, well-documented approach from the GRC
(Gibson Research Corporation) forums: running SpinRite on a UEFI-only machine by
using Linux as the base OS and giving a DOS virtual machine raw access to the
physical disks.

## Upstream source

The live-USB build and the "Linux as base OS" approach come from this two-part
forum series — read these first, they are the foundation:

- **Part 3a of 5 — Linux as base OS**
  https://forums.grc.com/threads/how-to-run-spinrite-on-a-uefi-only-machine-part-3a-of-5-linux-as-base-os.1617/
- **Part 3b of 5 — Linux as base OS**
  https://forums.grc.com/threads/how-to-run-spinrite-on-a-uefi-only-machine-part-3b-of-5-linux-as-base-os.1618/

General upstream references:

- SpinRite: https://www.grc.com/spinrite.htm
- ReadSpeed: https://www.grc.com/readspeed.htm
- GRC forums: https://forums.grc.com/
- Community SpinRite 6.1 wiki (command-line reference):
  https://gitlab.com/GRC-Community/spinrite-6.1-wiki/-/wikis/Command-Line
  Note: that wiki page is a JavaScript-rendered shell, so `curl`/fetch on the
  page URL returns nothing useful. Pull the raw content through the GitLab API
  instead:
  `https://gitlab.com/api/v4/projects/GRC-Community%2Fspinrite-6.1-wiki/wikis/Command-Line?with_content=1`

## What this repo adds

The forum threads get you to a working live USB with VirtualBox and a DOS VM.
Everything below is what got built on top of that, because attaching the right
physical disks by hand every time — on a stick that gets carried between many
different machines — is where the process actually goes wrong.

**Automatic disk discovery that can't eat the boot USB.**
`bin/spinrite-attach.sh` enumerates every physical disk on the machine and
excludes the live USB it is running from, identified via the device backing the
`/cdrom` mount rather than a hardcoded `/dev/sdX`. Device letters reassign on
every boot depending on what is plugged in, so a hardcoded exclusion is a
liability on a stick that boots on different hardware each time.

**Raw VMDK pointers keyed on stable drive identity.**
Pointer files are named after the `/dev/disk/by-id/` basename (which encodes
model + serial) instead of the ephemeral device node. That name is stable across
boots *and* across different physical machines, so the same drive gets the same
pointer wherever it turns up.

**A staleness check that catches a real data-integrity trap.**
A raw-disk VMDK descriptor bakes in its extent size at creation time and never
re-reads it from the live device. Reuse a leftover pointer for a different,
larger disk and the guest silently reports the old, smaller capacity — no error,
no `inaccessible` state, just a quietly wrong disk. Before reusing any existing
pointer the script compares the descriptor's baked-in sector count against
`blockdev --getsize64` on the live device and recreates it if they have drifted.
See `docs/troubleshooting.md`.

**Stale-attachment cleanup.**
Every run detaches whatever is sitting on the AHCI controller before attaching
what it just discovered, so a disk attached during a previous session on
different hardware cannot linger alongside the real one.

**A guard against the VM-crash footgun.**
The VBoxSVC group-permission fix (see `docs/troubleshooting.md`) involves killing
VBoxSVC — which will crash a running VM. The script checks for a live
`VirtualBoxVM` process first and refuses to touch anything if one exists.

**A Claude Code skill.**
`skills/virtualbox-dos-vm/SKILL.md` encodes the VBoxManage-level operational
knowledge — the permission gotchas, raw disk and image attachment, reading the
FreeDOS guest disk from the host, and driving SpinRite/ReadSpeed by synthetic
keystrokes or command-line AUTO mode. With it loaded, the whole run can be driven
conversationally instead of from memory.

**A run tracker.**
`bin/spinrite-track.py` plus a CSV records which drive on which computer was
scanned when, with before/after benchmark numbers — so a stick carried across a
fleet doesn't lose track of what has already been done. See `docs/tracking.md`.
