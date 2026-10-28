#!/usr/bin/env bash
# =============================================================================
# Nightly backup: NVMe (configs, DB dumps, secrets, host config) -> restic on ZFS
#
#   sudo scripts/backup.sh            take a snapshot, prune, weekly check
#   sudo scripts/backup.sh init       create the repository (once)
#   sudo scripts/backup.sh snapshots  list snapshots
#
# Runs from host/systemd/homelab-backup.timer. Live data stays on the NVMe;
# only the restic repository lives on ZFS (/srv/data/backups/restic), which
# scripts/backup-external.sh then mirrors to the external HDD.
# =============================================================================
set -euo pipefail

export RESTIC_REPOSITORY=/srv/data/backups/restic
export RESTIC_PASSWORD_FILE=/etc/homelab/restic.pass
STACKS=/srv/docker/stacks
VOLUMES=/srv/docker/volumes
STAGE=/var/tmp/homelab-backup
PORTAINER_URL=https://portainer.home
PORTAINER_TOKEN_FILE=/home/xabim/.config/portainer-api.hdr

# Postgres containers and their data directory. Running ones are dumped and
# their directory skipped; stopped ones are consistent on disk and copied as files.
DATABASES=(
  "nextcloud-db:$VOLUMES/nextcloud/db"
  "paperless-db-1:$VOLUMES/paperless/postgres"
  "immich-postgres:$VOLUMES/immich/postgres"
  "invidious-invidious-db-1:$VOLUMES/invidious/postgres"
  "forgejo-db-1:$VOLUMES/forgejo/postgres"
)
# SQLite apps: a copy taken while they run may be inconsistent
SQLITE_APPS=(navidrome kavita jellyfin)

EXCLUDES=(
  "$VOLUMES/jellyfin/cache"
  "$VOLUMES/immich/ml-cache"
  "$VOLUMES/immich/logs"
  "$VOLUMES/onlyoffice/logs"
  "$VOLUMES/*/redis"
  "$VOLUMES/forgejo/postgres_pg15_backup"
)

log()  { echo "[backup] $*"; }
warn() { echo "[backup] WARNING: $*" >&2; }
die()  { echo "[backup] ERROR: $*" >&2; exit 1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

[ "$(id -u)" = 0 ] || die "run as root"
command -v restic >/dev/null || die "restic is not installed (apt install restic)"
[ -s "$RESTIC_PASSWORD_FILE" ] || die "$RESTIC_PASSWORD_FILE missing"

case "${1:-run}" in
  init)      mkdir -p "$RESTIC_REPOSITORY"; exec restic init ;;
  snapshots) exec restic snapshots ;;
  run)       ;;
  *)         die "usage: $0 [run|init|snapshots]" ;;
esac

# One backup job at a time (backup-external.sh takes the same lock)
exec 9>/run/homelab-backup.lock
flock -n 9 || die "another backup is running"
mountpoint -q /srv/data || die "/srv/data is not mounted"
restic cat config >/dev/null 2>&1 || die "no repository at $RESTIC_REPOSITORY (run: $0 init)"

rm -rf "$STAGE"
mkdir -p "$STAGE"/{db,portainer,host}
chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

# --- Databases ---------------------------------------------------------------
for entry in "${DATABASES[@]}"; do
  c=${entry%%:*} dir=${entry#*:}
  if running "$c"; then
    log "dump $c"
    docker exec "$c" sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' \
      | gzip > "$STAGE/db/$c.sql.gz"
    gzip -t "$STAGE/db/$c.sql.gz"
    EXCLUDES+=("$dir")
  else
    log "$c stopped: copying $dir as files"
  fi
done

for app in "${SQLITE_APPS[@]}"; do
  running "$app" && warn "$app is running: its SQLite copy may be inconsistent"
done

# --- Portainer (its own backup; portainer.db must not be copied while open) ---
if curl -fsS -X POST -H @"$PORTAINER_TOKEN_FILE" -H 'Content-Type: application/json' \
     -d '{"password":""}' -o "$STAGE/portainer/portainer-backup.tar.gz" \
     "$PORTAINER_URL/api/backup"; then
  log "portainer backup via API"
  EXCLUDES+=("$VOLUMES/portainer/data")
else
  warn "Portainer backup API failed: copying its data directory as files"
fi

# --- Host configuration --------------------------------------------------------
for f in /etc/docker/daemon.json /etc/fstab /etc/hosts /etc/network/interfaces \
         /etc/systemd/system/homelab-backup.service /etc/systemd/system/homelab-backup.timer; do
  [ -e "$f" ] && cp --parents -a "$f" "$STAGE/host/"
done
zpool status         > "$STAGE/host/zpool-status.txt"
zpool get all        > "$STAGE/host/zpool-properties.txt"
zfs get -s local all > "$STAGE/host/zfs-properties.txt"
dpkg --get-selections > "$STAGE/host/packages.txt"
docker network ls     > "$STAGE/host/docker-networks.txt"

# --- Snapshot ----------------------------------------------------------------
# /srv/docker/stacks includes every .env.secrets and immich/.secrets
exclude_args=()
for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude "$e"); done

log "restic backup"
restic backup --host homelab --tag nightly "${exclude_args[@]}" \
  "$STACKS" "$VOLUMES" "$STAGE" "$PORTAINER_TOKEN_FILE"

log "prune (7 daily, 4 weekly, 6 monthly)"
restic forget --host homelab --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

if [ "$(date +%u)" = 7 ]; then
  log "weekly repository check"
  restic check
fi
log "done"
