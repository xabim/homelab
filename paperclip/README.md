# Paperclip

[Paperclip](https://github.com/paperclipai/paperclip) is a control plane for AI agent
"companies" (organizations). Agents here run [Claude Code](https://code.claude.com) on a
Claude **subscription**. This stack is **infrastructure only**: it runs Paperclip with zero,
one or many organizations, and contains nothing specific to any of them.

| | |
|---|---|
| URL | https://paperclip.home (internal only; step-ca TLS through Traefik) |
| Mode | on-demand (Portainer start/stop; stays off after a reboot) |
| Image | `homelab/paperclip:<PAPERCLIP_VERSION>-pw<PLAYWRIGHT_VERSION>`, built locally from the pinned upstream image |
| Database | embedded PostgreSQL inside the `paperclip` container |
| Containers | `paperclip-paperclip-1`, `paperclip-egress-proxy-1`, `paperclip-forgejo-gw-1`, `paperclip-ingress-1` |

## Who owns what

| Layer | Source of truth | Where |
|---|---|---|
| Paperclip deployment, persistence, networking, backups | this directory | `github.com/xabim/homelab` |
| Live organizations, agents, skills, projects, tasks, runs | **Paperclip's database** + `home/` | `/srv/docker/volumes/paperclip` |
| Versioned snapshots of stable organization configs | official Paperclip exports | Forgejo repo `paperclip-organizations` |
| Software projects | their own repositories | Forgejo |

Paperclip never reads the `paperclip-organizations` repository; exports and imports are
manual ([Organizations](#organizations)). Adding an organization needs no change here.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | the stack |
| `.env` | non-secret settings: versions, hostname, limits, agent git policy |
| `.env.secrets` | secrets (gitignored, mode 600); keys in `.env.secrets.example` |
| `image/Dockerfile` | upstream image + headless Chromium (Playwright) + ffmpeg/zip |
| `config/claude/` | Claude Code managed settings, mounted read-only into every agent run |
| `config/egress/` | squid config + the domain allowlist (the container's only way out) |

## Environment

`.env` (tracked): `PAPERCLIP_VERSION` (upstream image tag, pinned to a commit), `PLAYWRIGHT_VERSION`,
`PUID`/`PGID`, `PAPERCLIP_HOSTNAME`, `FORGEJO_HOSTNAME`, `PAPERCLIP_MEM_LIMIT`, `PAPERCLIP_CPUS`,
`AGENT_GIT_POLICY` (`review` | `commit` | `push`: which `config/claude/git-policy-*.json` is mounted).

`.env.secrets` (gitignored): `BETTER_AUTH_SECRET`, `PAPERCLIP_TOOL_ACTION_SIGNING_SECRET`,
`CLAUDE_CODE_OAUTH_TOKEN`, `FORGEJO_BOT_USER`, `FORGEJO_BOT_TOKEN`.

Paperclip-specific variables set in the compose file are documented upstream in
`docs/deploy/environment-variables.md` and `docs/deploy/docker.md`. Paperclip also loads
`home/instances/default/.env` itself, but only for variables **not** already set
(`override: false`), so `.env.secrets` wins.

> **Never set `ANTHROPIC_API_KEY`** (here, in `.env.secrets`, or in an agent's adapter env).
> Claude Code prefers it over the subscription token and bills the pay-as-you-go API.
> Also keep *extra usage* disabled in the Claude account.

## Persistent data

| Host path | Container | Contents |
|---|---|---|
| `/srv/docker/volumes/paperclip/home` | `/paperclip` | `PAPERCLIP_HOME`: `instances/default/{config.json, .env, db/, data/backups/, data/storage/, data/run-logs/, secrets/master.key, companies/, workspaces/}`, Claude Code state (`.claude/`, `.claude.json`) |
| `/srv/docker/volumes/paperclip/workspaces` | `/workspaces` | project checkouts and task worktrees used by agents |

`db/` is the live embedded PostgreSQL: **never copy it while the container runs** — use a dump.
`secrets/master.key` decrypts the secrets stored in the database: a DB backup without it
cannot restore them.

## Networking

Only the `ingress` relay joins the shared `proxy` network; Traefik terminates TLS
(`stepca` resolver) and forwards to it. The `paperclip` container sits on internal networks
only and reaches the outside world exclusively through `egress-proxy` (squid, allowlist in
`config/egress/allowlist.txt`: Anthropic, npm registry, `forgejo.home`). `forgejo-gw` lets
Paperclip *plugin* workers (which ignore proxy env vars) reach `https://forgejo.home` with
verified TLS; drop it if no Forgejo plugin is installed. No ports are published; there is no
external exposure.

DNS: `paperclip.home` → the host, in Pi-hole (exists already).

## Authentication

`PAPERCLIP_DEPLOYMENT_MODE=authenticated`, exposure `private`: sign in at
https://paperclip.home with the board account. Sessions are signed with
`BETTER_AUTH_SECRET` (rotating it signs everyone out). CLI/scripts use a board API key
obtained through Paperclip's CLI login approval flow; keep it out of shell history and repos.

Claude Code authenticates with `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`, one-year
subscription token). Agents' git uses the Forgejo bot token through an env-only credential
helper.

## Resource limits

`paperclip`: `${PAPERCLIP_MEM_LIMIT}` / `${PAPERCLIP_CPUS}` CPUs, 2048 pids, `oom_score_adj`
300 (it is killed before infrastructure), 90 s stop grace for the embedded database.
Sidecars use the `xsmall`/`small` tiers from [`resource-limits.yaml`](../resource-limits.yaml).

## Execution policy (read before starting agents)

Nothing in this stack starts an agent. Whether and when Claude Code runs is **per-agent
configuration in Paperclip's database**, per organization:

| Per-agent setting (`runtimeConfig.heartbeat`) | Effect |
|---|---|
| `enabled: false`, `intervalSec: 0` | no timer (periodic) wakes |
| `wakeOnDemand: false` | no assignment / comment / automation / API wakes, and scheduled retries are suppressed |
| `alwaysOn: true` | assignments and comments start runs immediately |
| `maxConcurrentRuns: 1` | one run **per agent** |
| `maxDailyRuns: n` | daily cap per agent |
| agent `status: paused` | no runs at all until resumed |

Limitations of the pinned version (`2026.1005.0+845`, verified in its source and docs):

* There is **no instance-wide switch** to disable the scheduler, and **no global limit** of
  one Claude execution across agents: with *n* awake agents, up to *n* runs can be active.
* There is no "manual-only, but keep a Run button" mode: the single `wakeOnDemand` flag gates
  every non-timer wake, including the UI/API run.
* Imports land with timer heartbeats disabled and (in the UI, by default) agents paused —
  but `alwaysOn` and wake-on-demand settings in the package are preserved and become live
  when the agent is resumed.
* Active runs are listed at `GET /api/companies/<id>/live-runs` and cancelled from the UI or
  `POST /api/heartbeat-runs/<run>/cancel`.

A strictly human-gated workflow therefore has to be kept at the organization level (every
agent locked, one run opened at a time). That is organization tooling, not part of this stack.

## Start / stop

Portainer → Stacks → `paperclip` → Start / Stop. CLI equivalent (same project name):

```bash
cd /srv/docker/stacks/paperclip
docker compose -p paperclip up -d --no-build     # start
docker compose -p paperclip stop                 # stop (90 s grace for PostgreSQL)
docker compose -p paperclip ps
curl -fsS --cacert /srv/docker/volumes/step-ca/certs/root_ca.crt https://paperclip.home/api/health | jq .status
```

## Build the image

The image is local (`pull_policy: never`), so build it on the host before the first deploy
and after changing `PAPERCLIP_VERSION`, `PLAYWRIGHT_VERSION` or `image/Dockerfile`:

```bash
cd /srv/docker/stacks/paperclip && docker compose -p paperclip build paperclip
```

## Update Paperclip

1. Read the upstream release notes/commits between the current and target tags (migrations,
   changed env vars, changed export format, changes to heartbeat/wake behaviour).
2. Take a backup (below) **with the stack stopped**, so `db/` is copied consistently as well.
3. Set `PAPERCLIP_VERSION` in `.env` to a commit-pinned tag (`sha-<commit>`), build the image.
4. Commit + push, then Portainer → Pull and redeploy. Paperclip applies DB migrations on start.
5. Verify: health `ok`, sign-in works, organizations/agents present, agent heartbeat settings
   unchanged, `docker exec paperclip-paperclip-1 sh -c 'test -z "$ANTHROPIC_API_KEY"'`.
6. Re-check that `node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts db:backup --help`
   still works in `/app` (the backup script calls it; it is what `pnpm paperclipai` runs).

Rollback: stop, restore `home/` from the pre-upgrade backup (migrations are not reversible),
set the old `PAPERCLIP_VERSION`, redeploy.

## Backups

Covered by the homelab nightly [`scripts/backup.sh`](../scripts/backup.sh) (22:00, then
mirrored to the external HDD by `backup-external.sh`):

| What | How |
|---|---|
| Database | if running: a fresh `paperclipai db:backup` dump into `home/instances/default/data/backups/`, live `db/` skipped; if stopped: `db/` copied as files |
| Hourly dumps | Paperclip writes them itself (`PAPERCLIP_DB_BACKUP_*`, 7 days), copied with `home/` |
| Master key, `config.json`, instance `.env`, uploads, run logs, Claude Code state | rsync of `/srv/docker/volumes/paperclip/home` → `/srv/data/backups/nvme/volumes/paperclip/home` |
| Workspaces | rsync of `/srv/docker/volumes/paperclip/workspaces` (uncommitted agent work lives here) |
| `.env.secrets`, compose, config | rsync of `/srv/docker/stacks` → `/srv/data/backups/nvme/stacks/` |

Organization exports in `paperclip-organizations` are **not** backups (no tasks, comments,
runs, costs, secrets or history).

## Restore

Option A — consistent file copy (backup taken while Paperclip was **stopped**, or a
pre-upgrade backup):

```bash
# Portainer: stop the paperclip stack
B=/srv/data/backups/nvme/volumes/paperclip
sudo mv /srv/docker/volumes/paperclip /srv/docker/volumes/paperclip.broken-$(date +%F)
sudo rsync -aH --numeric-ids $B/ /srv/docker/volumes/paperclip/
# Portainer: start the stack
```

Option B — from a SQL dump (backup taken while Paperclip was **running**: `db/` was skipped).
There is no `db:restore` CLI command in this version; the dump is restored the way Paperclip's
own worktree seeding does it (`resetPostgresDatabase` → `runDatabaseRestore` →
`applyPendingMigrations` from `@paperclipai/db`). Steps:

1. Stop the stack. Restore `home/` and `workspaces/` from the backup as in option A
   (this brings back `secrets/master.key`, `config.json` and the dumps; `db/` is absent).
2. Start the stack once: Paperclip initialises an **empty** embedded database in `db/`.
3. Restore the chosen dump into it from inside the container, before signing in (the
   empty DB has no agents, so nothing can run in between). The image has no `psql`, so the
   dump is passed uncompressed:

   ```bash
   D=paperclip-YYYYMMDD-HHMMSS          # newest file in home/instances/default/data/backups/
   cat > /tmp/pc-restore.ts <<'EOF'
   import { resetPostgresDatabase, runDatabaseRestore, applyPendingMigrations } from "./src/index.ts";
   const pg = "postgres://paperclip:paperclip@127.0.0.1:54329";
   await resetPostgresDatabase(`${pg}/postgres`, "paperclip");
   await runDatabaseRestore({ connectionString: `${pg}/paperclip`, backupFile: process.argv[2] });
   await applyPendingMigrations(`${pg}/paperclip`);
   console.log("restored");
   EOF
   docker exec -i paperclip-paperclip-1 sh -c 'cat > /app/packages/db/pc-restore.ts' < /tmp/pc-restore.ts
   docker exec -w /app/packages/db paperclip-paperclip-1 sh -c "
     gunzip -c /paperclip/instances/default/data/backups/$D.sql.gz > /tmp/restore.sql &&
     node /app/server/node_modules/tsx/dist/cli.mjs pc-restore.ts /tmp/restore.sql;
     rm -f /tmp/restore.sql pc-restore.ts"
   ```

4. Restart the stack (Portainer → Stop/Start).

Verify a restored instance: health `ok`; sign in; organizations, agents, issues present;
company secrets resolve (proves `master.key` matches); agents' heartbeat settings are what you
expect **before** anything is resumed; `GET /api/companies/<id>/live-runs` shows no
leftover queued/running runs (cancel them with `POST /api/heartbeat-runs/<run>/cancel`).

**Verification status (2026-11-10):** option B was rehearsed end to end on a copy of the
pre-migration backup (`db/` removed, dump `paperclip-20261110-174257`), with these exact
commands, in a network-isolated throwaway container: restore and migrations clean, then
1 company, 7 agents, 28 issues, no leftover runs, `local_encrypted` secrets provider `ok`
with the restored `master.key`. Option A is a plain file copy of a stopped instance.

## Organizations

Create and edit organizations in the Paperclip UI. To version a stable configuration, export
it (UI: company settings → Export, or `POST /api/companies/<id>/export`), review it for
secrets, and commit it to `paperclip-organizations`; that repository documents the workflow.
Import (UI: company settings → Import, or `paperclipai company import`) creates or merges an
organization from such a package; it never runs automatically.

## Egress allowlist

Edit `config/egress/allowlist.txt`, then:

```bash
docker exec paperclip-egress-proxy-1 squid -k parse && docker exec paperclip-egress-proxy-1 squid -k reconfigure
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `unhealthy` / slow start | `docker logs --since 10m paperclip-paperclip-1`; startup recovery and migrations can take minutes (start period 180 s) |
| 404/502 at paperclip.home | `docker ps --filter name=paperclip-ingress`; Traefik dashboard router `paperclip`; DNS record |
| Agent run: network error | squid log: `docker exec paperclip-egress-proxy-1 tail /var/log/squid/access.log` (`TCP_DENIED` = not allowlisted) |
| Claude Code `401` / login prompt | `CLAUDE_CODE_OAUTH_TOKEN` expired or missing in `.env.secrets` → regenerate, redeploy |
| git push to Forgejo refused | bot token scope, `AGENT_GIT_POLICY`, Forgejo branch protection |
| `pull access denied for homelab/paperclip` | the image was not built on the host ([Build the image](#build-the-image)) |
| Backup log `paperclip db:backup failed` | run the command from the script by hand in the container; the hourly dumps are still copied |
| Disk use grows | `du -sh /srv/docker/volumes/paperclip/*/`; old worktrees in `workspaces/`, run logs in `home/instances/default/data/run-logs` |
