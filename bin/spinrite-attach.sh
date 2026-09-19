#!/usr/bin/env bash
# Discover this machine's physical disks (never the live boot USB), attach the
# ones you name to the SpinRite FreeDOS VM via stable raw VMDK pointers, and
# start the VM.
#
# Listing is the default and is read-only. Nothing is unmounted, attached or
# started without the word "attach" on the command line.
set -euo pipefail

VM_NAME="SRDOS"
VM_DIR="$HOME/VirtualBox VMs"
CONTROLLER="AHCI"
SELF="$(basename "$0")"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SELF                          # same as 'list'
  $SELF list                     # discover + print table, attach nothing
  $SELF attach --all             # attach every discovered disk
  $SELF attach sdb sdc           # attach ONLY these
  $SELF attach --all --except sde
  $SELF attach --all --yes       # skip the typed confirmation
  $SELF --help

Disk names are as printed by 'list' ("sdb", "/dev/sdb" and "nvme0n1" all work).
Every attached disk has its partitions unmounted and is handed raw to a DOS
utility that rewrites every sector at Level 3. The live boot USB is always
excluded from discovery.
EOF
}

usage_die() {
  printf 'ERROR: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

# ---------------------------------------------------------------- arguments

MODE="list"
WANT_ALL=0
ASSUME_YES=0
NAMES=()
EXCEPTS=()

normalize() { printf '%s\n' "${1#/dev/}" | sed 's:/*$::'; }

case "${1-}" in
  ""|list)   MODE="list"; [ $# -gt 0 ] && shift ;;
  attach)    MODE="attach"; shift ;;
  -h|--help) usage; exit 0 ;;
  -*)        usage_die "unknown option: $1" ;;
  *)
    # The old interface took bare disk names and treated them as EXCLUSIONS.
    # Under this one the same words mean "attach only these" -- the exact
    # inverse, i.e. precisely the drives someone was trying to protect. Never
    # guess which was meant.
    cat >&2 <<EOF
ERROR: disk names must follow a verb -- bare names used to mean "exclude",
they now mean "attach only". Refusing to guess which you meant.

  To attach everything except those:  $SELF attach --all --except $*
  To attach only those:               $SELF attach $*
  To just look:                       $SELF list
EOF
    exit 2
    ;;
esac

collect="names"
while [ $# -gt 0 ]; do
  case "$1" in
    --all)     WANT_ALL=1; collect="names" ;;
    --except)  collect="excepts" ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage_die "unknown option: $1" ;;
    *)
      if [ "$collect" = "excepts" ]; then
        EXCEPTS+=("$(normalize "$1")")
      else
        NAMES+=("$(normalize "$1")")
      fi
      ;;
  esac
  shift
done

if [ "$MODE" = "list" ]; then
  [ "$WANT_ALL" = 0 ] && [ "${#NAMES[@]}" = 0 ] && [ "${#EXCEPTS[@]}" = 0 ] \
    || usage_die "'list' takes no disk names or flags -- it only ever prints."
else
  [ "${#EXCEPTS[@]}" = 0 ] || [ "$WANT_ALL" = 1 ] \
    || usage_die "--except is only valid with --all (did you mean: attach --all --except ${EXCEPTS[*]}?)."
  [ "$WANT_ALL" = 1 ] || [ "${#NAMES[@]}" -gt 0 ] \
    || usage_die "nothing selected -- name the disks to attach, or pass --all."
  [ "$WANT_ALL" = 0 ] || [ "${#NAMES[@]}" = 0 ] \
    || usage_die "--all cannot be combined with an explicit disk list (${NAMES[*]})."
fi

command -v VBoxManage >/dev/null || die "VBoxManage not found"

VBM() {
  # Always run VBoxManage via a fresh login-equivalent context for the target
  # user. `sg <group>` only grants a new group to its direct child -- the
  # actual VBoxSVC backing process ends up with stale credentials from
  # whatever session first spawned it, so every call (not just the "raw
  # device" ones) goes through this to keep VBoxSVC's permissions consistent
  # for the whole run.
  sudo -iu "$(id -un)" -- VBoxManage "$@"
}

# ---------------------------------------------------------------- discovery

# Identify the boot USB so it is always excluded, regardless of its /dev letter
# this session.
boot_src=$(findmnt -no SOURCE /cdrom) || die "Could not determine boot device from /cdrom mount"
boot_disk=$(lsblk -no pkname "$boot_src" 2>/dev/null || true)
[ -n "$boot_disk" ] || boot_disk=$(basename "$boot_src" | sed -E 's/p?[0-9]+$//')

mapfile -t candidates < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vx "$boot_disk" || true)
[ "${#candidates[@]}" -gt 0 ] || die "No physical disks found besides the boot USB (/dev/$boot_disk)."

print_table() {
  local dev size model serial mounted mark
  printf '  %-2s %-10s %-8s %-24s %-20s %s\n' "" "DEVICE" "SIZE" "MODEL" "SERIAL" "MOUNTED PARTITIONS"
  for dev in "${candidates[@]}"; do
    size=$(lsblk -dn -o SIZE "/dev/$dev")
    model=$(lsblk -dn -o MODEL "/dev/$dev")
    serial=$(lsblk -dn -o SERIAL "/dev/$dev")
    mounted=$(lsblk -no MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -v '^$' | tr '\n' ',' | sed 's/,$//') || true
    mark=" "
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@" | grep -qxF "$dev" && mark="*"
    fi
    printf '  %-2s /dev/%-5s %-8s %-24.24s %-20.20s %s\n' \
      "$mark" "$dev" "$size" "${model:-?}" "${serial:-?}" "${mounted:-<none>}"
  done
}

# AHCI port count caps how many raw disks one run can carry. Every run detaches
# whatever is on the controller first, so the full port count is what is
# available -- there is no such thing as a port left occupied by a prior run.
ahci_port_count() {
  local info idx
  info="$1"
  idx=$(printf '%s\n' "$info" | awk -F'[="]' -v c="$CONTROLLER" \
    '$1 ~ /^storagecontrollername[0-9]+$/ && $3==c {sub(/^storagecontrollername/,"",$1); print $1; exit}')
  [ -n "$idx" ] || return 1
  printf '%s\n' "$info" | awk -F'"' -v k="storagecontrollerportcount$idx=" \
    'index($0,k)==1 {print $2; exit}'
}

# ---------------------------------------------------------------- list mode

if [ "$MODE" = "list" ]; then
  log "Boot USB detected as /dev/$boot_disk -- always excluded."
  log ""
  log "Physical disks on this machine:"
  print_table
  log ""

  ports=""
  if vminfo=$(VBM showvminfo "$VM_NAME" --machinereadable 2>/dev/null); then
    ports=$(ahci_port_count "$vminfo" || true)
  fi
  if [ -n "$ports" ]; then
    log "${#candidates[@]} disk(s) found, $ports $CONTROLLER port(s) on $VM_NAME."
    if [ "${#candidates[@]}" -gt "$ports" ]; then
      log "More disks than ports -- work them in batches, logging each batch in the"
      log "tracker as it finishes:  ~/bin/spinrite-track.py report"
    fi
  else
    log "${#candidates[@]} disk(s) found. ($VM_NAME port count unavailable -- VM not"
    log "found or VBoxManage unreadable; 'attach' will report the real error.)"
  fi
  log ""
  log "  To attach all:      $SELF attach --all"
  log "  To attach a subset: $SELF attach ${candidates[0]}${candidates[1]+ ${candidates[1]}}"
  exit 0
fi

# -------------------------------------------------------------- attach mode

# Safety check FIRST, before touching VBoxSVC at all: if a VM process is
# already alive, killing VBoxSVC crashes it. Check via `ps`, which needs no
# VBoxManage/VBoxSVC round-trip, so this is safe to do even if SVC is wedged.
if pgrep -f "VirtualBoxVM.*--startvm" >/dev/null 2>&1; then
  die "A VirtualBoxVM process is already running -- refusing to touch VBoxSVC or restart. Check 'ps aux | grep VirtualBoxVM' / the physical screen before rerunning this script."
fi

# Work out the selection before anything destructive happens.
in_candidates() { printf '%s\n' "${candidates[@]}" | grep -qxF "$1"; }

selected=()
if [ "$WANT_ALL" = 1 ]; then
  for name in "${EXCEPTS[@]}"; do
    in_candidates "$name" || die "--except /dev/$name: not among the discovered disks. Run '$SELF list' to see them."
  done
  for dev in "${candidates[@]}"; do
    if [ "${#EXCEPTS[@]}" -gt 0 ] && printf '%s\n' "${EXCEPTS[@]}" | grep -qxF "$dev"; then
      continue
    fi
    selected+=("$dev")
  done
  [ "${#selected[@]}" -gt 0 ] || die "--except excluded every discovered disk; nothing left to attach."
else
  for name in "${NAMES[@]}"; do
    in_candidates "$name" \
      || die "/dev/$name: not among the discovered disks (or it is the live boot USB). Run '$SELF list' to see them."
    printf '%s\n' "${selected[@]+"${selected[@]}"}" | grep -qxF "$name" \
      && die "/dev/$name named twice."
    selected+=("$name")
  done
fi

# Kill any already-running VBoxSVC that may have been started under stale
# (pre-group-change) credentials, so it gets respawned cleanly below. Safe
# here only because we've just confirmed no VM process is running.
pkill -f VBoxSVC 2>/dev/null || true
sleep 1

# VM must exist and not be running. "aborted" (e.g. after a crash) is just as
# safe to start from as "poweroff" -- both mean no live session.
vminfo=$(VBM showvminfo "$VM_NAME" --machinereadable 2>&1) \
  || die "VM '$VM_NAME' not found:
$vminfo"
state=$(printf '%s\n' "$vminfo" | grep -m1 '^VMState=' | cut -d'"' -f2)
case "$state" in
  poweroff|aborted) ;;
  *) die "VM '$VM_NAME' is not powered off (state: $state). Power it off first." ;;
esac

port_count=$(ahci_port_count "$vminfo") \
  || die "VM '$VM_NAME' has no '$CONTROLLER' storage controller."

# Capacity guard, before a single disk is attached. Attaching part of a set and
# then failing on the rest leaves a half-prepared VM and unmounted filesystems.
if [ "${#selected[@]}" -gt "$port_count" ]; then
  batch=("${selected[@]:0:$port_count}")
  cat >&2 <<EOF
ERROR: ${#selected[@]} disks selected, $port_count $CONTROLLER port(s) on $VM_NAME.

  Run in batches -- attach the first set, complete it, then re-run with the rest:
    $SELF attach ${batch[*]}

  Already-completed drives are in the tracker: ~/bin/spinrite-track.py report
EOF
  exit 1
fi

log "Boot USB detected as /dev/$boot_disk -- always excluded."
log ""
log "Physical disks on this machine (* = selected for attachment):"
print_table "${selected[@]}"
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

log "About to attach ${#selected[@]} disk(s) to $VM_NAME: ${selected[*]/#/\/dev\/}"
log "Each one gets its partitions unmounted and is handed raw to a DOS utility"
log "that rewrites every sector at Level 3."
log ""
if [ "$ASSUME_YES" = 1 ]; then
  log "--yes given; skipping confirmation."
else
  read -rp "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || die "Aborted by user."
fi

# Detach anything already sitting on the AHCI controller before attaching the
# disks selected this run. Without this, a disk attached during a previous
# boot/session (e.g. on different physical hardware) would stay attached
# alongside the new one instead of being replaced -- a stale, no-longer-real
# disk showing up in the guest. The underlying .vmdk pointer files are left
# alone (harmless, and reused later if the same disk comes back).
detach_all_ahci_disks() {
  local info p line val
  info=$(VBM showvminfo "$VM_NAME" --machinereadable)
  for (( p=0; p<port_count; p++ )); do
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
  for (( p=0; p<port_count; p++ )); do
    line=$(printf '%s\n' "$info" | grep "^\"$CONTROLLER-$p-0\"=" || true)
    if [ -z "$line" ] || printf '%s\n' "$line" | grep -q '"none"'; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

for dev in "${selected[@]}"; do
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
