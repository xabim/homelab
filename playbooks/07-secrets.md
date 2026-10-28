# 07 · Secrets

**Use when:** adding, changing or rotating a password/key/token.
**Risk:** 🟡 the affected app restarts; a wrong DB password = app can't connect.

> 🌍 **The GitHub repo is public.** Secrets go **only** in `<app>/.env.secrets` (gitignored) or in
> Portainer stack variables. Never in `.env`, compose files, commit messages or Homepage config.

## Where secrets live

| Mechanism | Used by | Read by |
|---|---|---|
| `/srv/docker/stacks/<app>/.env.secrets` (mode 600) | all apps | Portainer, via its read-only mount of `/srv/docker/stacks`, passed to the container as env vars |
| Portainer stack variables | **invidious only** (`POSTGRES_PASSWORD`, `SERVER_SECRET_KEY`, `HMAC_KEY`) | Compose interpolation into `INVIDIOUS_CONFIG` |
| `immich/.secrets` | `immich/import-immich.sh` (`IMMICH_TOKEN`) | the script only |
| `~/.config/portainer-api.hdr` | shell automation | `curl -H @file` |

Why two mechanisms: values in `env_file` reach the **container**, but `${VAR}` placeholders in the
compose file are filled from `.env` / Portainer variables only.

## Add or change a secret

```bash
cd /srv/docker/stacks/<app>
$EDITOR .env.secrets                  # KEY=value, no quotes needed
stat -c '%a %U' .env.secrets          # must be 600 xabim
git status --short                    # must NOT list .env.secrets
```

Then Portainer → Stacks → *app* → **Pull and redeploy** (re-reads the file, recreates containers).

## Rotate a database password

The DB keeps the password it was **initialised** with — changing `POSTGRES_PASSWORD` alone does nothing.

```bash
docker exec -it <db-container> psql -U <user> -d <db> -c "ALTER USER <user> WITH PASSWORD '<new>';"
# update the same value in .env.secrets (both POSTGRES_PASSWORD and the app's DB password key), then redeploy
```

## Invidious

Change the value in **both** places:

1. `invidious/.env.secrets` (used by the companion and the DB container)
2. Portainer → Stacks → invidious → **Environment variables** → edit the value → redeploy the stack

If you redeploy Invidious through the API, include all three variables in the `env` array —
an empty array **wipes** them. `scripts/portainer-stacks.py redeploy invidious` does this for you
(it reads them from `invidious/.env.secrets`), so keep that file and Portainer in sync.

## Portainer API token

Portainer → user menu → **My account → Access tokens**. Store as
`X-API-Key: ptr_…` in `~/.config/portainer-api.hdr`, mode 600. Revoke there when not needed.
