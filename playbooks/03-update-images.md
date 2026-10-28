# 03 · Update images (new app versions)

**Use when:** an app has a new release, or Portainer/Kavita/etc. says "new version available".
**Risk:** 🟠 the app may run one-way database migrations. **Always back up first.**

## How tags work here

| Style | Stacks | Updates when… |
|---|---|---|
| **Pinned** in `.env` (`NAVIDROME_VERSION=0.64.2`, `PAPERLESS_VERSION=2.20.15`, `KAVITA_VERSION=…`, `HOMEPAGE_VERSION=…`, `JELLYFIN_VERSION=10.11.11`, `IMMICH_VERSION=v2` = major line) or in the compose file (`nextcloud:32-apache`, `onlyoffice/documentserver:9.4.0.1`, `forgejo:15`, `traefik:v3.6.25`) | most | you change the version and commit |
| **Floating** (`release`, `latest`, `nightly`) | invidious, podsync, picard, yubal | you redeploy with **Re-pull image** |

Prefer pinned tags: an upgrade then has a commit you can revert.

## Steps — app stack

1. **Read the release notes.** Look for "breaking", "migration", "PostgreSQL".
2. **Back up** the stack's database and config → [04](04-backup-and-restore.md).
3. **Bump the version** (pinned) in `<app>/.env` or `docker-compose.yml`, commit, push.
4. Portainer → Stacks → *app* → **Pull and redeploy** with **Re-pull image: on**.
5. Watch the logs until migrations finish (Stacks → container → Logs). Don't stop it mid-migration.
6. Verify like [02](02-deploy-a-change.md#verify), plus log in and check your data.

## PostgreSQL major versions ⚠️

Changing `postgres:16` → `postgres:17` **does not upgrade the data** — the new server refuses the
old data dir (or, with a changed mount path, silently starts an empty cluster). Procedure:

1. `pg_dump` / `pg_dumpall` the old DB → [04](04-backup-and-restore.md).
2. Stop the stack, move the old data dir aside (`mv …/postgres …/postgres_pgNN_backup`).
3. Bump the image (note: PostgreSQL ≥ 18 images expect the mount at `/var/lib/postgresql`, not `/var/lib/postgresql/data`).
4. Restore into a **temporary container** on the new (empty) data dir, so the app never starts
   against an empty DB and the stack's `docker-entrypoint-initdb.d` scripts don't create tables
   that clash with the dump:
   ```bash
   cd /srv/docker/stacks/<app>
   docker run -d --name pgtmp --network none --env-file ../.env.global --env-file .env \
     --env-file .env.secrets -v <data dir>:/var/lib/postgresql postgres:<new>
   # wait for "PostgreSQL init process complete", then:
   docker exec -i pgtmp sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' < dump
   docker stop pgtmp && docker rm pgtmp
   ```
5. Compare row counts with the old DB, then redeploy the stack (Git redeploy, so the new
   compose is used) and verify the app.

Immich's Postgres image (`ghcr.io/immich-app/postgres`) must follow Immich's own upgrade notes:
plain `pg_dump --clean --if-exists`, restored with `psql --single-transaction` after the
`search_path` fix-up from Immich's backup docs. Raw SQL against its `vchordrq` indexes needs
`SET LOCAL vchordrq.probes = 1` (Immich sets it itself).

## Infra images (CLI stacks)

See [06 · Infrastructure stacks](06-infrastructure-stacks.md#update-an-infra-image).

## Rollback

* **Pinned tag:** `git revert`, push, Pull and redeploy — **only safe if no DB migration ran**.
* **After a migration:** stop the stack, restore the backup of config + DB, then revert the tag.
