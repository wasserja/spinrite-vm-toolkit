#!/usr/bin/env bash
# Archive the SpinRite attach/backup scripts + SRDOS VM definition + FreeDOS
# C: disk (which holds SpinRite/ReadSpeed and every RS0NN.TXT results log) +
# Claude Code custom skills + memory into a single timestamped tarball under
# ~/spinrite-backups/, ready to drag into OneDrive (or any other cloud
# storage) via the browser.
set -euo pipefail

VM_NAME="SRDOS"
VM_DIR="$HOME/VirtualBox VMs/$VM_NAME"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/-home-kubuntu/memory"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
OUT_DIR="$HOME/spinrite-backups"
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$OUT_DIR/spinrite-backup-$TS.tar.gz"

TRACKER_CSV="$HOME/spinrite-tracker.csv"

for f in "$HOME/bin/spinrite-attach.sh" \
         "$HOME/bin/spinrite-backup.sh" \
         "$HOME/bin/spinrite-track.py" \
         "$HOME/Desktop/spinrite-attach.desktop" \
         "$VM_DIR/SRDOS.vbox" \
         "$VM_DIR/SRDOS-disk001.vdi" \
         "$CLAUDE_SETTINGS" \
         "$TRACKER_CSV"; do
  [ -f "$f" ] || { printf 'ERROR: expected file missing: %s\n' "$f" >&2; exit 1; }
done
for d in "$CLAUDE_SKILLS_DIR" "$CLAUDE_MEMORY_DIR"; do
  [ -d "$d" ] || { printf 'ERROR: expected directory missing: %s\n' "$d" >&2; exit 1; }
done

if command -v VBoxManage >/dev/null && VBoxManage list runningvms 2>/dev/null | grep -q "\"$VM_NAME\""; then
  printf 'NOTE: %s is currently running -- this is just a read-only file copy\n' "$VM_NAME" >&2
  printf '(does not touch VBoxSVC or the VM process), but SRDOS-disk001.vdi\n' >&2
  printf 'could be mid-write and slightly inconsistent. For a guaranteed-clean\n' >&2
  printf 'snapshot, re-run this after powering the VM off. Proceeding anyway.\n' >&2
fi

mkdir -p "$OUT_DIR"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/bin" "$STAGE/Desktop" "$STAGE/SRDOS" "$STAGE/claude-settings"
[ -f "$HOME/bin/spinrite-vm-build.sh" ] && cp "$HOME/bin/spinrite-vm-build.sh" "$STAGE/bin/"
cp "$HOME/bin/spinrite-attach.sh" "$STAGE/bin/"
cp "$HOME/bin/spinrite-backup.sh" "$STAGE/bin/"
cp "$HOME/bin/spinrite-track.py" "$STAGE/bin/"
cp "$HOME/Desktop/spinrite-attach.desktop" "$STAGE/Desktop/"
cp "$VM_DIR/SRDOS.vbox" "$STAGE/SRDOS/"
cp "$VM_DIR/SRDOS-disk001.vdi" "$STAGE/SRDOS/"
cp "$CLAUDE_SETTINGS" "$STAGE/claude-settings/settings.json"
cp "$TRACKER_CSV" "$STAGE/spinrite-tracker.csv"
# Whole directories, copied recursively (not enumerated file-by-file) since
# skills/memories accumulate over time.
cp -r "$CLAUDE_SKILLS_DIR" "$STAGE/claude-skills"
cp -r "$CLAUDE_MEMORY_DIR" "$STAGE/claude-memory"

cat > "$STAGE/README.txt" <<EOF
SpinRite live-USB backup -- $TS

Restore mapping (copy each into place on the new/rebuilt USB):
  bin/spinrite-vm-build.sh        -> ~/bin/spinrite-vm-build.sh  (if present)
  bin/spinrite-attach.sh          -> ~/bin/spinrite-attach.sh
  bin/spinrite-backup.sh          -> ~/bin/spinrite-backup.sh
  bin/spinrite-track.py           -> ~/bin/spinrite-track.py
  Desktop/spinrite-attach.desktop -> ~/Desktop/spinrite-attach.desktop
  SRDOS/SRDOS.vbox                -> ~/VirtualBox VMs/SRDOS/SRDOS.vbox
  SRDOS/SRDOS-disk001.vdi         -> ~/VirtualBox VMs/SRDOS/SRDOS-disk001.vdi
  claude-settings/settings.json   -> ~/.claude/settings.json
  claude-skills/*                 -> ~/.claude/skills/
  claude-memory/*                 -> ~/.claude/projects/-home-kubuntu/memory/
  spinrite-tracker.csv            -> ~/spinrite-tracker.csv

Notes:
- After restoring SRDOS.vbox + SRDOS-disk001.vdi, register the VM with:
    VBoxManage registervm "\$HOME/VirtualBox VMs/SRDOS/SRDOS.vbox"
- Raw physical-disk .vmdk pointers are NOT included on purpose -- they are
  machine/session-specific and spinrite-attach.sh recreates them fresh
  each run for whatever disk is actually present.
- chmod +x the scripts under bin/ after restoring.
- Host group membership is NOT captured here (/etc/group lives outside this
  archive). On a freshly built stick you must re-add the user to the groups
  VirtualBox needs, then log out and back in (a reboot is simplest):
    sudo usermod -aG disk "\$USER"        # raw physical-disk passthrough
    sudo usermod -aG vboxusers "\$USER"   # USB passthrough to the guest
  'disk' is the one that matters: without it, storageattach/startvm fail with
  the raw medium showing State: inaccessible / Capacity: 0 MBytes -- which does
  not look like a permissions problem. Verify with: id; test -r /dev/sda
- Secure Boot MOK enrollment is per-machine firmware state and is likewise not
  in this archive. If 'modprobe vboxdrv' fails with "Key was rejected by
  service" on a machine, enroll the DKMS key there (mokutil) and reboot.
EOF

tar -czf "$ARCHIVE" -C "$STAGE" bin Desktop SRDOS claude-skills claude-memory claude-settings spinrite-tracker.csv README.txt

printf 'Backup written to: %s\n' "$ARCHIVE"
printf 'Size: %s\n' "$(du -h "$ARCHIVE" | cut -f1)"
printf 'Contains: bin/, Desktop/, SRDOS/, claude-skills/, claude-memory/,\n'
printf '          claude-settings/, spinrite-tracker.csv, README.txt (restore mapping)\n'
printf 'Next step: open OneDrive in your browser and drag this file in.\n'
