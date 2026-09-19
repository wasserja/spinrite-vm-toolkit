# Building the SRDOS FreeDOS VM

> **Faster path first:** GRC forums part 5a offers a pre-built appliance,
> `SRDOS.OVA` (~1 MB), with FreeDOS and ReadSpeed already installed — import it
> with `File | Import Appliance` and skip to "Getting SpinRite onto C:" below.
> See `docs/origins.md` for the link and its caveats. Build from scratch if you
> want to understand the machine, or if the appliance won't import.

`bin/spinrite-attach.sh` expects a VirtualBox VM named `SRDOS` with a specific
controller layout. `vm/SRDOS.vbox.example` is a sanitized copy of a working
definition — it documents the shape, but it is not a drop-in file (the licensed
SpinRite lives on a disk image that is deliberately not in this repo).

## The layout the scripts assume

| Controller | Type | Use |
|---|---|---|
| `Floppy` | I82078 | Left **empty**. Not needed for normal use. |
| `PIIX4` | IDE, 2 ports | Port 0 = FreeDOS `C:` system disk. Port 1 kept free for temporarily attaching a DOS utility image. |
| `AHCI` | SATA, 3 ports | Where raw physical disks get attached. `PortCount` caps how many drives one run can handle. |

### Why AHCI, and what it costs

The upstream guide (forum part 3b, `docs/origins.md`) lays out the trade-off between
the two controllers you could hang physical disks off:

- **IDE** — *"Can only add up to 3 drives, as IDE only supports 4 total"*, but
  *"Faster operation (SpinRite native IDE driver works)"*.
- **AHCI** — *"Can have up to 30 drives (ports 0 to 29)"*, but *"Drives are seen as
  BIOS attached; SpinRite native AHCI doesn't work for some reason"* and *"BIOS
  access may be an order of magnitude slower than IDE (or the same speed, you need
  to test and see!!)"*.

This toolkit uses AHCI, and the consequence is visible: SpinRite's drive-select
screen reports the access mode as `BIOS extend v3.0`, and its own benchmark reads
roughly a quarter of what ReadSpeed reports for the same drive on the same day. A
reply in that thread argues AHCI is in fact faster on drives with real errors.
Nobody here has measured it — it is on `docs/roadmap.md`.

### How many drives one run can carry

Two separate ceilings, and only one of them is a setting:

- **`PortCount` on the AHCI controller** — 3 as built. Raising it is one command:
  `VBoxManage storagectl SRDOS --name AHCI --portcount <n>` (up to 30).
- **The guest BIOS drive table.** SpinRite reaches these disks as BIOS-attached
  drives (`BIOS 81`, `BIOS 82`, ...), so whether it sees drives beyond the first few
  is a property of the BIOS, not of `PortCount`. This has not been tested past 3.

Because the second ceiling is the unknown one, the documented answer to "more disks
than slots" is to run them in batches rather than to raise `PortCount` and hope —
see `docs/workflow.md` §3a. `bin/spinrite-attach.sh` reads the live `PortCount` and
refuses an over-capacity selection before attaching anything.

Guest: `OSType=DOS`, 128 MB RAM, 9 MB VRAM. DOS needs nothing more.

The names matter. `spinrite-attach.sh` hardcodes `CONTROLLER="AHCI"` and
`VM_NAME="SRDOS"`; both are single variables at the top of the script if you want
different ones.

## Creating it

```
VBoxManage createvm --name SRDOS --ostype DOS --register
VBoxManage modifyvm SRDOS --memory 128 --vram 9 --nic1 none --audio-enabled off

VBoxManage storagectl SRDOS --name Floppy --add floppy
VBoxManage storagectl SRDOS --name PIIX4  --add ide  --controller PIIX4 --bootable on
VBoxManage storagectl SRDOS --name AHCI   --add sata --controller IntelAHCI --portcount 3 --bootable on

# FreeDOS system disk. 5 MB is plenty for FreeDOS + SpinRite + ReadSpeed + logs.
VBoxManage createmedium disk \
  --filename "$HOME/VirtualBox VMs/SRDOS/SRDOS-disk001.vdi" --size 5 --format VDI
VBoxManage storageattach SRDOS --storagectl PIIX4 --port 0 --device 0 \
  --type hdd --medium "$HOME/VirtualBox VMs/SRDOS/SRDOS-disk001.vdi"
```

Then install FreeDOS onto that disk from the FreeDOS installer ISO (attach it to
the IDE controller's port 1 or as a DVD, boot, install, detach).

## Getting SpinRite onto C:

SpinRite is a commercial product from GRC. It is not in this repo and never will
be. Supply your own licensed copy.

SpinRite ships as a self-extracting installer that writes a bootable image. The
practical path is to get `SPINRITE.EXE` (and `RS.EXE` for ReadSpeed) onto the
FreeDOS `C:` disk once, after which the floppy/image is never needed again.

**Attaching a raw `.img` file fails** — `storageattach --medium some.img` returns
`VERR_NOT_SUPPORTED`, because VBoxManage cannot sniff the format of a bare raw
file the way it can a `.vmdk`/`.vdi`. Convert it first:

```
VBoxManage convertfromraw spinrite.img "$HOME/VirtualBox VMs/SRDOS/spinrite.vdi" --format VDI
VBoxManage storageattach SRDOS --storagectl PIIX4 --port 1 --device 0 \
  --type hdd --medium "$HOME/VirtualBox VMs/SRDOS/spinrite.vdi"
```

Boot the VM, `dir` to find which letter it landed on, `copy d:\spinrite.exe c:\`,
then detach (`--medium none` on that port) and delete the temporary `.vdi`.

## Boot behavior

With the floppy slot empty and no CD attached, the VM falls through the
floppy/CD boot failures and lands at a plain `C:\>` FreeDOS prompt.

Two things worth knowing so you don't misread a normal boot as a crash:

- A "Boot from Floppy 0 failed" / "Boot from CD-ROM failed" screen is **expected
  transient text** before it reaches the C: disk. Give it a few more seconds.
  Don't reflexively reattach the SpinRite floppy.
- `SPINRITE.EXE` and `RS.EXE` do **not** auto-run on boot. You launch them from
  the `C:\>` prompt.

If the floppy *is* attached, boot lands at `A:\>` instead; type `c:` to switch.
No F12/boot-menu juggling either way.

## Verifying a file landed on C: without booting the VM

The VM has no Guest Additions and no shared folders. To inspect the FreeDOS disk
from the host (VM must be powered off):

```
VBoxManage clonemedium "SRDOS-disk001.vdi" /tmp/check.raw --format RAW   # non-destructive
fdisk -l /tmp/check.raw                      # find the FAT partition's start sector
sudo mount -o ro,loop,offset=$((START_SECTOR*512)) /tmp/check.raw /mnt/point
ls /mnt/point
sudo umount /mnt/point && rm /tmp/check.raw
```

This is also how you pull SpinRite's run logs (`C:\SRLOGS\<N>.LOG`) off the
guest — the minimal FreeDOS install has no `FIND.EXE`/`MORE.COM`, so you cannot
page or grep a log file from inside DOS.
