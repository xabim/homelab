# 05 · Add a new service

**Use when:** deploying an app that isn't here yet.
**Risk:** 🟡 only the new app — as long as it uses its own names, paths and networks.

## 1. Decide

* **Hostname:** `<app>.home` · **Mode:** always-on or on-demand
* **Size tier / role** from [`resource-limits.yaml`](../resource-limits.yaml) (see README tables)
* **Where data goes:** small config/DB → `/srv/docker/volumes/<app>/`; bulk → `/srv/data/<app>/`

## 2. Create the stack

```bash
cd /srv/docker/stacks && mkdir <app>
cp docker-compose.traefik.yml <app>/docker-compose.yml   # or docker-compose.db.yml / docker-compose.socket.yml
install -m 600 /dev/null <app>/.env.secrets
```

The templates are **snippets**: paste the anchors you use from `resource-limits.yaml` at the top.
Start the file with the standard header:

```yaml
# =============================================================================
# <App> - <one-line purpose>
#
# Mode:  on-demand (start/stop from Portainer; stays off after reboot)
# URL:   https://<app>.home
# Data:  /srv/docker/volumes/<app>/...
# Deploy: Portainer Git stack from github.com/xabim/homelab (main)
# =============================================================================
```

Rules (Portainer CE compatibility):

* `env_file`: `../.env.global`, `.env`, and **`/srv/docker/stacks/<app>/.env.secrets`** (absolute)
* Bind mounts: **absolute paths only** — `./x` breaks in Portainer CE
* If the image declares `VOLUME`s (`docker image inspect -f '{{json .Config.Volumes}}' <image>`),
  bind every one that holds state — otherwise Stop/Start throws that state away
* `${VAR}` inside `environment:` is interpolated from `.env` only — **not** from `.env.secrets`.
  If a secret must be interpolated, use a Portainer stack variable (see Invidious)
* Networks: `proxy` (external) for Traefik; a private network for app ↔ DB

## 3. Validate

```bash
cd /srv/docker/stacks/<app> && docker compose config --quiet && echo OK
git -C /srv/docker/stacks status --short     # .env.secrets must NOT appear
```

## 4. DNS

Pi-hole (`https://<pihole-ip>/admin`) → **Local DNS → DNS Records** → `<app>.home` → `<host-ip>`.

## 5. Commit, push, deploy

```bash
git add <app>/ && git commit -m "feat(<app>): add new service" && git push
```

Portainer → **Stacks → Add stack**:

* Name: **`<app>`** (= directory name = Compose project name)
* Build method: **Repository** → `https://github.com/xabim/homelab`, reference `refs/heads/main`,
  compose path `<app>/docker-compose.yml`
* GitOps updates: **off** · Environment variables: none (unless needed, see above)
* **Deploy the stack**

## 6. Verify

```bash
docker ps --filter label=com.docker.compose.project=<app>
curl -s $CA -o /dev/null -w '%{http_code}\n' https://<app>.home/
docker logs --since 5m <container> 2>&1 | tail -20
```

## 7. Finish

* Optional IP fallback: add an entrypoint in `/srv/docker/volumes/traefik/traefik.yml`, a router in
  `dynamic/port-routing.yml`, and publish the port in `traefik/docker-compose.yml` (Traefik restart → [06](06-infrastructure-stacks.md)).
* Add a tile to Homepage: `/srv/docker/volumes/homepage/config/services.yaml` (root-owned — edit via a container or `sudo`).
* Add the app to the README service catalog and to [`playbooks/README.md`](README.md#stack-reference).
* On-demand? **Stop** it in Portainer when done.

## Remove a service

1. Back up its data ([04](04-backup-and-restore.md)).
2. Portainer → Stacks → *app* → **Delete** (removes containers, not bind-mounted data).
3. `git rm -r <app>` + remove from README/Homepage/port-routing → commit, push.
4. Delete its data directories only when you're sure.
