# 01 · Start & stop apps

**Use when:** you want to use an on-demand app (Immich, Jellyfin, Navidrome, Kavita, Forgejo,
Picard, Yubal, Homepage) or free resources by stopping one.
**Risk:** 🟢 none — data lives in bind mounts and survives stop/start.

## From the phone (normal way)

1. Open **https://portainer.home** (or `https://<host-ip>:9001` if DNS is down).
2. **Stacks** → tap the stack.
3. **Start this stack** / **Stop this stack**.

What happens:

| Action | Effect | After a reboot |
|---|---|---|
| **Start** | `compose up` from Portainer's local clone (no GitHub needed) | comes back (`restart: unless-stopped`) — also after the daily 22:00 power-off |
| **Stop** | `compose down` — containers + project networks removed, data untouched | **stays off** (no containers exist) |

> The host powers off every day at 22:00 ([08](08-reboot-and-power.md#daily-backup--power-off-at-2200)):
> stop on-demand apps when you're done, or they start again on the next boot.
> Picard has write access to the music library — stop it when you're done tagging.
> Yubal downloads on a daily schedule (00:00 UTC) only while it is running.

## Restart a single container

Stacks → *stack* → click the container → **Restart**. Use this for "it's stuck", not for config
changes (those need [02 · Deploy a change](02-deploy-a-change.md)).

## Logs

Stacks → *stack* → container → **Logs** (toggle *Auto-refresh*, set *Lines* to ~200).

## From the shell (API, optional)

Needs an access token in `~/.config/portainer-api.hdr` (one line: `X-API-Key: ptr_…`, mode 600).

```bash
H="-H @$HOME/.config/portainer-api.hdr"; CA="--cacert /srv/docker/volumes/step-ca/certs/root_ca.crt"
# list stacks: Id, name, status (1 = active, 2 = inactive)
curl -s $CA $H https://portainer.home/api/stacks | python3 -c 'import json,sys;[print(s["Id"],s["Name"],s["Status"]) for s in json.load(sys.stdin)]'
# stop / start stack <ID>
curl -s $CA $H -X POST "https://portainer.home/api/stacks/<ID>/stop?endpointId=3"
curl -s $CA $H -X POST "https://portainer.home/api/stacks/<ID>/start?endpointId=3"
```

## Verify

```bash
docker ps --filter label=com.docker.compose.project=<stack> --format '{{.Names}} {{.Status}}'
curl -s $CA -o /dev/null -w '%{http_code}\n' https://<app>.home/    # 200/302 = up, 404 = stopped
```

A `404` from Traefik right after **Start** for up to ~1 minute is normal: Traefik picks up the new
container's labels a moment later.

## ⚠️ Don't

* Don't `docker compose up` an app from `/srv/docker/stacks/<app>` — Portainer owns it.
* Don't stop infra containers (`traefik`, `step-ca`, `docker-socket-proxy`, `portainer`) from
  Portainer unless you mean to take everything down.
