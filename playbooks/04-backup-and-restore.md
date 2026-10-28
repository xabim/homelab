# 04 · Backup & restore

**Use when:** before upgrades or risky changes, on a regular schedule, or when data is lost.
**Risk:** 🟢 backups are read-only · 🔴 restores overwrite data.

> ⚠️ **There is no automated backup.** `/srv/data` is a ZFS **mirror** (protects against a dead
> disk, not against deletion or corruption). `/srv/docker/volumes` — every database and config — is
> on the single NVMe. Take backups manually until something automated exists.

## What to back up

| Priority | Data | Location | Method |
|---|---|---|---|
| 🔴 | Nextcloud DB | container `nextcloud-db` | `pg_dump` |
| 🔴 | Immich DB | container `immich-postgres` | `pg_dumpall` |
| 🔴 | Paperless DB | container `paperless-db-1` | `pg_dump` |
| 🟠 | Forgejo DB | container `forgejo-db-1` (on-demand: start it first) | `pg_dump` |
| 🟠 | Configs | `/srv/docker/volumes/*` | `tar` (stack stopped) |
| 🟠 | SQLite apps | `/srv/data/kavita/config`, `/srv/docker/volumes/navidrome/data`, `/srv/docker/volumes/jellyfin/config` | `tar` (stack stopped) |
| 🟡 | Bulk data | `/srv/data/{nextcloud,immich,paperless,media,forgejo}` | off-host copy (rsync to external disk) |
| 🟢 | Compose files | `/srv/docker/stacks` | Git (GitHub) — secrets **not** included: copy `*/.env.secrets` separately |

## Database dumps (stack running)

```bash
BK=/srv/data/backups/$(date +%Y%m%d); mkdir -p $BK
docker exec nextcloud-db    pg_dump -U nextcloud -d nextcloud | gzip > $BK/nextcloud.sql.gz
docker exec paperless-db-1  pg_dump -U paperless -d paperless | gzip > $BK/paperless.sql.gz
docker exec immich-postgres pg_dumpall -U postgres            | gzip > $BK/immich.sql.gz
docker exec forgejo-db-1    pg_dump -U forgejo   -d forgejo   | gzip > $BK/forgejo.sql.gz
for f in $BK/*.sql.gz; do gzip -t "$f" && echo "OK $(du -h "$f")"; done
```

Nextcloud: wrap the dump in `occ maintenance:mode --on` / `--off` for a consistent file+DB state.

## Config / data tars (stack stopped)

Many directories are root-owned, so tar through a throwaway container:

```bash
docker run --rm -v /srv/docker/volumes/<app>:/d:ro -v $BK:/b alpine:3 \
  tar -C /d -czf /b/<app>-volumes.tar.gz .
```

## Secrets

```bash
tar -C /srv/docker/stacks -czf $BK/env-secrets.tar.gz $(cd /srv/docker/stacks && ls */.env.secrets immich/.secrets)
chmod 600 $BK/env-secrets.tar.gz
```

Invidious' secrets also live as Portainer stack variables (same values as `invidious/.env.secrets`).

## Restore — database

1. Stop the **app** container but keep the DB running (or stop the stack and start only the DB).
2. Recreate an empty database and load the dump:
   ```bash
   docker exec nextcloud-db psql -U nextcloud -d postgres -c 'DROP DATABASE nextcloud;' -c 'CREATE DATABASE nextcloud OWNER nextcloud;'
   gunzip -c $BK/nextcloud.sql.gz | docker exec -i nextcloud-db psql -U nextcloud -d nextcloud
   ```
3. **Immich:** follow Immich's documented restore procedure for `pg_dumpall` files (it needs a fresh
   cluster and a `search_path` fix-up).
4. Start the stack, verify data.

## Restore — config / files

```bash
# stack stopped in Portainer first; keeps the current state as <app>.before-restore
docker run --rm -v /srv/docker/volumes:/v -v $BK:/b:ro alpine:3 \
  sh -c 'mv /v/<app> /v/<app>.before-restore && mkdir /v/<app> && tar -C /v/<app> -xzf /b/<app>-volumes.tar.gz'
```

Then **Start** the stack in Portainer.

## Housekeeping

Backups sit on the same ZFS pool as the data. Copy important ones off-host and delete old
directories under `/srv/data/backups/` when no longer needed.
