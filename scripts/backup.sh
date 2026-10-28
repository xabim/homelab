#!/usr/bin/env bash
# =============================================================================
# Backup of the NVMe to ZFS, as plain files (DB dumps + rsync)
#
#   sudo /srv/docker/stacks/scripts/backup.sh          by hand, any time
#   sudo /srv/docker/stacks/scripts/backup.sh --wait   wait for a running backup/copy first
#
# Runs every day at 22:00 from host/systemd/homelab-shutdown.timer, right before
# the host powers off.
# Live data stays on the NVMe; the copy lands in /srv/data/backups/nvme (ZFS),
# which scripts/backup-external.sh then mirrors to the external HDD:
#
#   db/<date>/<container>.sql.gz   pg_dumpall of every running Postgres (last 7 days)
#   volumes/                       rsync of /srv/docker/volumes (latest only)
#   stacks/                        rsync of /srv/docker/stacks, .env.secrets included
#   portainer/                     Portainer's own backup + the API token
#   host/                          daemon.json, fstab, network, ZFS layout, packages
#   LAST-BACKUP                    when the last run finished
# =============================================================================
set -euo pipefail

DEST=/srv/data/backups/nvme
STACKS=/srv/docker/stacks
VOLUMES=/srv/docker/volumes
KEEP_DUMPS=7
PORTAINER_URL=https://portainer.home
PORTAINER_TOKEN_FILE=/home/xabim/.config/portainer-api.hdr

# Postgres containers and their data directory. Running ones are dumped and
# their directory skipped; stopped ones are consistent on disk and copied as files.
DATABASES=(
  "nextcloud-db:nextcloud/db"
  "paperless-db-1:paperless/postgres"
  "immich-postgres:immich/postgres"
  "invidious-invidious-db-1:invidious/postgres"
  "forgejo-db-1:forgejo/postgres"
)
# SQLite apps: a copy taken while they run may be inconsistent
SQLITE_APPS=(navidrome kavita jellyfin)

# Relative to /srv/docker/volumes; rebuilt by the apps, not worth copying
EXCLUDES=(jellyfin/cache immich/ml-cache immich/logs onlyoffice/logs '*/redis' forgejo/postgres_pg15_backup)

log()  { echo "[backup] $*"; }
warn() { echo "[backup] WARNING: $*" >&2; }
die()  { echo "[backup] ERROR: $*" >&2; exit 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
mountpoint -q /srv/data || die "/srv/data is not mounted"

# One backup at a time (backup-external.sh takes the same lock)
exec 9>/run/homelab-backup.lock
if [ "${1:-}" = --wait ]; then
  flock -n 9 || { log "waiting for the running backup/copy to finish"; flock 9; }
else
  flock -n 9 || die "another backup is running (use --wait to queue)"
fi

# Holds every secret: root only
install -d -m 700 "$DEST"
mkdir -p "$DEST"/{db,volumes,stacks,portainer,host}

# --- Databases ---------------------------------------------------------------
today="$DEST/db/$(date +%F)"
mkdir -p "$today"
for entry in "${DATABASES[@]}"; do
  c=${entry%%:*} dir=${entry#*:}
  if running "$c"; then
    log "dump $c"
    docker exec "$c" sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' \
      | gzip > "$today/$c.sql.gz.tmp"
    gzip -t "$today/$c.sql.gz.tmp" && mv "$today/$c.sql.gz.tmp" "$today/$c.sql.gz"
    EXCLUDES+=("$dir")
  else
    log "$c stopped: copying $dir as files"
  fi
done
rmdir "$today" 2>/dev/null || true
# keep the newest $KEEP_DUMPS dated directories
{ ls -1d "$DEST"/db/*/ 2>/dev/null || true; } | sort | head -n -"$KEEP_DUMPS" | xargs -r rm -rf

for app in "${SQLITE_APPS[@]}"; do
  running "$app" && warn "$app is running: its SQLite copy may be inconsistent"
done

# --- Portainer (its own backup; portainer.db must not be copied while open) ---
if curl -fsS -X POST -H @"$PORTAINER_TOKEN_FILE" -H 'Content-Type: application/json' \
     -d '{"password":""}' -o "$DEST/portainer/portainer-backup.tar.gz.tmp" \
     "$PORTAINER_URL/api/backup"; then
  mv "$DEST/portainer/portainer-backup.tar.gz.tmp" "$DEST/portainer/portainer-backup.tar.gz"
  log "portainer backup via API"
  EXCLUDES+=(portainer/data)
else
  rm -f "$DEST/portainer/portainer-backup.tar.gz.tmp"
  warn "Portainer backup API failed: copying its data directory as files"
fi
cp -a "$PORTAINER_TOKEN_FILE" "$DEST/portainer/"

# --- Files ---------------------------------------------------------------------
# --delete-excluded: a DB directory copied while stopped disappears once it is dumped
exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude "/$e"); done
log "rsync volumes"
rsync -aH --numeric-ids --delete --delete-excluded "${exclude_args[@]}" "$VOLUMES/" "$DEST/volumes/"
log "rsync stacks"
rsync -aH --numeric-ids --delete "$STACKS/" "$DEST/stacks/"

# --- Host configuration --------------------------------------------------------
rm -rf "$DEST/host" && mkdir -p "$DEST/host"
for f in /etc/docker/daemon.json /etc/fstab /etc/hosts /etc/network/interfaces; do
  [ -e "$f" ] && cp --parents -a "$f" "$DEST/host/"
done
zpool status          > "$DEST/host/zpool-status.txt"
zpool get all         > "$DEST/host/zpool-properties.txt"
zfs get -s local all  > "$DEST/host/zfs-properties.txt"
dpkg --get-selections > "$DEST/host/packages.txt"

date -Is > "$DEST/LAST-BACKUP"
log "done: $(du -sh "$DEST" | cut -f1) in $DEST"
