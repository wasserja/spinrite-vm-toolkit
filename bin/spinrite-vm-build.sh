#!/usr/bin/env bash
# Build the SRDOS FreeDOS VM from GRC's pre-built appliance, and put your own
# licensed SpinRite on its C: drive.
#
# Both inputs are files YOU supply. This script downloads nothing: the appliance
# is hosted on a personal OneDrive link from a forum thread (docs/origins.md),
# and SpinRite is a commercial product that is never fetched, bundled or
# committed by anything in this repo.
set -euo pipefail

VM_NAME="SRDOS"
OVA=""
SPINRITE_SRC=""
BASEFOLDER=""
ASSUME_YES=0
SELF="$(basename "$0")"

# sha256 of the SRDOS.OVA this toolkit was built and tested against. GRC
# publishes no checksum, so this is a "same file I had" check, not a chain of
# trust -- a mismatch warns, it does not stop the build.
KNOWN_OVA_SHA256="f5798a5e8fadf0b2bc042ddf5d10640baeb4d1839a9a7133355db72d410b35c8"

OVA_URL="https://forums.grc.com/threads/how-to-run-spinrite-on-a-uefi-only-machine-part-5a-of-5-using-pre-built-vm.1619/"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SELF --spinrite <path> [--ova <path>] [--name $VM_NAME] [--basefolder <dir>] [--yes]
  $SELF --help

  --spinrite <path>  Your licensed SpinRite: either SPINRITE.EXE itself, or the
                     bootable .img the GRC installer writes (mounted read-only,
                     SPINRITE.EXE lifted out of it). Required.
  --ova <path>       GRC's pre-built appliance. Default: ~/Downloads/SRDOS.ova
  --name <name>      VM name to create. Default: $VM_NAME
  --basefolder <dir> Where to put the VM. Default: VirtualBox's own default.
  --yes              Skip the confirmation.

Creates the VM the rest of this toolkit expects: controllers Floppy / PIIX4 /
AHCI, FreeDOS on PIIX4 port 0, three free AHCI ports for physical disks.

Nothing is downloaded and no existing VM is modified -- if a VM named <name>
already exists, this refuses to run.
EOF
}

usage_die() { printf 'ERROR: %s\n\n' "$1" >&2; usage >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --spinrite)   [ $# -ge 2 ] || usage_die "--spinrite needs a path"; SPINRITE_SRC="$2"; shift 2 ;;
    --ova)        [ $# -ge 2 ] || usage_die "--ova needs a path"; OVA="$2"; shift 2 ;;
    --name)       [ $# -ge 2 ] || usage_die "--name needs a value"; VM_NAME="$2"; shift 2 ;;
    --basefolder) [ $# -ge 2 ] || usage_die "--basefolder needs a path"; BASEFOLDER="$2"; shift 2 ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage_die "unknown argument: $1" ;;
  esac
done

: "${OVA:=$HOME/Downloads/SRDOS.ova}"

command -v VBoxManage >/dev/null || die "VBoxManage not found"

VBM() {
  # Same reason as spinrite-attach.sh: keep VBoxSVC's credentials consistent for
  # the whole run. See docs/troubleshooting.md §1.
  sudo -iu "$(id -un)" -- VBoxManage "$@"
}

# ------------------------------------------------------------------- checks

[ -n "$SPINRITE_SRC" ] || usage_die "--spinrite is required: this script will not supply SpinRite for you."
[ -f "$SPINRITE_SRC" ] || die "--spinrite $SPINRITE_SRC: no such file."

if [ ! -f "$OVA" ]; then
  die "No appliance at $OVA.

  GRC's pre-built SRDOS.OVA is linked from forum part 5a:
    $OVA_URL
  Download it yourself and pass --ova <path>. This script will not fetch it."
fi

if VBM showvminfo "$VM_NAME" --machinereadable >/dev/null 2>&1; then
  die "A VM named '$VM_NAME' already exists. Refusing to touch it.
  Pick another name with --name, or remove the existing VM first:
    VBoxManage unregistervm '$VM_NAME' --delete"
fi

# --- verify the appliance ------------------------------------------------
# The OVA ships its own manifest (SRDOS.mf: SHA1 per member). That is a real
# integrity check on the contents even though GRC publishes no checksum for the
# archive as a whole.
log "Verifying $OVA ..."
tar tf "$OVA" >/dev/null 2>&1 || die "$OVA is not a readable tar archive -- an OVA should be."

mf=$(tar xOf "$OVA" --wildcards '*.mf' 2>/dev/null || true)
if [ -n "$mf" ]; then
  while read -r algo name eq want; do
    [ -n "${want:-}" ] || continue
    name="${name#(}"; name="${name%)}"
    case "$algo" in
      SHA1)   got=$(tar xOf "$OVA" "$name" | sha1sum   | awk '{print $1}') ;;
      SHA256) got=$(tar xOf "$OVA" "$name" | sha256sum | awk '{print $1}') ;;
      *)      log "  ? $name: unknown digest '$algo', skipped"; continue ;;
    esac
    if [ "$got" = "$want" ]; then
      log "  OK $name ($algo)"
    else
      die "$name fails its own manifest: expected $want, got $got. The appliance is corrupt or truncated."
    fi
  done <<< "$mf"
else
  log "  ! No manifest inside the OVA -- contents not verified."
fi

ova_sha=$(sha256sum "$OVA" | awk '{print $1}')
if [ "$ova_sha" = "$KNOWN_OVA_SHA256" ]; then
  log "  OK whole archive matches the appliance this toolkit was tested against."
else
  log "  ! This is not byte-identical to the appliance this toolkit was tested"
  log "    against (expected ${KNOWN_OVA_SHA256:0:16}..., got ${ova_sha:0:16}...)."
  log "    Not necessarily wrong -- GRC publishes no checksum and forum replies"
  log "    mention re-writing the manifest for newer VirtualBox. Proceeding."
fi

# --- confirm -------------------------------------------------------------
log ""
log "About to create VM '$VM_NAME' from $OVA"
log "and install SpinRite from $SPINRITE_SRC onto its C: drive."
log ""
if [ "$ASSUME_YES" = 1 ]; then
  log "--yes given; skipping confirmation."
else
  read -rp "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || die "Aborted by user."
fi

WORK=$(mktemp -d)
MOUNTED=""
cleanup() {
  [ -n "$MOUNTED" ] && sudo umount "$MOUNTED" 2>/dev/null || true
  [ -n "${RAW:-}" ] && [ -f "${RAW:-}" ] && VBM closemedium disk "$RAW" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------- import

# The appliance carries a sound card and a second IDE controller that this
# toolkit has no use for. Drop them at import time rather than detaching them
# afterwards. Unit numbers are per-OVF, so find them instead of hardcoding.
log ""
log "Reading the appliance descriptor ..."
dry=$(VBM import "$OVA" --dry-run 2>&1) || die "Could not interpret $OVA:
$dry"

ignore_args=()
while read -r unit desc; do
  case "$desc" in
    *"Sound card"*) ignore_args+=(--vsys 0 --unit "$unit" --ignore); log "  ignoring unit $unit (sound card)" ;;
  esac
done < <(printf '%s\n' "$dry" | sed -n 's/^ *\([0-9]\+\): \(.*\)$/\1 \2/p')

# Keep the FIRST IDE controller (the FreeDOS disk hangs off it); drop any extra.
ide_seen=0
while read -r unit desc; do
  case "$desc" in
    "IDE controller"*)
      ide_seen=$((ide_seen + 1))
      if [ "$ide_seen" -gt 1 ]; then
        ignore_args+=(--vsys 0 --unit "$unit" --ignore)
        log "  ignoring unit $unit (spare IDE controller)"
      fi
      ;;
  esac
done < <(printf '%s\n' "$dry" | sed -n 's/^ *\([0-9]\+\): \(.*\)$/\1 \2/p')

import_args=(import "$OVA" --vsys 0 --vmname "$VM_NAME")
[ -n "$BASEFOLDER" ] && import_args+=(--vsys 0 --basefolder "$BASEFOLDER")
import_args+=(${ignore_args[@]+"${ignore_args[@]}"})

log "Importing as '$VM_NAME' ..."
VBM "${import_args[@]}" >/dev/null 2>&1 || die "Import failed. Run it by hand to see why:
  VBoxManage ${import_args[*]}"

# VirtualBox names the imported controllers Floppy / PIIX4 / AHCI already, and
# the appliance is 128MB RAM / 9MB VRAM / DOS with AHCI portcount 3 -- exactly
# what this toolkit expects. Assert it rather than assume it.
vminfo=$(VBM showvminfo "$VM_NAME" --machinereadable)
for want in Floppy PIIX4 AHCI; do
  printf '%s\n' "$vminfo" | grep -q "^storagecontrollername[0-9]*=\"$want\"$" \
    || die "Imported VM has no '$want' controller. The appliance layout is not what this toolkit expects; see docs/vm-build.md."
done
VBM modifyvm "$VM_NAME" --nic1 none >/dev/null 2>&1 || true

disk=$(printf '%s\n' "$vminfo" | sed -n 's/^"PIIX4-0-0"="\(.*\)"$/\1/p')
[ -n "$disk" ] && [ -f "$disk" ] || die "No FreeDOS disk found on PIIX4 port 0 after import."
log "  FreeDOS disk: $disk"

# --------------------------------------------------- SpinRite onto C:

# Done entirely on the host. Booting the guest to `copy d:\spinrite.exe c:\`
# works too (docs/vm-build.md keeps it as the fallback) but needs synthetic
# keystrokes and timing guesses, which do not belong in a build script.
log ""
log "Installing SpinRite onto C: ..."

SPIN_DIR="$WORK/spin"
mkdir -p "$SPIN_DIR" "$WORK/c"
case "$SPINRITE_SRC" in
  *.[iI][mM][gG])
    log "  Reading $SPINRITE_SRC (read-only) ..."
    sudo mount -o ro,loop "$SPINRITE_SRC" "$SPIN_DIR" || die "Could not mount $SPINRITE_SRC. Is it the bootable image the SpinRite installer writes?"
    MOUNTED="$SPIN_DIR"
    src=$(find "$SPIN_DIR" -maxdepth 1 -iname 'spinrite.exe' | head -1)
    [ -n "$src" ] || { sudo umount "$SPIN_DIR"; MOUNTED=""; die "No SPINRITE.EXE inside $SPINRITE_SRC."; }
    cp "$src" "$WORK/SPINRITE.EXE"
    sudo umount "$SPIN_DIR"; MOUNTED=""
    ;;
  *)
    cp "$SPINRITE_SRC" "$WORK/SPINRITE.EXE"
    ;;
esac
log "  SpinRite binary: $(stat -c%s "$WORK/SPINRITE.EXE") bytes"

RAW="$WORK/c.raw"
VBM clonemedium disk "$disk" "$RAW" --format RAW >/dev/null 2>&1 \
  || die "Could not clone $disk to RAW."

offset_sectors=$(fdisk -l "$RAW" 2>/dev/null | awk -v d="${RAW}1" '$1==d {print ($2=="*" ? $3 : $2); exit}')
[ -n "$offset_sectors" ] || offset_sectors=0   # superfloppy: FAT at sector 0
log "  FAT partition starts at sector $offset_sectors"

sudo mount -o loop,offset=$((offset_sectors * 512)),umask=000 "$RAW" "$WORK/c" \
  || die "Could not mount the guest C: filesystem."
MOUNTED="$WORK/c"

# The appliance ships a pre-release SpinRite that only nags. Remove it by
# whatever case FAT recorded, then write the licensed one in its place.
find "$WORK/c" -maxdepth 1 -iname 'spinrite.exe' -delete
cp "$WORK/SPINRITE.EXE" "$WORK/c/SPINRITE.EXE"

# ReadSpeed ships in READSPEE\ but AUTOEXEC.BAT sets PATH=\ -- so `rs` at the
# C:\> prompt only works if RS.EXE is also in the root. docs/workflow.md step 4
# assumes it is.
rs=$(find "$WORK/c" -iname 'rs.exe' | head -1)
if [ -n "$rs" ] && [ ! -f "$WORK/c/RS.EXE" ]; then
  cp "$rs" "$WORK/c/RS.EXE"
  log "  Copied RS.EXE to the root of C: (PATH is \\ only)"
fi

sync
sudo umount "$WORK/c"; MOUNTED=""

# --------------------------------------------------------------- write back

# Round-tripping through RAW also normalizes the streamOptimized VMDK the OVA
# ships into a plain read-write VDI, which is what docs/vm-build.md describes.
newdisk="$(dirname "$disk")/SRDOS-disk001.vdi"
[ -e "$newdisk" ] && newdisk="$(dirname "$disk")/${VM_NAME}-disk001.vdi"
log ""
log "Writing the modified disk back as $(basename "$newdisk") ..."
VBM convertfromraw "$RAW" "$newdisk" --format VDI >/dev/null 2>&1 \
  || die "Could not convert the modified disk back to VDI."

VBM storageattach "$VM_NAME" --storagectl PIIX4 --port 0 --device 0 --type hdd --medium none
VBM closemedium disk "$disk" >/dev/null 2>&1 || true
rm -f "$disk"
VBM storageattach "$VM_NAME" --storagectl PIIX4 --port 0 --device 0 --type hdd --medium "$newdisk"

VBM closemedium disk "$RAW" >/dev/null 2>&1 || true
rm -f "$RAW"
RAW=""

# ------------------------------------------------------------------- verify

log ""
log "Verifying ..."
VER="$WORK/verify.raw"
VBM clonemedium disk "$newdisk" "$VER" --format RAW >/dev/null 2>&1 \
  || die "Could not clone the finished disk back for verification."
sudo mount -o ro,loop,offset=$((offset_sectors * 512)) "$VER" "$WORK/c" \
  || { VBM closemedium disk "$VER" >/dev/null 2>&1 || true; die "Could not mount the finished disk for verification."; }
MOUNTED="$WORK/c"

ok=1
for f in SPINRITE.EXE RS.EXE; do
  found=$(find "$WORK/c" -maxdepth 1 -iname "$f" | head -1)
  if [ -n "$found" ]; then
    log "  OK C:\\$f ($(stat -c%s "$found") bytes)"
  else
    log "  MISSING C:\\$f"
    ok=0
  fi
done
sudo umount "$WORK/c"; MOUNTED=""
VBM closemedium disk "$VER" >/dev/null 2>&1 || true
rm -f "$VER"

[ "$ok" = 1 ] || die "Verification failed -- the VM exists but C: is not complete."

log ""
log "Done. VM '$VM_NAME' is ready."
log ""
log "  Boot it:            VBoxManage startvm $VM_NAME --type gui"
log "  Attach real disks:  ~/bin/spinrite-attach.sh list"
log ""
log "The appliance's bundled pre-release SpinRite was replaced with the copy you"
log "supplied. Three AHCI ports are free for physical disks."
