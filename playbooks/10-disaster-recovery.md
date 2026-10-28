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

[`host/bootstrap.sh`](../host/bootstrap.sh) does the host part and is safe to re-run: it installs
packages, writes `daemon.json`, imports the pool, enables the scrub and backup timers, creates the
networks and starts the infra stacks — and prints a **TODO** for anything it can't do itself.

1. Install Debian 13 with the `contrib` APT component (for ZFS), then:
   ```bash
   sudo apt install git
   sudo git clone https://github.com/xabim/homelab.git /srv/docker/stacks
   sudo chown -R $USER: /srv/docker/stacks
   sudo /srv/docker/stacks/host/bootstrap.sh       # first pass: packages, pool, networks
   ```
   Containers resolve `*.home` through the first `nameserver` in `/etc/resolv.conf` — if that isn't
   the Pi-hole, run it as `sudo DOCKER_DNS=<pihole-ip> …/bootstrap.sh`.
2. **Pool lost?** Recreate `tank` (layout in `backups/nvme/host/zfs-properties.txt` on the external
   disk) and copy the data back from it ([restore-from-hdd](../docs/restore-from-hdd.md)).
3. **Restore `/srv/docker`** — the repo with **all `.env.secrets`**, step-ca CA keys, Traefik, app configs:
   ```bash
   B=/srv/data/backups/nvme
   sudo rsync -aH --numeric-ids $B/stacks/  /srv/docker/stacks/
   sudo rsync -aH --numeric-ids $B/volumes/ /srv/docker/volumes/
   cd /srv/docker/stacks && git pull            # newer commits than the backup, if any
   ```
4. **Second pass:** `sudo host/bootstrap.sh` — now starts socket proxy, step-ca, Traefik and Portainer.
5. **Databases** that were running at backup time have **no data directory** in `volumes/`. Load
   their dumps from `$B/db/<date>/` **before** the apps start, or they initialise empty databases:
   `cd <app> && docker compose up -d <db-service>`, load the dump
   ([04](04-backup-and-restore.md#restore)), `docker compose down`.
6. **Portainer:** create the admin (or restore `portainer/portainer-backup.tar.gz` on its first-run
   screen) and an API token, then the app stacks — scenario B, steps 2–4:
   `scripts/portainer-stacks.py apply --yes`.
7. Clients keep trusting the old root CA only if step-ca's data was restored — otherwise
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
GitHub, and the NVMe backup in `/srv/data/backups/nvme`. Recovery = scenario C — at most
one backup run of configs and databases is lost.
