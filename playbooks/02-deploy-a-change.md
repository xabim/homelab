# 02 · Deploy a change to an app stack

**Use when:** you changed an app's `docker-compose.yml` or `.env` (labels, mounts, limits, env…).
**Risk:** 🟡 the stack restarts — **all** its containers are recreated, not only the changed one.
**Not for:** infra stacks → [06](06-infrastructure-stacks.md). Secrets → [07](07-secrets.md).

## Steps

1. **Edit** in `/srv/docker/stacks/<app>/`.
2. **Validate** locally:
   ```bash
   cd /srv/docker/stacks/<app> && docker compose config --quiet && echo OK
   ```
3. **Check you're not leaking anything** (the repo is public):
   ```bash
   cd /srv/docker/stacks && git status --short && git diff
   ```
4. **Commit and push:**
   ```bash
   git add <app>/ && git commit -m "feat(<app>): <what changed>" && git push
   ```
5. **Prepare the app** if it has state in flight:
   * **Nextcloud:** `docker exec -u www-data nextcloud php occ maintenance:mode --on`
   * **Databases:** take a dump first if the change touches the DB service → [04](04-backup-and-restore.md)
6. **Redeploy** in Portainer: Stacks → *app* → **Pull and redeploy**.
   * Leave **Re-pull image** **off** unless you also want an image update ([03](03-update-images.md)).
   * The redeploy runs in the background; a second click while it runs returns *"deployment already in progress"*.
7. **Nextcloud:** `docker exec -u www-data nextcloud php occ maintenance:mode --off`

## Verify

```bash
docker ps --filter label=com.docker.compose.project=<app> --format '{{.Names}} {{.Status}}'
docker inspect <container> --format 'restarts={{.RestartCount}}'
docker logs --since 5m <container> 2>&1 | grep -iE 'error|fatal' | head
curl -s $CA -o /dev/null -w '%{http_code}\n' https://<app>.home/
```

## Rollback

```bash
git revert HEAD && git push        # then Pull and redeploy again
```

## Special cases

| Stack | Gotcha |
|---|---|
| `invidious` | Its 3 secrets are **Portainer stack variables**. The UI keeps them; an **API** redeploy must resend them or they are wiped. |
| `immich` | `IMMICH_VERSION=v2` → *Re-pull image* updates within v2 only. v3 = change the tag + follow Immich's migration notes. |
| `nextcloud` | Always use maintenance mode; all 5 containers restart. |
| stopped on-demand stacks | Redeploying **starts** them — stop again afterwards if you don't need them. |
| `.env.secrets` path | Must be absolute (`/srv/docker/stacks/<app>/.env.secrets`) — Portainer's clone doesn't contain gitignored files. |
| relative bind mounts | `./something` breaks in Portainer CE (resolves inside Portainer's container). Use absolute paths. |
