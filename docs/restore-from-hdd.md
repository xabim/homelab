# Restore from the external backup disk

This disk is written by `scripts/backup-external.sh` (repo `github.com/xabim/homelab`).

```text
data/                  mirror of the server's /srv/data (ZFS): media, photos, Nextcloud files, …
data/backups/restic/   nightly restic repository of the NVMe:
                         /srv/docker/stacks      compose files + every .env.secrets
                         /srv/docker/volumes     app configs, step-ca keys, Traefik certs
                         /var/tmp/homelab-backup db/*.sql.gz (pg_dumpall), portainer/, host/
restic                 restic binary (Linux x86_64)
restic.pass            repository password
LAST-COPY              when this disk was last written
```

⚠️ Anyone holding this disk can read everything on it, secrets included.

## Look inside

```bash
D=/mnt/homelab-backup
export RESTIC_REPOSITORY=$D/data/backups/restic RESTIC_PASSWORD_FILE=$D/restic.pass
$D/restic snapshots
$D/restic ls latest /srv/docker/stacks/nextcloud
```

## Rebuild the server

1. Debian 13, Docker Engine + Compose plugin, ZFS, restic.
2. **Bulk data.** Pool intact → `zpool import tank`. Pool lost → create it again
   (`host/zpool-properties.txt` and `host/zfs-properties.txt` in the snapshot show the old layout), then
   `rsync -aHAX --numeric-ids $D/data/ /srv/data/`.
3. **NVMe data.** Restore the latest snapshot to its original paths:
   ```bash
   restic restore latest --target / --include /srv/docker
   restic restore latest --target /tmp/restore --include /var/tmp/homelab-backup
   install -d -m 700 /etc/homelab && cp $D/restic.pass /etc/homelab/restic.pass
   ```
4. Follow the repo's `playbooks/10-disaster-recovery.md`, scenario C, from step 5.
   Databases that were running at backup time were skipped as files: load their dumps, below.

## Load a database dump

Each running Postgres was dumped with `pg_dumpall --clean --if-exists`. With the stack's DB
container started on an **empty** data directory (app containers stopped):

```bash
gunzip -c /tmp/restore/var/tmp/homelab-backup/db/<container>.sql.gz \
  | docker exec -i <container> sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Containers: `nextcloud-db`, `paperless-db-1`, `immich-postgres`, `invidious-invidious-db-1`, `forgejo-db-1`.
Then start the whole stack. Portainer: restore `portainer/portainer-backup.tar.gz` from its
first-run screen (*Restore Portainer from backup*), or rebuild it with `scripts/portainer-stacks.py apply`.
