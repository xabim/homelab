# Migration: `ai-studio` stack → homelab `paperclip` stack

One-time procedure, **completed on 2026-11-10**. Kept as a record and for its rollback section.

**Before:** Portainer stack `ai-studio` (#14) deploys `stacks/ai-studio/docker-compose.yml`
from `github.com/xabim/ai-studio`; data in `/srv/docker/volumes/ai-studio/{paperclip,workspaces}`;
secrets in `…/paperclip/instances/default/.env`; image `ai-studio/paperclip:<tag>`.

**After:** Portainer stack `paperclip` deploys `paperclip/docker-compose.yml` from
`github.com/xabim/homelab`; data in `/srv/docker/volumes/paperclip/{home,workspaces}`;
secrets in `paperclip/.env.secrets`; image `homelab/paperclip:<tag>-pw<playwright>`.

Same Paperclip version, same database, same hostname (`paperclip.home`), same container
paths (`/paperclip`, `/workspaces`), so nothing stored in the database changes.
The `ai-studio-ci` stack (Forgejo Actions runner, `/srv/docker/volumes/ai-studio/ci-runner`)
is not touched.

Downtime: a few minutes. Every step marked **[approval]** needs the owner's go-ahead.

## 0. Quiesce

No agent run may be active: in Paperclip (or `scripts/studio status`) wait for active runs
to finish or cancel them. Agents that are *always on* or on a timer will start new runs as
soon as the stack is back: lock or pause them first if you don't want that.

## 1. Stop and back up **[approval]**

```bash
# Portainer: Stacks -> ai-studio -> Stop   (90 s grace: embedded PostgreSQL shuts down cleanly)
docker ps --filter name=ai-studio-paperclip-1 --format '{{.Status}}'   # must print nothing
sudo install -d -m 700 /srv/data/backups/paperclip-premigration
sudo tar -C /srv/docker/volumes/ai-studio -czf \
  /srv/data/backups/paperclip-premigration/ai-studio-$(date +%F-%H%M).tar.gz paperclip workspaces
sudo tar -tzf /srv/data/backups/paperclip-premigration/ai-studio-*.tar.gz | grep -c . # non-zero
```

This is a cold, consistent copy (database stopped), including `secrets/master.key`.

## 2. Secrets file (copy, no editing)

Paperclip's instance `.env` already holds every secret the stack needs. Copy it verbatim:

```bash
install -m 600 /srv/docker/volumes/ai-studio/paperclip/instances/default/.env \
  /srv/docker/stacks/paperclip/.env.secrets
cd /srv/docker/stacks && git status --short paperclip/   # .env.secrets must NOT appear
```

The instance `.env` stays in place with identical values (Paperclip only uses it for variables
the container does not already have). Key names must match `.env.secrets.example`.

## 3. Move the data (same filesystem: instant, reversible)

```bash
sudo install -d -o 1000 -g 1000 -m 750 /srv/docker/volumes/paperclip
sudo mv /srv/docker/volumes/ai-studio/paperclip   /srv/docker/volumes/paperclip/home
sudo mv /srv/docker/volumes/ai-studio/workspaces  /srv/docker/volumes/paperclip/workspaces
```

From now on, **do not start the old `ai-studio` stack**: it would initialise a new, empty
Paperclip at the old path.

## 4. Image (no rebuild needed)

`image/Dockerfile` has the same instructions as the ai-studio image, so re-tag it:

```bash
docker tag ai-studio/paperclip:sha-d69631b01b9c658f80bf8bed389863dce82643e1 \
           homelab/paperclip:sha-d69631b01b9c658f80bf8bed389863dce82643e1-pw1.64.1
```

(or `docker compose -p paperclip build paperclip` in this directory.)

## 5. Backup script **[approval]**

Applied in the same commit as this stack (`git log -p scripts/backup.sh`).

Switches the Paperclip handling in `scripts/backup.sh` from `ai-studio-paperclip-1` /
`ai-studio/paperclip/...` to `paperclip-paperclip-1` / `paperclip/home/...` and takes a fresh
`db:backup` dump at backup time.

## 6. Commit and push homelab **[approval]**

```bash
cd /srv/docker/stacks
git add paperclip stacks.toml README.md playbooks/README.md scripts/backup.sh
git commit -m "feat(paperclip): Paperclip as a shared homelab service"
git push
```

## 7. Deploy **[approval]**

```bash
# Old stack off Portainer first (removes its containers/networks, not bind-mounted data)
#   Portainer: Stacks -> ai-studio -> Delete
scripts/portainer-stacks.py plan     # "+ paperclip create"
scripts/portainer-stacks.py apply    # created stopped (on-demand)
# Portainer: Stacks -> paperclip -> Start
```

## 8. Verify

```bash
docker ps --filter label=com.docker.compose.project=paperclip --format '{{.Names}}\t{{.Status}}'
CA=/srv/docker/volumes/step-ca/certs/root_ca.crt
curl -fsS --cacert $CA https://paperclip.home/api/health | jq -c '{status,version}'
docker exec paperclip-paperclip-1 sh -c 'test -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" && echo no-api-key'
docker exec paperclip-paperclip-1 sh -c 'test -n "$CLAUDE_CODE_OAUTH_TOKEN" && echo claude-token-present'
```

Then sign in at https://paperclip.home: the AI Studio company, its 7 agents, projects and
issues must be there; check the agents' heartbeat settings are unchanged. Run
`sudo scripts/backup.sh` once and confirm the log line `dump paperclip` and a new
`paperclip-*.sql.gz` in `/srv/data/backups/nvme/volumes/paperclip/home/instances/default/data/backups/`.

## 9. Operator tooling in the ai-studio repository

Done in `xabim/ai-studio` (a370d81): `scripts/studio` defaults to this stack, the
`forgejo-runner` stack and `/srv/docker/volumes/paperclip`; no overrides needed.
The Forgejo runner moved the same way (homelab `forgejo-runner/`, data in
`/srv/docker/volumes/forgejo-runner`); the old Portainer stack `ai-studio-ci` is stopped
and can be deleted.

## Rollback

Before step 7 nothing is live: move the directories back and start `ai-studio` again.
After step 7:

```bash
# Portainer: Stacks -> paperclip -> Stop
sudo mv /srv/docker/volumes/paperclip/home       /srv/docker/volumes/ai-studio/paperclip
sudo mv /srv/docker/volumes/paperclip/workspaces /srv/docker/volumes/ai-studio/workspaces
# Re-create the ai-studio Portainer stack (repo github.com/xabim/ai-studio, path
# stacks/ai-studio/docker-compose.yml) and start it; revert scripts/backup.sh (git revert).
```

If data was damaged: stop everything and extract the step-1 tarball into
`/srv/docker/volumes/ai-studio/` instead.
