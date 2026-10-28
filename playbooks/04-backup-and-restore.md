# 04 · Backup & restore

**Use when:** before upgrades or risky changes, copying to the external disk, or when data is lost.
**Risk:** 🟢 backups are read-only · 🔴 restores overwrite data.

## How it works

Plain files and rsync — no backup tool, no password, nothing to install.

| Step | What | Where | When |
|---|---|---|---|
| **1 · NVMe → ZFS** | DB dumps, configs, secrets, Portainer, host config | `/srv/data/backups/nvme/` | nightly 03:30 (`homelab-backup.timer`) **or by hand** → [`scripts/backup.sh`](../scripts/backup.sh) |
| **2 · ZFS → HDD** | all of `/srv/data`: bulk data **and** step 1 | external HDD labelled `HOMELAB-BACKUP` | by hand → [`scripts/backup-external.sh`](../scripts/backup-external.sh) |

Live data stays on the NVMe; ZFS holds the copy. Inside `/srv/data/backups/nvme/` (root only):

| Path | Content |
|---|---|
| `db/<date>/<container>.sql.gz` | `pg_dumpall --clean --if-exists` of every **running** Postgres — last 7 days kept |
| `volumes/` | rsync of `/srv/docker/volumes` — latest only |
| `stacks/` | rsync of `/srv/docker/stacks` — the Git repo **plus every `.env.secrets`** |
| `portainer/` | Portainer's own backup (`portainer.db` can't be copied while open) + the API token |
| `host/` | `daemon.json`, `fstab`, network config, ZFS layout, package list |
| `LAST-BACKUP` | when the last run finished |

* **Postgres:** running databases are dumped and their data directory left out of `volumes/`;
  stopped ones (e.g. Forgejo) are consistent on disk and copied as files.
* **SQLite apps** (Navidrome, Kavita, Jellyfin) are copied as files — fine while stopped; if one is
  running, the run prints a `WARNING`.
* **Skipped:** Jellyfin cache, Immich ML cache, logs, Redis.
* **Host off at 03:30?** The timer runs after the next boot, once the host has been up 15 minutes.

Both copies are **mirrors**: `volumes/` and `stacks/` hold the latest state only, and the HDD gets
whatever `/srv/data` holds at that moment — a file deleted on the server disappears from the disk on the
next copy. The HDD is **not encrypted**: anyone holding it can read everything, secrets included.

## Run a backup now

Any time — before an upgrade, a migration, or just because:

```bash
sudo /srv/docker/stacks/scripts/backup.sh
```

Takes a minute or two and ends with `[backup] done: <size> in /srv/data/backups/nvme`. `WARNING` /
`ERROR` lines are printed as they happen. If the nightly run is in progress it stops with
`another backup is running` — wait and retry.

The same run through systemd (output in the journal, like the nightly one):

```bash
sudo systemctl start homelab-backup.service && journalctl -u homelab-backup.service -n 30
```

For a complete off-host copy: run the backup, then the external copy below.

## Copy to the external disk

Plug the disk in, then:

```bash
sudo /srv/docker/stacks/scripts/backup-external.sh
```

It mounts the disk by label, refuses to run if `/srv/data` isn't mounted, asks before deleting more
than 1000 files, mirrors `/srv/data`, adds `RESTORE.md` ([docs/restore-from-hdd.md](../docs/restore-from-hdd.md))
and unmounts. Unplug after `disk unmounted, safe to unplug`. The first run takes hours; later ones
copy only changes.

### Prepare the disk (once, erases it)

```bash
lsblk -o NAME,SIZE,MODEL,LABEL          # find the disk — double-check, this wipes it
sudo mkfs.ext4 -L HOMELAB-BACKUP /dev/sdX1
```

It must be larger than `/srv/data` (`zfs list tank/data`) with room to grow.

## Check the backup

```bash
sudo cat /srv/data/backups/nvme/LAST-BACKUP           # last NVMe backup
sudo ls /srv/data/backups/nvme/db/                    # one directory per day of dumps
journalctl -u homelab-backup.service -n 30            # last nightly run: WARNING / ERROR?
```

The timer is installed by [`host/bootstrap.sh`](../host/bootstrap.sh).

## Restore

`B=/srv/data/backups/nvme` (or `/mnt/homelab-backup/data/backups/nvme` from the HDD).

**Config / files of one app:** stop the stack in Portainer, keep the current state, copy back:

```bash
sudo mv /srv/docker/volumes/<app> /srv/docker/volumes/<app>.before-restore
sudo rsync -aH --numeric-ids $B/volumes/<app>/ /srv/docker/volumes/<app>/
```

Then **Start** the stack in Portainer and verify.

**Database:** stop the **app** container but keep (or start only) the DB container on an **empty**
data directory, then load the dump:

```bash
sudo ls $B/db/                                         # pick a date
gunzip -c $B/db/<date>/<container>.sql.gz \
  | docker exec -i <container> sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Start the whole stack and verify. **Immich:** see Immich's restore docs for anything beyond this.

**A secret:** `sudo cp -a $B/stacks/<app>/.env.secrets /srv/docker/stacks/<app>/` (mode 600 is kept).

## One-off dump or tar

For a copy kept apart from the nightly rotation:

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
