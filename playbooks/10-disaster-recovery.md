# 10 · Disaster recovery

**Use when:** Portainer's data is lost, GitHub is unreachable, a disk dies, or the host must be rebuilt.
**Risk:** 🔴 — read the whole scenario before starting.

## Scenario A — GitHub unreachable

Nothing breaks. Running stacks keep running; **Start/Stop** use Portainer's local clone.
Only **Pull and redeploy** and **new stacks** fail. Wait, or use scenario C for an urgent change.

## Scenario B — Portainer broken or its data lost

Apps keep running — Portainer only orchestrates. To rebuild:

```bash
cd /srv/docker/stacks/portainer
docker compose down
sudo mv /srv/docker/volumes/portainer/data /srv/docker/volumes/portainer/data.broken-$(date +%Y%m%d)
docker compose up -d
```

1. Open `https://portainer.home` **within 5 minutes**, create the admin user, choose *Get started* (local socket).
2. Create an API token and store it in `~/.config/portainer-api.hdr` ([07](07-secrets.md#portainer-api-token)).
3. Existing projects now show as *Limited*. Take down the ones still running (data is in bind mounts):
   ```bash
   cd /srv/docker/stacks/<app> && docker compose down       # NEVER -v
   ```
4. Re-create every app stack from [`stacks.toml`](../stacks.toml):
   ```bash
   cd /srv/docker/stacks
   scripts/portainer-stacks.py plan          # every stack shows "+ create"
   scripts/portainer-stacks.py apply --yes   # always-on start; on-demand are stopped again
   ```
   Invidious' stack variables are read from `invidious/.env.secrets` automatically.

## Run an app without Portainer

Emergency only — it creates a second owner for the containers.

```bash
cd /srv/docker/stacks/<app> && docker compose up -d
```

Before giving the stack back to Portainer: `docker compose down` in that directory, then
**Start** (or re-create) it in Portainer.

## Scenario C — rebuild the host

Order matters:

1. Debian 13, Docker Engine + Compose plugin, ZFS, restic. Pool intact → `zpool import tank` → `/srv/data`.
   Pool lost → recreate it and copy `data/` back from the external disk
   ([restore-from-hdd](../docs/restore-from-hdd.md)).
2. `/etc/homelab/restic.pass` (mode 600) from the external disk or your password manager.
3. Restore `/srv/docker` (compose files, **all `.env.secrets`**, step-ca CA keys, Traefik, app configs)
   from the latest nightly snapshot, then load the DB dumps ([04](04-backup-and-restore.md#restore--from-the-nightly-snapshots)):
   ```bash
   export RESTIC_REPOSITORY=/srv/data/backups/restic RESTIC_PASSWORD_FILE=/etc/homelab/restic.pass
   restic restore latest --target / --include /srv/docker
   cd /srv/docker/stacks && git pull          # newer commits than the snapshot, if any
   ```
   Databases that were running at backup time have **no data directory** in the snapshot — load
   their dumps after step 5 and **before step 7**, or the apps initialise empty databases:
   `cd <app> && docker compose up -d <db-service>`, load the dump, `docker compose down`.
4. Backup timer: `cp host/systemd/homelab-backup.{service,timer} /etc/systemd/system/` and
   `systemctl enable --now homelab-backup.timer`.
5. Networks: `docker network create proxy && docker network create dockersock`
6. Infra, in this order:
   ```bash
   for s in docker-socket-proxy step-ca traefik portainer; do (cd /srv/docker/stacks/$s && docker compose up -d); done
   ```
7. App stacks via Portainer (scenario B, step 1 onwards).
8. Clients keep trusting the old root CA only if step-ca's data was restored — otherwise
   reinstall the new `root_ca.crt` everywhere.

## Scenario D — a ZFS disk fails

```bash
zpool status tank                 # shows DEGRADED + the failed device
sudo zpool replace tank <old-dev> /dev/disk/by-id/<new-disk>
zpool status tank                 # watch the resilver
```

The mirror keeps serving data while degraded. Replace soon — a second failure loses `/srv/data`.

## Scenario E — NVMe fails

Lost: OS, `/srv/docker/volumes` (all DBs and configs), Portainer data. Survives: `/srv/data`,
GitHub, and the nightly restic snapshots on ZFS. Recovery = scenario C — at most one night of
configs and databases is lost.
