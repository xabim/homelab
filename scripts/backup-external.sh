#!/usr/bin/env bash
# =============================================================================
# Copy everything to the external HDD (label HOMELAB-BACKUP, ext4)
#
#   sudo scripts/backup-external.sh          mirror, asks before mass deletions
#   sudo scripts/backup-external.sh --yes    no questions
#
# The disk ends up self-contained:
#   data/          rsync mirror of /srv/data (bulk data + the nightly restic
#                  repository in data/backups/restic: configs, DB dumps, secrets)
#   restic         static binary to read that repository on any Linux box
#   restic.pass    the repository password
#   RESTORE.md     how to get everything back
#
# A mirror has no history: a file deleted on the server is deleted here too.
# =============================================================================
set -euo pipefail

LABEL=HOMELAB-BACKUP
MNT=/mnt/homelab-backup
SRC=/srv/data/
STACKS=$(cd "$(dirname "$0")/.." && pwd)
MAX_DELETES=1000   # ask before deleting more files than this

log() { echo "[external] $*"; }
die() { echo "[external] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
YES=false; [ "${1:-}" = --yes ] && YES=true

# A missing /srv/data with --delete would empty the disk: refuse
mountpoint -q /srv/data || die "/srv/data is not mounted"
[ -d /srv/data/backups/restic ] || die "no restic repository under /srv/data/backups"

DEV=$(blkid -L "$LABEL" 2>/dev/null) || die "no disk labelled $LABEL (see playbook 04: prepare the disk)"
FSTYPE=$(blkid -s TYPE -o value "$DEV")
[ "$FSTYPE" = ext4 ] || die "$DEV is $FSTYPE, expected ext4"

# Same lock as the nightly job, so the restic repository is copied at rest
exec 9>/run/homelab-backup.lock
flock -n 9 || die "a backup is running, try again later"

mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  mount "$DEV" "$MNT"
  trap 'sync; umount "$MNT" && log "disk unmounted, safe to unplug"' EXIT
fi
mkdir -p "$MNT/data"

RSYNC=(rsync -aHAX --numeric-ids --delete)

deletes=$("${RSYNC[@]}" --dry-run --itemize-changes "$SRC" "$MNT/data/" | grep -c '^\*deleting' || true)
log "$deletes file(s) would be deleted from the disk"
if [ "$deletes" -gt "$MAX_DELETES" ] && ! $YES; then
  read -rp "[external] more than $MAX_DELETES deletions - continue? [y/N] " a
  [ "$a" = y ] || die "aborted, nothing copied"
fi

log "mirroring $SRC -> $MNT/data/ (first run takes hours)"
"${RSYNC[@]}" --info=progress2,stats1 "$SRC" "$MNT/data/"

cp /etc/homelab/restic.pass "$MNT/restic.pass"
chmod 600 "$MNT/restic.pass"
cp "$(command -v restic)" "$MNT/restic"
cp "$STACKS/docs/restore-from-hdd.md" "$MNT/RESTORE.md"
date -Is > "$MNT/LAST-COPY"

log "verifying the copied restic repository"
restic -r "$MNT/data/backups/restic" --password-file "$MNT/restic.pass" check --no-lock
log "done: $(cat "$MNT/LAST-COPY")"
