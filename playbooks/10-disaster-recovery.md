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
2. Existing projects now show as *Limited*. Re-adopt each app stack, one at a time:
   ```bash
   # stack running → take it down first (data is in bind mounts)
   cd /srv/docker/stacks/<app> && docker compose down       # NEVER -v
   ```
   then Stacks → Add stack → Repository (same settings as [05](05-add-a-new-service.md#5-commit-push-deploy)).
3. **Invidious:** re-add its 3 stack variables from `invidious/.env.secrets`.
4. Stop the on-demand stacks again. Create a new API token if you use one.

## Run an app without Portainer

Emergency only — it creates a second owner for the containers.

```bash
cd /srv/docker/stacks/<app> && docker compose up -d
```

Before giving the stack back to Portainer: `docker compose down` in that directory, then
**Start** (or re-create) it in Portainer.

## Scenario C — rebuild the host

Order matters:

1. Debian 13, Docker Engine + Compose plugin, ZFS (`zpool import tank` → `/srv/data`).
2. `git clone git@github.com:xabim/homelab.git /srv/docker/stacks`
3. Restore `*/.env.secrets` from your secrets backup ([04](04-backup-and-restore.md#secrets)), mode 600.
4. Restore `/srv/docker/volumes` from backup — **step-ca** (CA keys!), traefik, portainer, app configs/DBs.
5. Networks: `docker network create proxy && docker network create dockersock`
6. Infra, in this order:
   ```bash
   for s in docker-socket-proxy step-ca traefik portainer; do (cd /srv/docker/stacks/$s && docker compose up -d); done
   ```
7. App stacks via Portainer (scenario B, step 2 onwards).
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
GitHub. Recovery = scenario C with your latest database dumps. **This is why off-host backups of
`/srv/docker/volumes` matter.**
