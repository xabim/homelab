# 04 · Backup & restore

**Use when:** setting up backups, copying to the external disk, before risky changes, or when data is lost.
**Risk:** 🟢 backups are read-only · 🔴 restores overwrite data.

## How it works

| Layer | What | Where | When |
|---|---|---|---|
| **Nightly** | configs, DB dumps, secrets, Portainer, host config (everything on the NVMe) | restic repo `/srv/data/backups/restic` (ZFS) | 03:30, `homelab-backup.timer` → [`scripts/backup.sh`](../scripts/backup.sh) |
| **External** | all of `/srv/data` (bulk data **and** the restic repo) | HDD labelled `HOMELAB-BACKUP` | by hand → [`scripts/backup-external.sh`](../scripts/backup-external.sh) |

Live data stays on the NVMe; ZFS only holds the backups of it. The nightly snapshot:

* **Postgres:** running containers are dumped (`pg_dumpall --clean --if-exists`) and their data
  directories skipped; stopped ones (e.g. Forgejo) are consistent on disk and copied as files.
* **Portainer:** taken through its backup API (`portainer.db` must not be copied while open).
* **Secrets:** all of `/srv/docker/stacks`, so every `.env.secrets` and `immich/.secrets`.
* **Host:** `daemon.json`, `fstab`, network config, ZFS properties, package list, Docker networks.
* **Skipped:** Jellyfin cache, Immich ML cache, logs, Redis.
* **SQLite apps** (Navidrome, Kavita, Jellyfin) are copied as files — fine while stopped. If one is
  running at 03:30, the journal shows a warning.
* Kept: 7 daily, 4 weekly, 6 monthly. `restic check` every Sunday.

The external disk is a plain **mirror** — no history: a file deleted on the server is deleted from the
disk on the next copy. The disk holds `restic.pass`, so **anyone holding it can read everything**.

## One-time setup

```bash
sudo apt install restic
sudo install -d -m 700 /etc/homelab
sudo sh -c 'umask 077; openssl rand -base64 32 > /etc/homelab/restic.pass'
sudo /srv/docker/stacks/scripts/backup.sh init
sudo cp /srv/docker/stacks/host/systemd/homelab-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now homelab-backup.timer
sudo systemctl start homelab-backup.service     # first run now; watch with journalctl
```

Also keep the password somewhere off the server (`sudo cat /etc/homelab/restic.pass`).

### Prepare the external disk (once, erases it)

```bash
lsblk -o NAME,SIZE,MODEL,LABEL          # find the disk — double-check, this wipes it
sudo mkfs.ext4 -L HOMELAB-BACKUP /dev/sdX1
```

It must be larger than `/srv/data` (`zfs list tank/data`) with room to grow.

## Copy to the external disk

```bash
sudo /srv/docker/stacks/scripts/backup-external.sh
```

It mounts the disk by label, refuses to run if `/srv/data` isn't mounted, asks before deleting more
than 1000 files, mirrors `/srv/data`, adds `restic`, `restic.pass` and `RESTORE.md`
([docs/restore-from-hdd.md](../docs/restore-from-hdd.md)), checks the copied repo and unmounts.
The first run takes hours; later ones copy only changes.

## Run a backup now

Any time — before an upgrade, a migration, or just because. The nightly snapshot may be up to a day old.

**Nightly backup (NVMe → ZFS), output in the terminal:**

```bash
sudo /srv/docker/stacks/scripts/backup.sh
```

Takes a minute or two. It ends with `[backup] done`; any `WARNING` / `ERROR` line is printed as it
happens. If the timer's run is in progress it refuses with `another backup is running` — wait and retry.

**Same thing through systemd** (identical run, output goes to the journal like the nightly one):

```bash
sudo systemctl start homelab-backup.service          # returns when finished
journalctl -u homelab-backup.service -n 30           # read the result
```

**Then confirm** a new snapshot exists (newest last):

```bash
sudo /srv/docker/stacks/scripts/backup.sh snapshots
```

**External disk (ZFS → HDD):** plug it in, then

```bash
sudo /srv/docker/stacks/scripts/backup-external.sh
```

For a complete off-host copy, run the nightly backup first, then the external one.

## Check the nightly backup

```bash
systemctl list-timers homelab-backup.timer
journalctl -u homelab-backup.service -n 50       # last run; look for WARNING / ERROR
sudo /srv/docker/stacks/scripts/backup.sh snapshots
```

## Restore — from the nightly snapshots

```bash
export RESTIC_REPOSITORY=/srv/data/backups/restic RESTIC_PASSWORD_FILE=/etc/homelab/restic.pass
sudo -E restic snapshots
sudo -E restic restore latest --target /tmp/restore --include /srv/docker/volumes/<app>
```

**Config / files:** stop the stack in Portainer, keep the current state, put the restored copy in place:

```bash
sudo mv /srv/docker/volumes/<app> /srv/docker/volumes/<app>.before-restore
sudo cp -a /tmp/restore/srv/docker/volumes/<app> /srv/docker/volumes/<app>
```

**Database:** restore the dump, then load it into the DB container started on an **empty** data
directory (app containers stopped):

```bash
sudo -E restic restore latest --target /tmp/restore --include /var/tmp/homelab-backup/db
gunzip -c /tmp/restore/var/tmp/homelab-backup/db/<container>.sql.gz \
  | docker exec -i <container> sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Then **Start** the stack in Portainer and verify. **Immich:** see Immich's restore docs for
anything beyond this (it needs a fresh cluster).

**Secrets:** `--include /srv/docker/stacks` and copy the `.env.secrets` you need (mode 600).

## One-off dump or tar (outside restic)

For a quick file you can hand to `psql` right away, next to the snapshots:

```bash
BK=/srv/data/backups/$(date +%Y%m%d); mkdir -p $BK
docker exec <container> sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' | gzip > $BK/<container>.sql.gz
gzip -t $BK/<container>.sql.gz && du -h $BK/*
```

Config tars (many directories are root-owned, so tar through a throwaway container, stack stopped):

```bash
docker run --rm -v /srv/docker/volumes/<app>:/d:ro -v $BK:/b alpine:3 \
  tar -C /d -czf /b/<app>-volumes.tar.gz .
```

Nextcloud: wrap a manual dump in `occ maintenance:mode --on` / `--off` for a consistent file+DB state.
Delete dated `/srv/data/backups/<date>/` directories once they're no longer needed — the external
copy mirrors them too.
