# 06 · Infrastructure stacks (Traefik, step-ca, socket proxy, Portainer)

**Use when:** changing routing, TLS, Docker API access or Portainer itself.
**Risk:** 🔴 Traefik or step-ca down = **every** `*.home` URL down. Do it when nobody is using the services.

These four stacks are **CLI-managed on purpose**: they must not depend on Portainer or GitHub.
In Portainer they show as *Limited* — fine for logs and restarts, never edit them there.

| Stack | Config in Git | Config outside Git |
|---|---|---|
| `traefik` | `traefik/docker-compose.yml`, `.env`, `plugins-local/` (down-page plugin) | `/srv/docker/volumes/traefik/traefik.yml` (static), `dynamic/*.yml` (hot-reloaded), `certs/` |
| `step-ca` | `step-ca/docker-compose.yml`, `.env` | `/srv/docker/volumes/step-ca/` (CA keys — **back up, never commit**) |
| `docker-socket-proxy` | `docker-socket-proxy/docker-compose.yml`, `.env` (API permissions) | — |
| `portainer` | `portainer/docker-compose.yml`, `.env` | `/srv/docker/volumes/portainer/data` (stacks, users, tokens) |

## Change Traefik routes without a restart

Files in `/srv/docker/volumes/traefik/dynamic/` are watched — save and Traefik reloads.

```bash
cp -a /srv/docker/volumes/traefik/dynamic /srv/data/backups/traefik-dynamic-$(date +%Y%m%d)
$EDITOR /srv/docker/volumes/traefik/dynamic/<file>.yml
docker logs --since 1m traefik 2>&1 | grep ERR
```

Dynamic files are rendered as Go templates: a literal `{{` breaks **all** of them (`function "…" not defined`).

## Change compose / static config (restart needed)

```bash
cd /srv/docker/stacks/<stack>
$EDITOR docker-compose.yml               # or /srv/docker/volumes/traefik/traefik.yml
docker compose config --quiet && docker compose up -d
```

Traefik restart ≈ 5 s of downtime. Errors like *"service X@docker does not exist"* in the first
second after start are normal (Docker provider still loading), and so are errors for port routers
of **stopped** on-demand stacks.

Commit compose changes afterwards (`git add <stack>/ && git commit && git push`).

## Update an infra image

1. Bump the version (`traefik/docker-compose.yml` image, `PORTAINER_VERSION` in `portainer/.env`,
   `STEP_CA_VERSION`/`DOCKER_SOCKET_PROXY_VERSION` in the `.env`).
2. **Portainer:** back up `/srv/docker/volumes/portainer/data` first — its DB migrates one-way:
   ```bash
   docker run --rm -v /srv/docker/volumes/portainer/data:/d:ro -v /srv/data/backups:/b alpine:3 \
     tar -C /d -czf /b/portainer-data-$(date +%Y%m%d).tar.gz .
   ```
3. `docker compose pull && docker compose up -d` in the stack directory.
4. Verify: `docker ps`, `https://portainer.home`, a few app URLs.
5. Commit, push.

## Verify everything after infra work

```bash
CA="--cacert /srv/docker/volumes/step-ca/certs/root_ca.crt"
for h in portainer cloud office paperless podsync invidious; do
  printf '%-10s %s\n' $h "$(curl -s $CA -o /dev/null -w '%{http_code}' https://$h.home/)"; done
curl -s $CA https://ca.home:9000/health
```

## Socket proxy permissions

`docker-socket-proxy/.env` is read-only by design (`GET=1`, `POST=0`, `DELETE=0`, `EXEC=0`).
Only Traefik and Homepage use it. **Don't** open write permissions — Portainer has its own socket mount.
