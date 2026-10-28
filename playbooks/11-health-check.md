# 11 · Health check

**Use when:** once a month, after a reboot, or when something "feels slow".
**Risk:** 🟢 read-only.

```bash
CA="--cacert /srv/docker/volumes/step-ca/certs/root_ca.crt"
```

## Quick check (2 minutes)

```bash
# containers: anything restarting, exited or unhealthy?
docker ps -a --filter health=unhealthy --format '{{.Names}} UNHEALTHY'
docker ps -a --filter status=restarting --filter status=exited --format '{{.Names}} {{.Status}}'
docker ps --format '{{.Names}}' | xargs docker inspect --format '{{.Name}} {{.RestartCount}}' | awk '$2>0'

# URLs
for h in portainer cloud office paperless podsync invidious; do
  printf '%-10s %s\n' $h "$(curl -s $CA -o /dev/null -w '%{http_code}' https://$h.home/)"; done

# storage
zpool status -x            # "all pools are healthy"
df -h / /srv/data
```

## Monthly (10 minutes)

| Check | Command | Healthy |
|---|---|---|
| ZFS pool & last scrub | `zpool status tank` | `ONLINE`, scrub completed recently with 0 errors |
| Disk space | `df -h / /srv/data` | < 80 % |
| Docker disk usage | `docker system df` | images not ballooning |
| Unused images | `docker image ls --filter dangling=true` | remove with `docker image prune` (images only — safe) |
| Dangling volumes | `docker volume ls -qf dangling=true` | empty — **inspect before deleting**: `docker volume inspect <v>` |
| Memory pressure | `docker stats --no-stream` | no container near its limit |
| OOM kills | `docker ps -q \| xargs docker inspect -f '{{.Name}} {{.State.OOMKilled}}' \| grep true` | none |
| Certificates | `echo \| openssl s_client -connect localhost:443 -servername cloud.home 2>/dev/null \| openssl x509 -noout -enddate` | far from expiry (renewed automatically) |
| Git in sync | `git -C /srv/docker/stacks status -sb` | `## main...origin/main`, clean |
| Portainer stacks | Portainer → Stacks · `scripts/portainer-stacks.py plan` | no unexpected "Limited" app stacks; plan shows no `+`, `~` or `?` lines |
| Backups | `journalctl -u homelab-backup.service -n 20` · `sudo scripts/backup.sh snapshots` | last night's run ended in `done`, no ERROR; external disk copied recently ([04](04-backup-and-restore.md)) |
| Updates waiting | Portainer / app UIs "new version" banners | plan with [03](03-update-images.md) |

## Expected state

* **Running:** traefik, step-ca, docker-socket-proxy, portainer, nextcloud (×5), paperless (×3),
  invidious (×3), podsync — plus whatever on-demand apps you started.
* **Stopped:** on-demand stacks you're not using.
* **Volumes:** essentially none — only anonymous cache volumes (e.g. Immich Redis) while running.
