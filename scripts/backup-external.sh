#!/usr/bin/env bash
# =============================================================================
# Copy everything to the external HDD (label HOMELAB-BACKUP, ext4)
#
#   sudo /srv/docker/stacks/scripts/backup-external.sh          asks before mass deletions
#   sudo /srv/docker/stacks/scripts/backup-external.sh --yes    no questions
#
# The disk ends up self-contained:
#   data/          rsync mirror of /srv/data: bulk data + data/backups/nvme
#                  (configs, DB dumps, secrets — see scripts/backup.sh)
#   RESTORE.md     how to get everything back
#   LAST-COPY      when this disk was last written
#
# A mirror has no history: a file deleted on the server is deleted here too.
# Not encrypted: anyone holding the disk can read everything, secrets included.
# =============================================================================
set -euo pipefail

LABEL=HOMELAB-BACKUP
MNT=/mnt/homelab-backup
SRC=/srv/data/
STACKS=$(cd "$(dirname "$0")/.." && pwd)
MAX_DELETES=1000   # ask before deleting more files than this

log() { echo "[external] $*"; }
die() { echo "[external] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
YES=false; [ "${1:-}" = --yes ] && YES=true

# A missing /srv/data with --delete would empty the disk: refuse
mountpoint -q /srv/data || die "/srv/data is not mounted"
[ -f /srv/data/backups/nvme/LAST-BACKUP ] || die "no NVMe backup yet: run scripts/backup.sh first"

DEV=$(blkid -L "$LABEL" 2>/dev/null) || die "no disk labelled $LABEL (see playbook 04: prepare the disk)"
FSTYPE=$(blkid -s TYPE -o value "$DEV")
[ "$FSTYPE" = ext4 ] || die "$DEV is $FSTYPE, expected ext4"

# Same lock as backup.sh, so the NVMe backup is copied at rest and the
# 22:00 shutdown waits for this copy to finish
exec 9>/run/homelab-backup.lock
flock -n 9 || die "a backup is running, try again later"

mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  mount "$DEV" "$MNT"
  trap 'sync; umount "$MNT" && log "disk unmounted, safe to unplug"' EXIT
fi
mkdir -p "$MNT/data"

RSYNC=(rsync -aH --numeric-ids --delete)

deletes=$("${RSYNC[@]}" --dry-run --itemize-changes "$SRC" "$MNT/data/" | grep -c '^\*deleting' || true)
log "$deletes file(s) would be deleted from the disk"
if [ "$deletes" -gt "$MAX_DELETES" ] && ! $YES; then
  read -rp "[external] more than $MAX_DELETES deletions - continue? [y/N] " a
  [ "$a" = y ] || die "aborted, nothing copied"
fi

log "mirroring $SRC -> $MNT/data/ (first run takes hours)"
"${RSYNC[@]}" --info=progress2,stats1 "$SRC" "$MNT/data/"

cp "$STACKS/docs/restore-from-hdd.md" "$MNT/RESTORE.md"
date -Is > "$MNT/LAST-COPY"
log "done: NVMe backup from $(cat "$MNT/data/backups/nvme/LAST-BACKUP"), copied $(cat "$MNT/LAST-COPY")"
