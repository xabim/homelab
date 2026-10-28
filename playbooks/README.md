# 📖 Playbooks

Short, copy-pasteable runbooks for operating the homelab. Each one says **when** to use it,
**what it touches**, the **steps**, how to **verify**, and how to **roll back**.

| # | Playbook | Risk | Typical time |
|---|---|---|---|
| 01 | [Start & stop apps](01-start-stop-apps.md) | 🟢 none | 1 min |
| 02 | [Deploy a change](02-deploy-a-change.md) | 🟡 brief app downtime | 5 min |
| 03 | [Update images](03-update-images.md) | 🟠 app upgrade, possible DB migration | 10–30 min |
| 04 | [Backup & restore](04-backup-and-restore.md) | 🟢 backup / 🔴 restore | 10–60 min |
| 05 | [Add a new service](05-add-a-new-service.md) | 🟡 new app only | 30 min |
| 06 | [Infrastructure stacks](06-infrastructure-stacks.md) | 🔴 all routing/TLS | 10 min |
| 07 | [Secrets](07-secrets.md) | 🟡 one app | 5 min |
| 08 | [Reboot, shutdown & power](08-reboot-and-power.md) | 🟡 everything, briefly | 5 min |
| 09 | [Troubleshooting](09-troubleshooting.md) | 🟢 read-only first | — |
| 10 | [Disaster recovery](10-disaster-recovery.md) | 🔴 | 1–3 h |
| 11 | [Health check](11-health-check.md) | 🟢 read-only | 10 min |
| 12 | [TLS & certificates](12-tls-certificates.md) | 🟢 tasks 1–7 · 🟡 8–9 · 🔴 10 | 5–15 min |

Deep dive: [🔐 TLS & internal PKI](../docs/tls.md)

## Ground rules

1. **Never** run `docker compose down -v`, `docker volume prune` or `docker system prune` blindly.
2. **App stacks belong to Portainer.** Don't `docker compose up` an app from the CLI while its
   Portainer stack exists — you'd get two owners for the same containers.
3. **Infra stacks belong to the CLI** (`traefik`, `step-ca`, `docker-socket-proxy`, `portainer`).
4. **Back up before anything that touches a database** (image updates, major versions):
   `sudo scripts/backup.sh` — see [04](04-backup-and-restore.md#run-a-backup-now).
5. **Commit before you deploy.** Portainer deploys what is on GitHub `main`, not what is on disk.

## Handy variables

Most playbooks use these:

```bash
cd /srv/docker/stacks
CA="--cacert /srv/docker/volumes/step-ca/certs/root_ca.crt"   # for curl to *.home
BK=/srv/data/backups/$(date +%Y%m%d)                            # backup target
```

## Stack reference

| Stack | Owner | Mode | Containers | Database |
|---|---|---|---|---|
| `nextcloud` | Portainer | always-on | nextcloud, nextcloud-cron, nextcloud-db, nextcloud-redis, onlyoffice | PostgreSQL 16 |
| `paperless` | Portainer | always-on | paperless-webserver-1, paperless-db-1, paperless-broker-1 | PostgreSQL 18 |
| `invidious` | Portainer | always-on | invidious-invidious-1, invidious-companion-1, invidious-invidious-db-1 | PostgreSQL 18 |
| `kavita` | Portainer | on-demand | kavita | SQLite |
| `podsync` | Portainer | always-on | podsync | — |
| `immich` | Portainer | on-demand | immich-server, immich-ml, immich-postgres, immich-redis | PostgreSQL 18 + VectorChord |
| `jellyfin` | Portainer | on-demand | jellyfin | SQLite |
| `navidrome` | Portainer | on-demand | navidrome | SQLite |
| `forgejo` | Portainer | on-demand | forgejo-forgejo-1, forgejo-db-1 | PostgreSQL 18 |
| `musicbrainz-picard` | Portainer | on-demand | musicbrainz-picard-picard-1 | — |
| `yubal` | Portainer | on-demand | yubal | — |
| `homepage` | Portainer | on-demand | homepage | — |
| `traefik` | CLI | infra | traefik | — |
| `step-ca` | CLI | infra | step-ca | — |
| `docker-socket-proxy` | CLI | infra | docker-socket-proxy | — |
| `portainer` | CLI | infra | portainer | BoltDB |
