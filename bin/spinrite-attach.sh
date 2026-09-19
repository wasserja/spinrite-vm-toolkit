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

# Which VirtualBox storage controller the physical disks land on. AHCI is the
# default and is what every tracker row to date was measured against;
# `--controller ide` puts them on PIIX4 instead, where SpinRite's own ATA driver
# engages rather than the guest BIOS path. That is measurably faster at Level 3
# but changes what ReadSpeed reports, so a before/after pair is only comparable
# within one controller. See docs/field-notes.md.
AHCI_CONTROLLER="AHCI"
IDE_CONTROLLER="PIIX4"
CONTROLLER="$AHCI_CONTROLLER"

# PIIX4 port 0 device 0 carries the FreeDOS C: system disk. It is never offered
# as a slot and never detached -- without it the VM stops booting, and nothing
# reports that until the guest is sitting at a boot prompt.
SYSTEM_SLOT="PIIX4 0 0"

# Shortest token accepted as a serial substring. Device names are matched
# exactly, so this only bounds the fuzzy path -- a two-character typo must not
# be able to select a drive. Referenced by usage(), so it has to live up here.
MIN_SERIAL_LEN=4
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
  $SELF attach S0EXAMPLE000001   # ...or by serial substring
  $SELF attach --all --except sde
  $SELF attach --all --yes       # skip the typed confirmation
  $SELF attach sdb --controller ide   # ...on PIIX4/IDE rather than AHCI
  $SELF list --controller ide
  $SELF prune                    # unregister stale VirtualBox media entries
  $SELF prune --yes
  $SELF --help

Disks are named as 'list' prints them ("sdb", "/dev/sdb" and "nvme0n1" all
work), or by a substring of their SERIAL ($MIN_SERIAL_LEN+ characters,
case-insensitive, must match exactly one drive). Serials are what the tracker
records and they survive a reboot, so a batch list carries between sessions.
Every attached disk has its partitions unmounted and is handed raw to a DOS
utility that rewrites every sector at Level 3. The live boot USB is always
excluded from discovery.

--controller picks where they land: 'ahci' (default, 3 ports) or 'ide' (PIIX4,
3 usable slots -- port 0 device 0 holds the VM's own FreeDOS system disk and is
never touched). Either way an attach first clears BOTH controllers of any
physical disk left attached by a previous run, so the guest can never see the
same drive twice. ReadSpeed and SpinRite numbers are NOT comparable across
controllers -- see docs/field-notes.md.
EOF
}

usage_die() {
  printf 'ERROR: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

set_controller() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    ahci|sata)  CONTROLLER="$AHCI_CONTROLLER" ;;
    ide|piix4)  CONTROLLER="$IDE_CONTROLLER" ;;
    *) usage_die "unknown controller '$1' -- expected 'ahci' or 'ide'." ;;
  esac
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
  prune)     MODE="prune"; shift ;;
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
    --controller)
      [ $# -ge 2 ] || usage_die "--controller needs a value ('ahci' or 'ide')."
      set_controller "$2"; shift ;;
    --controller=*)
      set_controller "${1#*=}" ;;
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
    || usage_die "'list' takes no disk names -- it only ever prints. (--controller is accepted.)"
elif [ "$MODE" = "prune" ]; then
  [ "$WANT_ALL" = 0 ] && [ "${#NAMES[@]}" = 0 ] && [ "${#EXCEPTS[@]}" = 0 ] \
    || usage_die "'prune' takes no disk names -- it only ever touches the media registry. (--yes is accepted.)"
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

# ----------------------------------------------------------------- prune mode

# VirtualBox keeps a registry of every medium it has ever been handed. Raw-disk
# pointers for drives that are no longer plugged in, and clones left behind by
# `clonemedium`, stay in it forever as "inaccessible" entries. They are inert,
# but they accumulate -- and they make `VBoxManage list hdds` useless for
# spotting a real problem. Unregistering one never deletes its file: if the
# drive comes back, `attach` re-registers the same pointer.
if [ "$MODE" = "prune" ]; then
  if pgrep -f "VirtualBoxVM.*--startvm" >/dev/null 2>&1; then
    die "A VirtualBoxVM process is already running -- refusing to touch the media registry. Power the VM off first."
  fi

  # Media currently attached to any registered VM, by UUID. `list hdds` does
  # not reliably print an "In use by VMs" line (it does not on VirtualBox 7.x
  # for an attached VDI), so the authoritative source is each VM's own
  # attachment list.
  attached_uuids=$(
    VBM list vms 2>/dev/null | sed -n 's/.*{\(.*\)}.*/\1/p' | while read -r vmid; do
      VBM showvminfo "$vmid" --machinereadable 2>/dev/null \
        | sed -n 's/^"[^"]*ImageUUID[^"]*"="\([^"]*\)"$/\1/p'
    done | sort -u
  )

  # One record per medium: UUID, state, location.
  records=$(
    VBM list hdds 2>/dev/null | awk '
      function flush() { if (uuid != "") printf "%s\t%s\t%s\n", uuid, state, loc; uuid=""; state=""; loc="" }
      /^UUID:/     { flush(); uuid=$2; next }
      /^State:/    { state=$2; next }
      /^Location:/ { loc=$0; sub(/^Location:[ \t]*/, "", loc); next }
      END          { flush() }
    '
  )
  [ -n "$records" ] || { log "Media registry is empty -- nothing to prune."; exit 0; }

  gone=()      # registry entry whose backing file no longer exists
  absent=()    # pointer file still there, but its drive is not plugged in
  skipped=0
  while IFS=$'\t' read -r uuid state loc; do
    [ -n "$uuid" ] || continue
    [ "$state" = "inaccessible" ] || continue
    if [ -n "$attached_uuids" ] && printf '%s\n' "$attached_uuids" | grep -qxF "$uuid"; then
      skipped=$((skipped + 1))
      continue
    fi
    if [ -e "$loc" ]; then
      absent+=("$uuid|$loc")
    else
      gone+=("$uuid|$loc")
    fi
  done <<< "$records"

  total=$(( ${#gone[@]} + ${#absent[@]} ))
  if [ "$total" = 0 ]; then
    log "No stale media registry entries."
    [ "$skipped" -gt 0 ] && log "($skipped inaccessible entr(y/ies) skipped -- still attached to a VM.)"
    exit 0
  fi

  if [ "${#gone[@]}" -gt 0 ]; then
    log "Dangling entries -- the file they point at is gone (${#gone[@]}):"
    for rec in "${gone[@]}"; do log "  ${rec#*|}"; done
    log ""
  fi
  if [ "${#absent[@]}" -gt 0 ]; then
    log "Raw pointers whose drive is not plugged in right now (${#absent[@]}):"
    for rec in "${absent[@]}"; do log "  ${rec#*|}"; done
    log ""
    log "  These pointer FILES are kept. Unregistering only clears the registry entry;"
    log "  '$SELF attach' re-registers the pointer when that drive turns up again."
    log ""
  fi
  [ "$skipped" -gt 0 ] && log "$skipped inaccessible entr(y/ies) skipped -- still attached to a VM." && log ""

  log "About to unregister $total medium/media (closemedium, never --delete; no file is removed)."
  if [ "$ASSUME_YES" = 1 ]; then
    log "--yes given; skipping confirmation."
  else
    read -rp "Type 'yes' to continue: " confirm
    [ "$confirm" = "yes" ] || die "Aborted by user."
  fi

  closed=0
  failed=0
  for rec in ${gone[@]+"${gone[@]}"} ${absent[@]+"${absent[@]}"}; do
    uuid="${rec%%|*}"
    if VBM closemedium disk "$uuid" >/dev/null 2>&1; then
      closed=$((closed + 1))
    else
      log "WARNING: could not unregister $uuid (${rec#*|})"
      failed=$((failed + 1))
    fi
  done
  log ""
  if [ "$failed" -gt 0 ]; then
    log "Unregistered $closed medium/media, $failed failed."
  else
    log "Unregistered $closed medium/media."
  fi
  exit 0
fi

# ---------------------------------------------------------------- discovery

# Identify the boot USB so it is always excluded, regardless of its /dev letter
# this session.
boot_src=$(findmnt -no SOURCE /cdrom) || die "Could not determine boot device from /cdrom mount"
boot_disk=$(lsblk -no pkname "$boot_src" 2>/dev/null || true)
[ -n "$boot_disk" ] || boot_disk=$(basename "$boot_src" | sed -E 's/p?[0-9]+$//')

mapfile -t candidates < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vx "$boot_disk" || true)
[ "${#candidates[@]}" -gt 0 ] || die "No physical disks found besides the boot USB (/dev/$boot_disk)."

# Non-fatal counterpart to resolve_byid(): the by-id basename, or nothing.
byid_basename() {
  local dev="$1" real link best=""
  [ -d /dev/disk/by-id ] || return 0
  real=$(readlink -f "/dev/$dev") || return 0
  for link in /dev/disk/by-id/*; do
    [ -e "$link" ] || continue
    [[ "$link" == *-part* ]] && continue
    [ "$(readlink -f "$link")" = "$real" ] || continue
    case "$(basename "$link")" in
      nvme-*|ata-*|usb-*|scsi-*) best="$link"; break ;;
      *) [ -z "$best" ] && best="$link" ;;
    esac
  done
  [ -n "$best" ] && basename "$best"
}

# Everything a serial substring may match against: the drive's own SERIAL and
# its by-id basename, which encodes model+serial.
disk_identity() {
  printf '%s %s' "$(lsblk -dn -o SERIAL "/dev/$1" 2>/dev/null | tr -d ' ')" "$(byid_basename "$1")"
}

# Map one user-supplied token to exactly one discovered disk, into $RESOLVED.
#
# Device names (sdb, nvme0n1) are stable within a boot but not across boots or
# machines, while the tracker records serials -- so a batch list written down in
# one session cannot be replayed in the next. Accepting a serial substring here
# is what lets it be carried verbatim. An exact device name still wins outright,
# so nothing about the old interface changes.
RESOLVED=""
resolve_selector() {
  local token="$1" role="$2" dev matches=()
  if printf '%s\n' "${candidates[@]}" | grep -qxF -- "$token"; then
    RESOLVED="$token"
    return 0
  fi
  if [ "${#token}" -lt "$MIN_SERIAL_LEN" ]; then
    die "$role '$token': no disk of that name, and too short to use as a serial (need $MIN_SERIAL_LEN+ characters). Run '$SELF list'."
  fi
  for dev in "${candidates[@]}"; do
    if disk_identity "$dev" | grep -qiF -- "$token"; then
      matches+=("$dev")
    fi
  done
  case "${#matches[@]}" in
    1) RESOLVED="${matches[0]}" ;;
    0) die "$role '$token': not a disk name here, and no discovered drive's serial contains it (or it is the live boot USB). Run '$SELF list' to see names and serials." ;;
    *) die "$role '$token': ambiguous -- matches ${matches[*]/#//dev/}. Use a longer serial substring, or the device name." ;;
  esac
}

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

is_system_slot() { [ "$1 $2 $3" = "$SYSTEM_SLOT" ]; }

# Every slot on a controller that can carry a raw physical disk, one
# "<port> <device>" pair per line. AHCI addresses a disk by port with device
# always 0, and its width is the VM's configured portcount; PIIX4 is a fixed
# 2 ports x 2 devices, minus the system disk's slot. As the VM is built today
# both come to 3, so switching controllers costs nothing in drive count.
#
# How many slots exist is also how many disks one run can carry: every run
# detaches whatever was attached first, so there is no such thing as a slot left
# occupied by a prior run.
controller_slots() {
  local ctl="$1" info="$2" idx count p d
  idx=$(printf '%s\n' "$info" | awk -F'[="]' -v c="$ctl" \
    '$1 ~ /^storagecontrollername[0-9]+$/ && $3==c {sub(/^storagecontrollername/,"",$1); print $1; exit}')
  [ -n "$idx" ] || return 1
  count=$(printf '%s\n' "$info" | awk -F'"' -v k="storagecontrollerportcount$idx=" \
    'index($0,k)==1 {print $2; exit}')
  [ -n "$count" ] || return 1

  # IDE carries two devices per port (master/slave); AHCI is one per port.
  local devices="0"
  [ "$ctl" = "$IDE_CONTROLLER" ] && devices="0 1"

  for (( p=0; p<count; p++ )); do
    for d in $devices; do
      if ! is_system_slot "$ctl" "$p" "$d"; then
        printf '%s %s\n' "$p" "$d"
      fi
    done
  done
}

# ---------------------------------------------------------------- list mode

if [ "$MODE" = "list" ]; then
  log "Boot USB detected as /dev/$boot_disk -- always excluded."
  log ""
  log "Physical disks on this machine:"
  print_table
  log ""

  slots=()
  if vminfo=$(VBM showvminfo "$VM_NAME" --machinereadable 2>/dev/null); then
    mapfile -t slots < <(controller_slots "$CONTROLLER" "$vminfo" || true)
  fi
  if [ "${#slots[@]}" -gt 0 ]; then
    log "${#candidates[@]} disk(s) found, ${#slots[@]} usable $CONTROLLER slot(s) on $VM_NAME."
    if [ "${#candidates[@]}" -gt "${#slots[@]}" ]; then
      log "More disks than slots -- work them in batches, logging each batch in the"
      log "tracker as it finishes:  ~/bin/spinrite-track.py report"
    fi
  else
    log "${#candidates[@]} disk(s) found. ($VM_NAME's $CONTROLLER slots are unavailable"
    log "-- VM not found, controller absent, or VBoxManage unreadable; 'attach' will"
    log "report the real error.)"
  fi
  log ""
  log "  To attach all:      $SELF attach --all"
  log "  To attach a subset: $SELF attach ${candidates[0]}${candidates[1]+ ${candidates[1]}}"
  log "  ...or by serial:    $SELF attach $(disk_identity "${candidates[0]}" | awk '{print $1}')"
  log ""
  log "Serials come straight from the tracker (~/bin/spinrite-track.py report), so a"
  log "batch list noted in one session can be replayed verbatim in the next."
  exit 0
fi

# -------------------------------------------------------------- attach mode

# Safety check FIRST, before touching VBoxSVC at all: if a VM process is
# already alive, killing VBoxSVC crashes it. Check via `ps`, which needs no
# VBoxManage/VBoxSVC round-trip, so this is safe to do even if SVC is wedged.
if pgrep -f "VirtualBoxVM.*--startvm" >/dev/null 2>&1; then
  die "A VirtualBoxVM process is already running -- refusing to touch VBoxSVC or restart. Check 'ps aux | grep VirtualBoxVM' / the physical screen before rerunning this script."
fi

# Work out the selection before anything destructive happens. Tokens are
# resolved to device names first, so duplicate detection below compares the
# actual disks -- "attach sda <sda's serial>" is caught as naming one twice.
selected=()
if [ "$WANT_ALL" = 1 ]; then
  excluded=()
  for name in "${EXCEPTS[@]}"; do
    resolve_selector "$name" "--except"
    excluded+=("$RESOLVED")
  done
  for dev in "${candidates[@]}"; do
    if [ "${#excluded[@]}" -gt 0 ] && printf '%s\n' "${excluded[@]}" | grep -qxF -- "$dev"; then
      continue
    fi
    selected+=("$dev")
  done
  [ "${#selected[@]}" -gt 0 ] || die "--except excluded every discovered disk; nothing left to attach."
else
  for name in "${NAMES[@]}"; do
    resolve_selector "$name" "disk"
    printf '%s\n' "${selected[@]+"${selected[@]}"}" | grep -qxF -- "$RESOLVED" \
      && die "/dev/$RESOLVED selected twice (via '$name')."
    selected+=("$RESOLVED")
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

mapfile -t SLOTS < <(controller_slots "$CONTROLLER" "$vminfo" || true)
[ "${#SLOTS[@]}" -gt 0 ] \
  || die "VM '$VM_NAME' has no usable '$CONTROLLER' slots -- controller missing, or every slot is the system disk's."

# Capacity guard, before a single disk is attached. Attaching part of a set and
# then failing on the rest leaves a half-prepared VM and unmounted filesystems.
if [ "${#selected[@]}" -gt "${#SLOTS[@]}" ]; then
  batch=("${selected[@]:0:${#SLOTS[@]}}")
  cat >&2 <<EOF
ERROR: ${#selected[@]} disks selected, ${#SLOTS[@]} usable $CONTROLLER slot(s) on $VM_NAME.

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

log "About to attach ${#selected[@]} disk(s) to $VM_NAME on $CONTROLLER: ${selected[*]/#/\/dev\/}"
log "Each one gets its partitions unmounted and is handed raw to a DOS utility"
log "that rewrites every sector at Level 3."
log ""
if [ "$ASSUME_YES" = 1 ]; then
  log "--yes given; skipping confirmation."
else
  read -rp "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || die "Aborted by user."
fi

# Detach anything already sitting on EITHER controller before attaching the disks
# selected this run. Without this, a disk attached during a previous
# boot/session (e.g. on different physical hardware) would stay attached
# alongside the new one instead of being replaced -- a stale, no-longer-real
# disk showing up in the guest. Sweeping only the target controller is not
# enough: the same physical drive moved from AHCI to PIIX4, which is exactly
# what comparing the two controllers does, would otherwise remain attached in
# both places and enumerate twice in the guest, shifting SpinRite's BIOS drive
# numbering underneath a command written against the previous enumeration. The
# underlying .vmdk pointer files are left alone (harmless, and reused later if
# the same disk comes back).
detach_stale_media() {
  local info ctl p d line val
  info=$(VBM showvminfo "$VM_NAME" --machinereadable)
  for ctl in "$AHCI_CONTROLLER" "$IDE_CONTROLLER"; do
    while read -r p d; do
      [ -n "$p" ] || continue
      line=$(printf '%s\n' "$info" | grep "^\"$ctl-$p-$d\"=" || true)
      [ -n "$line" ] || continue
      val=$(printf '%s\n' "$line" | sed -E 's/^[^=]+="?//; s/"$//')
      if [ -n "$val" ] && [ "$val" != "none" ]; then
        log "Detaching stale medium from $ctl port $p device $d: $val"
        VBM storageattach "$VM_NAME" --storagectl "$ctl" --port "$p" --device "$d" --type hdd --medium none
      fi
    done < <(controller_slots "$ctl" "$info" || true)
  done
}
detach_stale_media

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

next_free_slot() {
  local info slot p d line
  info=$(VBM showvminfo "$VM_NAME" --machinereadable)
  for slot in "${SLOTS[@]}"; do
    read -r p d <<< "$slot"
    line=$(printf '%s\n' "$info" | grep "^\"$CONTROLLER-$p-$d\"=" || true)
    if [ -z "$line" ] || printf '%s\n' "$line" | grep -q '"none"'; then
      printf '%s %s\n' "$p" "$d"
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

  slot=$(next_free_slot) || die "No free $CONTROLLER slots left on $VM_NAME"
  read -r port device <<< "$slot"
  log "Attaching $vmdk to $CONTROLLER port $port device $device"
  VBM storageattach "$VM_NAME" --storagectl "$CONTROLLER" --port "$port" --device "$device" --type hdd --medium "$vmdk"
done

log ""
log "Starting $VM_NAME in GUI mode..."
VBM startvm "$VM_NAME" --type gui
