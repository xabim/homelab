# 09 · Troubleshooting

**Rule:** look before you touch. Everything in *Diagnose* is read-only.

```bash
CA="--cacert /srv/docker/volumes/step-ca/certs/root_ca.crt"
```

## Diagnose

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | sort
docker ps -a --filter status=restarting --filter status=exited --format '{{.Names}} {{.Status}}'
docker logs --since 10m <container> 2>&1 | tail -50
docker inspect <container> --format 'restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}'
getent hosts <app>.home                        # DNS
curl -sv $CA https://<app>.home/ -o /dev/null  # TLS + HTTP
docker logs --since 10m traefik 2>&1 | grep -i <app>
```

## Symptom → cause

| Symptom | Likely cause | Fix |
|---|---|---|
| `404 page not found` (Traefik) | Stack stopped, or container just started | Start it ([01](01-start-stop-apps.md)); wait ~1 min after start |
| `Could not resolve host` / `ENOTFOUND` | No Pi-hole record (`traefik.home` has none, use `:9004`) | Add record in Pi-hole |
| Certificate error / self-signed warning | Client doesn't trust the root CA, or ACME failed for a new host | Install `root_ca.crt` on the client; check `docker logs traefik \| grep -i acme` (needs DNS for the name) |
| `502 Bad Gateway` | App container up but not listening (still booting / crashed) | `docker logs <app>`; check `loadbalancer.server.port` label |
| Container `Restarting` loop | Bad config, DB unreachable, wrong secret | Logs; `docker compose config` in the app dir; check `.env.secrets` |
| `OOMKilled=true` | Hit `mem_limit` | Raise the tier in the compose file → [02](02-deploy-a-change.md) |
| Portainer deploy: *env file … not found* | `.env.secrets` referenced relatively or missing | Use the absolute path; check the file exists |
| Portainer deploy: bind mount path doesn't exist | Relative `./path` in compose | Use an absolute path |
| Portainer: *Stack deployment is already in progress* | A previous deploy is still running (async) | Wait, refresh |
| Portainer stack status stuck "deploying" | Long image pull | Watch `docker events` / container list; it settles |
| Nextcloud shows maintenance page | Maintenance mode left on | `docker exec -u www-data nextcloud php occ maintenance:mode --off` |
| Nextcloud "untrusted domain" | Accessed by IP | Use `https://cloud.home` |
| Invidious: *Companion is starting… potoken* forever | Images too old for YouTube | Pull and redeploy with **Re-pull image** ([03](03-update-images.md)) |
| Invidious DB auth errors | Stack variables wiped by an API redeploy | Re-add the 3 variables ([07](07-secrets.md#invidious)) |
| Kavita shows setup wizard | Config not mounted at `/config` | Check mount: `docker inspect kavita --format '{{json .Mounts}}'` |
| Everything down | Traefik or step-ca down | `docker ps \| grep -E 'traefik\|step-ca'`; `cd /srv/docker/stacks/traefik && docker compose up -d` |
| Can't reach Portainer | Portainer container down | `cd /srv/docker/stacks/portainer && docker compose up -d` |

## Escape hatch

If Portainer is broken and an app must run **now**, see
[10 · Disaster recovery → run an app without Portainer](10-disaster-recovery.md#run-an-app-without-portainer).
