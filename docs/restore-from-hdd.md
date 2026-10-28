# Restore from the external backup disk

This disk is written by `scripts/backup-external.sh` (repo `github.com/xabim/homelab`).
Everything on it is plain files — `ls`, `cp` and `rsync` are all you need.

```text
data/                    mirror of the server's /srv/data (ZFS): media, photos, Nextcloud files, …
data/backups/nvme/       copy of the server's NVMe, made by scripts/backup.sh:
  db/<date>/*.sql.gz       pg_dumpall of every running Postgres (last 7 days)
  volumes/                 /srv/docker/volumes: app configs, step-ca CA keys, Traefik certs
  stacks/                  /srv/docker/stacks: the Git repo + every .env.secrets
  portainer/               Portainer's own backup + the API token
  host/                    daemon.json, fstab, network, ZFS layout, package list
  LAST-BACKUP              when that copy was made
LAST-COPY                when this disk was last written
```

⚠️ Not encrypted: anyone holding this disk can read everything on it, secrets included.

## Rebuild the server

`D=/mnt/homelab-backup` (where this disk is mounted).

1. Debian 13 with the `contrib` APT component, then `apt install git rsync`.
2. **Bulk data.** Pool intact → `zpool import tank`. Pool lost → create it again
   (`data/backups/nvme/host/zfs-properties.txt` shows the old layout), then
   `rsync -aH --numeric-ids $D/data/ /srv/data/`.
3. **Repo, secrets and configs** back to the NVMe:
   ```bash
   rsync -aH --numeric-ids /srv/data/backups/nvme/stacks/  /srv/docker/stacks/
   rsync -aH --numeric-ids /srv/data/backups/nvme/volumes/ /srv/docker/volumes/
   cd /srv/docker/stacks && git pull          # newer commits than the backup, if any
   ```
4. Follow the repo's `playbooks/10-disaster-recovery.md`, scenario C, from `host/bootstrap.sh`.
   Databases that were running at backup time are only in `db/`: load their dumps, below.

## Load a database dump

Start only the stack's DB container on an **empty** data directory (app containers stopped):

```bash
gunzip -c /srv/data/backups/nvme/db/<date>/<container>.sql.gz \
  | docker exec -i <container> sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Containers: `nextcloud-db`, `paperless-db-1`, `immich-postgres`, `invidious-invidious-db-1`, `forgejo-db-1`.
Then start the whole stack. Portainer: restore `portainer/portainer-backup.tar.gz` from its
first-run screen (*Restore Portainer from backup*), or rebuild it with `scripts/portainer-stacks.py apply`.
