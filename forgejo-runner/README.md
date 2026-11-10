# Forgejo runner

[Forgejo Actions](https://forgejo.org/docs/latest/user/actions/) runner for repositories on
https://forgejo.home. On-demand: start it when you want CI, stop it afterwards.

| | |
|---|---|
| Image | `homelab/forgejo-runner:<RUNNER_VERSION>-pw<PLAYWRIGHT_VERSION>`: Playwright base (Node + Chromium) + `forgejo-runner` + git/ffmpeg/zip |
| Mode | jobs run in **host mode inside the container** (no Docker socket, no DinD, no privileges), capacity 1 |
| Label | `ai-studio-ci` (`runs-on: ai-studio-ci`) — kept for the existing workflows |
| Registration | org `studio` on Forgejo; stored in `/srv/docker/volumes/forgejo-runner/.runner` |
| Data | `/srv/docker/volumes/forgejo-runner`: `.runner`, `cache/` and `work/` (both rebuildable, excluded from backups) |

Host-mode jobs can read `.runner`. Register the runner on one organization only and never give
CI workflows secrets.

## Build the image

```bash
cd /srv/docker/stacks/forgejo-runner && docker compose -p forgejo-runner build runner
```

Rebuild after changing `RUNNER_VERSION`, `PLAYWRIGHT_VERSION` or `image/`. Keep
`PLAYWRIGHT_VERSION` equal to the projects' `@playwright/test` version.

## Register (once, or after losing `.runner`)

Forgejo → org `studio` → Settings → Actions → Runners → **Create new runner** (copy the token), then:

```bash
cd /srv/docker/stacks/forgejo-runner
docker compose -p forgejo-runner run --rm -it runner \
  forgejo-runner register --config /etc/forgejo-runner/config.yml
# instance: https://forgejo.home   token: <paste>   name: ai-studio-ci   labels: ai-studio-ci:host
```

## Operate

Portainer → Stacks → `forgejo-runner` → Start / Stop. Status: Forgejo → org settings → Runners
(`idle` = connected). Logs: `docker logs --since 10m forgejo-runner-runner-1`.

| Symptom | Check |
|---|---|
| Jobs stay *waiting* | runner stopped or offline; `runs-on` label matches `config/config.yml` |
| `x509: certificate signed by unknown authority` | the step-ca root mount (`/etc/ssl/homelab/root_ca.crt`) |
| Browser tests fail to launch | `PLAYWRIGHT_VERSION` differs from the project's `@playwright/test` |
