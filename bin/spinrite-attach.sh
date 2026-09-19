#!/usr/bin/env bash
# Discover physical disks (excluding the live boot USB), attach them to the
# SpinRite FreeDOS VM via stable raw VMDK pointers, and start the VM.
#
# Usage: spinrite-attach.sh [sdX ...]
#   Any device names given as arguments (bare, e.g. "sde") are excluded from
#   discovery in addition to the boot USB -- e.g. to skip an external drive
#   when more disks are present than free AHCI ports.
set -euo pipefail

VM_NAME="SRDOS"
VM_DIR="$HOME/VirtualBox VMs"
CONTROLLER="AHCI"
EXTRA_EXCLUDE=("$@")

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VBM() {
  # Always run VBoxManage via a fresh login-equivalent context for the target
  # user. `sg <group>` only grants a new group to its direct child -- the
  # actual VBoxSVC backing process ends up with stale credentials from
  # whatever session first spawned it, so every call (not just the "raw
  # device" ones) goes through this to keep VBoxSVC's permissions consistent
  # for the whole run.
  sudo -iu "$(id -un)" -- VBoxManage "$@"
}

command -v VBoxManage >/dev/null || die "VBoxManage not found"

# 0. Safety check FIRST, before touching VBoxSVC at all: if a VM process is
# already alive, killing VBoxSVC crashes it (confirmed 2026-08-18 -- VBoxSVC
# going unresponsive mid-session makes the GUI force a power-off). Check via
# `ps`, which needs no VBoxManage/VBoxSVC round-trip, so this is safe to do
# even if SVC is currently wedged.
if pgrep -f "VirtualBoxVM.*--startvm" >/dev/null 2>&1; then
  die "A VirtualBoxVM process is already running -- refusing to touch VBoxSVC or restart. Check 'ps aux | grep VirtualBoxVM' / the physical screen before rerunning this script."
fi

# Kill any already-running VBoxSVC that may have been started under stale
# (pre-group-change) credentials, so it gets respawned cleanly below. Safe
# here only because we've just confirmed no VM process is running.
pkill -f VBoxSVC 2>/dev/null || true
sleep 1

# 1. VM must exist and not be running. "aborted" (e.g. after a crash) is
# just as safe to start from as "poweroff" -- both mean no live session.
vminfo=$(VBM showvminfo "$VM_NAME" --machinereadable 2>&1) \
  || die "VM '$VM_NAME' not found:
$vminfo"
state=$(printf '%s\n' "$vminfo" | grep -m1 '^VMState=' | cut -d'"' -f2)
case "$state" in
  poweroff|aborted) ;;
  *) die "VM '$VM_NAME' is not powered off (state: $state). Power it off first." ;;
esac

# 2. Identify the boot USB so it's always excluded, regardless of its /dev letter this session
boot_src=$(findmnt -no SOURCE /cdrom) || die "Could not determine boot device from /cdrom mount"
boot_disk=$(lsblk -no pkname "$boot_src" 2>/dev/null || true)
[ -n "$boot_disk" ] || boot_disk=$(basename "$boot_src" | sed -E 's/p?[0-9]+$//')
log "Boot USB detected as /dev/$boot_disk -- excluded from discovery."
if [ "${#EXTRA_EXCLUDE[@]}" -gt 0 ]; then
  log "Also excluding by request: ${EXTRA_EXCLUDE[*]/#/\/dev\/}"
fi

# 3. Discover other physical disks
mapfile -t candidates < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vx "$boot_disk" || true)
if [ "${#EXTRA_EXCLUDE[@]}" -gt 0 ]; then
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | grep -vxF -f <(printf '%s\n' "${EXTRA_EXCLUDE[@]}") || true)
fi
[ "${#candidates[@]}" -gt 0 ] || die "No physical disks found besides the boot USB (/dev/$boot_disk) and any excluded devices."

log ""
log "Discovered candidate physical disks:"
printf '  %-10s %-8s %-24s %-20s %s\n' "DEVICE" "SIZE" "MODEL" "SERIAL" "MOUNTED PARTITIONS"
for dev in "${candidates[@]}"; do
  size=$(lsblk -dn -o SIZE "/dev/$dev")
  model=$(lsblk -dn -o MODEL "/dev/$dev")
  serial=$(lsblk -dn -o SERIAL "/dev/$dev")
  mounted=$(lsblk -no MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -v '^$' | tr '\n' ',' | sed 's/,$//') || true
  printf '  /dev/%-5s %-8s %-24s %-20s %s\n' "$dev" "$size" "${model:-?}" "${serial:-?}" "${mounted:-<none>}"
done
log ""

# Defensive: warn about any existing pointer file that resolves to the boot disk itself
shopt -s nullglob
boot_real=$(readlink -f "/dev/$boot_disk")
for f in "$VM_DIR"/*.vmdk; do
  desc=$(cat "$f" 2>/dev/null) || continue
  path=$(printf '%s\n' "$desc" | grep -oP '(?<=FLAT ")[^"]+' | head -1) || true
  [ -n "$path" ] || continue
  resolved=$(readlink -f "$path" 2>/dev/null || true)
  if [ "$resolved" = "$boot_real" ]; then
    log "WARNING: $f points at the current boot USB ($path) -- it will NOT be used, but consider removing it."
  fi
done

read -rp "Attach ALL of the above disks to $VM_NAME and start SpinRite? Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || die "Aborted by user."

# Detach anything already sitting on the AHCI controller before attaching the
# disks discovered this run. Without this, a disk attached during a previous
# boot/session (e.g. on different physical hardware) would stay attached
# alongside the new one instead of being replaced -- a stale, no-longer-real
# disk showing up in the guest. The underlying .vmdk pointer files are left
# alone (harmless, and reused later if the same disk comes back).
detach_all_ahci_disks() {
  local info p line val
  info=$(VBM showvminfo "$VM_NAME" --machinereadable)
  for p in $(seq 0 29); do
    line=$(printf '%s\n' "$info" | grep "^\"$CONTROLLER-$p-0\"=" || true)
    [ -n "$line" ] || continue
    val=$(printf '%s\n' "$line" | sed -E 's/^[^=]+="?//; s/"$//')
    if [ -n "$val" ] && [ "$val" != "none" ]; then
      log "Detaching stale medium from $CONTROLLER port $p: $val"
      VBM storageattach "$VM_NAME" --storagectl "$CONTROLLER" --port "$p" --device 0 --type hdd --medium none
    fi
  done
}
detach_all_ahci_disks

resolve_byid() {
  local dev="$1" real link best=""
  real=$(readlink -f "/dev/$dev")
  for link in /dev/disk/by-id/*; do
    [[ "$link" == *-part* ]] && continue
    [ "$(readlink -f "$link")" = "$real" ] || continue
    case "$(basename "$link")" in
      nvme-*|ata-*|usb-*|scsi-*) best="$link"; break ;;
      *) [ -z "$best" ] && best="$link" ;;
    esac
  done
  [ -n "$best" ] || die "No stable /dev/disk/by-id path found for /dev/$dev"
  printf '%s\n' "$best"
}

next_free_port() {
  local info p line
  info=$(VBM showvminfo "$VM_NAME" --machinereadable)
  for p in $(seq 0 29); do
    line=$(printf '%s\n' "$info" | grep "^\"$CONTROLLER-$p-0\"=" || true)
    if [ -z "$line" ] || printf '%s\n' "$line" | grep -q '"none"'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

for dev in "${candidates[@]}"; do
  log ""
  log "== /dev/$dev =="

  while read -r part_mnt; do
    [ -n "$part_mnt" ] || continue
    log "Unmounting $part_mnt ..."
    sudo umount "$part_mnt"
  done < <(lsblk -no MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -v '^$' || true)

  byid=$(resolve_byid "$dev")
  vmdk="$VM_DIR/$(basename "$byid").vmdk"

  # Reuse-by-filename is keyed on the by-id path's basename, which encodes
  # the drive's model/serial -- unlike the vmdk's internal FLAT path (always
  # a resolved /dev/nvmeX or /dev/sdX node, since VBoxManage resolves
  # symlinks when writing the descriptor), this is stable across boots and
  # across different physical machines. Still, VMDK raw-disk descriptors
  # bake in the extent size at creation time and never refresh it, so a
  # same-serial pointer whose live size has since changed would silently
  # misreport -- verify size on reuse and recreate if it drifted.
  if [ -f "$vmdk" ]; then
    live_bytes=$(sudo blockdev --getsize64 "/dev/$dev")
    desc_sectors=$(grep -oP '(?<=^RW )\d+' "$vmdk" | head -1)
    desc_bytes=$(( ${desc_sectors:-0} * 512 ))
    if [ "$desc_bytes" = "$live_bytes" ]; then
      log "Reusing existing pointer: $vmdk"
    else
      log "Existing pointer $vmdk is stale ($desc_bytes bytes vs live $live_bytes) -- recreating."
      VBM closemedium disk "$vmdk" 2>/dev/null || true
      rm -f "$vmdk"
    fi
  fi
  if [ ! -f "$vmdk" ]; then
    log "Creating raw VMDK pointer: $vmdk -> $byid"
    VBM createmedium disk --filename "$vmdk" --format=VMDK --variant RawDisk --property "RawDrive=$byid"
  fi

  port=$(next_free_port) || die "No free $CONTROLLER ports left on $VM_NAME"
  log "Attaching $vmdk to $CONTROLLER port $port"
  VBM storageattach "$VM_NAME" --storagectl "$CONTROLLER" --port "$port" --device 0 --type hdd --medium "$vmdk"
done

log ""
log "Starting $VM_NAME in GUI mode..."
VBM startvm "$VM_NAME" --type gui
