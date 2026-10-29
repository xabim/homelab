<div align="center">

# 🏠 Homelab

**A small, boring-on-purpose home server.**
Docker Compose stacks, managed from a phone with Portainer, deployed from Git,
with real TLS on every service and resource limits on every container.

![Debian](https://img.shields.io/badge/Debian-13-A81D33?logo=debian&logoColor=white)
![Docker](https://img.shields.io/badge/Docker_Compose-v2-2496ED?logo=docker&logoColor=white)
![Portainer](https://img.shields.io/badge/Portainer_CE-2.45-13BEF9?logo=portainer&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-v3.7-24A1C1?logo=traefikproxy&logoColor=white)
![step-ca](https://img.shields.io/badge/PKI-step--ca-EB6100?logo=letsencrypt&logoColor=white)
![ZFS](https://img.shields.io/badge/Storage-ZFS_mirror-2A6DB0)
![Stacks](https://img.shields.io/badge/stacks-16-brightgreen)

</div>

---

> **Design goal:** a single app failure must never take down the host —
> and turning an app on or off should take one tap.
>
> **Rebuild philosophy:** Git + rsync, nothing more. The repo says how the server is built;
> plain-file copies hold what it stores. No Ansible, no backup software, no extra daemons —
> this repo and one external disk are enough to rebuild from scratch.

<details>
<summary><b>📑 Contents</b></summary>

- [At a glance](#-at-a-glance)
- [Architecture](#-architecture)
- [Service catalog](#-service-catalog)
- [How a change reaches production](#-how-a-change-reaches-production)
- [Repository layout](#-repository-layout)
- [Secrets](#-secrets)
- [TLS & internal PKI](#-tls--internal-pki)
- [Networking & DNS](#-networking--dns)
- [Resource limits & OOM policy](#-resource-limits--oom-policy)
- [Container hardening](#️-container-hardening)
- [Storage & data safety](#-storage--data-safety)
- [Adding a service](#-adding-a-service--checklist)
- [Documentation & playbooks](#-documentation--playbooks)

</details>

## ✨ At a glance

| | |
|---|---|
| 🖥️ **Host** | A single Debian box · NVMe for OS, configs and databases · ZFS mirror for bulk data (`/srv/data`) |
| 📦 **Stacks** | 12 app stacks managed by **Portainer** (from this repo on GitHub) + 4 infrastructure stacks managed by CLI |
| 🔐 **TLS** | Internal CA (**step-ca**) issues 30-day certificates to **Traefik** over ACME — every `*.home` URL is real HTTPS · [deep dive](docs/tls.md) |
| 🌐 **DNS** | **Pi-hole** on a separate device resolves `*.home` → the host |
| 📱 **Ops** | Start/stop/logs/restart from a phone at `https://portainer.home` |
| ⏻ **Power** | Every day at **22:00** (Spanish time) it backs up the NVMe, then powers off · switched on by hand or Wake-on-LAN · [playbook 08](playbooks/08-reboot-and-power.md#daily-backup--power-off-at-2200) |
| 📖 **Runbooks** | Everything operational lives in [`playbooks/`](playbooks/README.md) |

---

## 🧭 Architecture

```mermaid
flowchart LR
    user(["📱 Phone / 💻 Laptop"])
    pihole["Pi-hole<br/><i>*.home → host</i>"]
    github[("GitHub<br/>xabim/homelab")]

    subgraph host["Debian host"]
        direction LR
        traefik["Traefik<br/>:443 + :900x"]
        stepca["step-ca<br/>ACME CA"]
        proxy["docker-socket-proxy<br/><i>read-only API</i>"]
        portainer["Portainer CE"]
        sock[["/var/run/docker.sock"]]

        subgraph apps["Portainer Git stacks"]
            direction TB
            always["Always-on<br/>Nextcloud · Paperless<br/>Podsync · Invidious"]
            ondemand["On-demand<br/>Immich · Jellyfin · Navidrome · Kavita<br/>Forgejo · Picard · Yubal · Homepage"]
        end
    end

    user -- DNS --> pihole
    user -- HTTPS --> traefik
    traefik -- "certs (ACME)" --> stepca
    traefik -- "labels (GET)" --> proxy
    proxy --- sock
    portainer -- "full API" --- sock
    portainer -- "clone on deploy" --> github
    traefik --> apps
    traefik --> portainer
```

**Two kinds of stacks, on purpose:**

| Layer | Stacks | Managed by | Why |
|---|---|---|---|
| **Infrastructure** | `traefik`, `step-ca`, `docker-socket-proxy`, `portainer` | `docker compose` (CLI, from this directory) | Routing and TLS must never depend on Portainer or GitHub being reachable. Portainer must not manage itself. |
| **Applications** | everything else | **Portainer Git stacks** (`main` branch, auto-update **off**), listed in [`stacks.toml`](stacks.toml) | One-tap start/stop from a phone; Git is the single source of truth — including which stacks exist. |

---

## 📋 Service catalog

| Service | URL | Mode | Stack | Direct IP fallback |
|---|---|---|---|---|
| 🎬 [Jellyfin](https://jellyfin.org) | https://jellyfin.home | on-demand | `jellyfin` | `:9002` |
| 🎵 [Navidrome](https://www.navidrome.org) | https://music.home | on-demand | `navidrome` | — |
| 📺 [Invidious](https://invidious.io) | https://invidious.home | always-on | `invidious` | `:9005` |
| 🎙️ [Podsync](https://github.com/mxpv/podsync) | https://podsync.home | always-on | `podsync` | `:9010` |
| ☁️ [Nextcloud](https://nextcloud.com) + [ONLYOFFICE](https://www.onlyoffice.com) | https://cloud.home · https://office.home | always-on | `nextcloud` | — (hard-redirects to its domain) |
| 📸 [Immich](https://immich.app) | https://immich.home | on-demand | `immich` | `:9008` |
| 📄 [Paperless-ngx](https://docs.paperless-ngx.com) | https://paperless.home | always-on | `paperless` | `:9006` |
| 📚 [Kavita](https://www.kavitareader.com) | https://books.home | on-demand | `kavita` | — |
| 🦊 [Forgejo](https://forgejo.org) | https://forgejo.home | on-demand | `forgejo` | — |
| 🏷️ [MusicBrainz Picard](https://picard.musicbrainz.org) | https://picard.home | on-demand | `musicbrainz-picard` | — |
| 🎧 [Yubal](https://github.com/guillevc/yubal) | https://yubal.home | on-demand | `yubal` | — |
| 🧭 [Homepage](https://gethomepage.dev) | https://homepage.home | on-demand | `homepage` | `:9003` |
| 🐳 [Portainer](https://www.portainer.io) | https://portainer.home | infra | `portainer` (CLI) | `:9001` |
| 🚦 [Traefik](https://traefik.io/traefik/) dashboard | — (no DNS record) | infra | `traefik` (CLI) | `:9004` |
| 🔏 [step-ca](https://smallstep.com/docs/step-ca/) | https://ca.home:9000 | infra | `step-ca` (CLI) | `:9000` |
| 🛡️ [Pi-hole](https://pi-hole.net) | on its own IP, `/admin` | external | — (other device) | — |

> Every app compose file starts with a header (purpose, mode, URL, data, notes) —
> visible in Portainer under **Stacks → *app* → Editor**.

---

## 🔁 How a change reaches production

```mermaid
sequenceDiagram
    participant You
    participant Repo as /srv/docker/stacks (git)
    participant GH as GitHub
    participant P as Portainer
    participant D as Docker

    You->>Repo: edit <app>/docker-compose.yml
    You->>Repo: docker compose config --quiet
    You->>GH: git commit && git push
    You->>P: Stacks → app → Pull and redeploy
    P->>GH: fetch main
    P->>D: compose up (recreates the stack's containers)
```

* **Start / Stop** use Portainer's local clone — they work even if GitHub is down.
* **Stop** = `compose down`: containers and project networks are removed, bind-mounted data is untouched.
  A stopped stack therefore **stays off after a reboot**.
* **Pull and redeploy** recreates **all** containers of the stack, not just the changed ones.

👉 Step by step: [`playbooks/02-deploy-a-change.md`](playbooks/02-deploy-a-change.md)

---

## 📂 Repository layout

```text
/srv/docker/stacks/                 ← this repo (github.com/xabim/homelab)
├── README.md
├── docs/                           ← deep dives (TLS & PKI) + restore guide copied to the HDD
├── playbooks/                      ← operational runbooks
├── .env.global                     ← TZ, PUID/PGID, base paths (shared by all stacks)
├── resource-limits.yaml            ← reference copy of the resource anchors
├── stacks.toml                     ← the Portainer Git stacks and their mode (always-on / on-demand)
├── scripts/portainer-stacks.py     ← plan / apply / redeploy those stacks via the Portainer API
├── scripts/backup.sh               ← daily 22:00 (then power-off) or by hand: DB dumps + rsync of the NVMe → ZFS
├── scripts/backup-external.sh      ← by hand: mirror /srv/data to the external HDD
├── host/bootstrap.sh               ← idempotent host setup: packages, daemon.json, ZFS, timers, networks, infra
├── host/systemd/                   ← 22:00 backup + power-off timer (installed by bootstrap.sh)
├── docker-compose.{traefik,db,socket}.yml   ← snippet templates for new services
├── prompt.md                       ← AI-assistant prompt for adding services
└── <stack>/
    ├── docker-compose.yml          ← the stack (header comment explains it)
    ├── .env                        ← non-secret variables (tracked — repo is public!)
    └── .env.secrets                ← secrets, mode 600, gitignored

/srv/docker/volumes/<app>/          ← configs + databases (NVMe, not in Git)
/srv/data/<app>/                    ← bulk data: media, photos, files (ZFS mirror)
```

> ⚠️ **The GitHub repo is public.** `.env` files and compose files are world-readable;
> anything secret goes in `.env.secrets` (gitignored) — never anywhere else.

---

## 🔐 Secrets

* Every stack references its secrets by **absolute path**:
  `- /srv/docker/stacks/<app>/.env.secrets`
* Portainer has `/srv/docker/stacks` mounted **read-only at the same path**, so Git stacks
  (which run from a clone without gitignored files) can still read them.
* **Exception — Invidious:** its secrets are interpolated into `INVIDIOUS_CONFIG`, so they are
  **Portainer stack variables** (`POSTGRES_PASSWORD`, `SERVER_SECRET_KEY`, `HMAC_KEY`).

👉 [`playbooks/07-secrets.md`](playbooks/07-secrets.md)

---

## 🔏 TLS & internal PKI

The most interesting piece of the infrastructure: a **private Certificate Authority** issuing real,
short-lived certificates — fully automated, like Let's Encrypt, but on the LAN.

```mermaid
flowchart LR
    subgraph pki["step-ca · ca.home:9000"]
        root["🏛️ Root CA<br/><i>until 2035</i>"] -- signs --> inter["🏢 Intermediate CA<br/><i>until 2035</i>"]
        acme["ACME provisioner<br/><code>traefik-acme</code><br/>30-day certs"]
        inter --- acme
    end
    traefik["🚦 Traefik<br/>ACME client<br/><code>acme-stepca.json</code>"]
    pihole["Pi-hole<br/>*.home → host"]
    device["💻📱 Devices<br/>trust the root"]

    traefik -- "1 · order cert for app.home" --> acme
    acme -- "2 · resolve app.home" --> pihole
    acme -- "3 · HTTP-01 check on :80" --> traefik
    acme -- "4 · signed leaf (30 d)" --> traefik
    device -- "HTTPS app.home" --> traefik
    device -. "chain verifies to" .-> root
```

| | |
|---|---|
| **CA** | step-ca, root + intermediate *marxa CA* (valid until 2035-12-25) |
| **Protocol** | ACME, HTTP-01 challenge on Traefik's `:80` entrypoint |
| **Leaf lifetime** | 30 days, renewed automatically by Traefik |
| **Trust anchor** | `/srv/docker/volumes/step-ca/certs/root_ca.crt` — install it once per device |
| **Golden rule** | a hostname needs a **Pi-hole record before** it can get a certificate |

📖 **How it works, end to end:** [`docs/tls.md`](docs/tls.md) ·
🛠️ **Tasks** (trust a device, inspect, add a host, troubleshoot, back up the CA):
[`playbooks/12-tls-certificates.md`](playbooks/12-tls-certificates.md)

---

## 🌐 Networking & DNS

```text
 client ──DNS──► Pi-hole: *.home → host IP
 client ──443──► Traefik ──(Host rule from container labels)──► app container
```

* **Networks:** `proxy` (Traefik ↔ apps) and `dockersock` (socket proxy) are **external** —
  created once by hand, never touched by stack operations. Each multi-container app also gets
  its own private network (`immich_immich`, `nextcloud_internal`, `paperless_default`, …).
* **Routing:** declared per service with Traefik labels — ``Host(`app.home`)``, `websecure`,
  `certresolver=stepca`.
* **Trusting the CA:** containers that call other `*.home` services mount the root
  (or use `NODE_EXTRA_CA_CERTS` for Node apps) — see [docs/tls.md § 5](docs/tls.md#5-who-trusts-the-root).
* **Port fallback:** Traefik publishes `:9001`–`:9006`, `:9008` and `:9010` for access by IP when DNS is down
  (routers in `/srv/docker/volumes/traefik/dynamic/port-routing.yml`).
* **Stopped service:** a lowest-priority catch-all router (`dynamic/fallback.yml`) answers any host
  with no live router with a 503 page linking to Portainer — rendered inside Traefik by the local
  plugin in `traefik/plugins-local/` (no extra container). Dynamic files are Go templates, so the
  page uses `%HOST%`, never `{{…}}`.
* **New hostname?** Add it to Pi-hole — Traefik and step-ca do the rest.
* **IP fallback ports** serve Traefik's default certificate (no hostname to match) — expect a browser warning there.

### Docker API access

| Consumer | Access | Via |
|---|---|---|
| Traefik, Homepage | read-only (`GET`) | `tcp://docker-socket-proxy:2375` on `dockersock` |
| Portainer | full (deploy, start/stop, exec) | `/var/run/docker.sock` mounted directly |

Portainer is the **only** application allowed to mount the socket: it needs write access, and a
write-enabled proxy would be equally powerful while exposing more to the other proxy clients.

---

## 📐 Resource limits & OOM policy

Every service has hard limits. Compose can't share YAML anchors across files, so each
`docker-compose.yml` copies the anchors it needs from [`resource-limits.yaml`](resource-limits.yaml).

| Tier | Memory limit | Reservation | CPUs | PIDs |
|---|---:|---:|---:|---:|
| `xsmall` | 128 MB | 32 MB | 0.25 | 128 |
| `small` | 256 MB | 64 MB | 0.5 | 256 |
| `medium` | 512 MB | 128 MB | 1.0 | 512 |
| `large` | 1 GB | 256 MB | 2.0 | 1024 |
| `xlarge` | 2 GB | 512 MB | 4.0 | 2048 |

| Role | `oom_score_adj` | Stop grace | Used for |
|---|---:|---:|---|
| `core` | −400 | 60 s | Traefik, step-ca, socket proxy |
| `cache` | −200 | 20 s | Redis |
| `db` | −100 | 60 s | PostgreSQL |
| `service` | +200 | 30 s | web apps |
| `worker` | +300 | 45 s | background workers |
| `batch` | +500 | 120 s | long batch jobs |

```yaml
services:
  myapp:
    <<: [*resource_medium, *resource_service]
```

Under memory pressure the kernel sacrifices apps first and keeps routing, TLS and databases alive.
A swap partition gives it room to breathe before that.

**Forbidden:** `deploy.resources` (Swarm-only, silently ignored) · containers without limits ·
mounting the Docker socket in apps (Portainer excepted) · anonymous volumes for data that matters.

---

## 🛡️ Container hardening

```yaml
security_opt: [no-new-privileges:true]
cap_drop: [ALL]
cap_add: [<only what the image needs>]
read_only: true          # where the image allows it, with tmpfs for /tmp and /run
```

When an image can't cope with `cap_drop: ALL` (Forgejo, Picard, Portainer), the compose file says
so in a comment.

---

## 💾 Storage & data safety

| Where | What | Protected by |
|---|---|---|
| `/srv/data` (ZFS mirror `tank/data`) | media, photos, Nextcloud files, books, documents, Git repos | mirror redundancy + monthly scrub (`zfs-scrub-monthly@tank.timer`, catches up after downtime) |
| `/srv/docker/volumes` (NVMe) | configs + **all PostgreSQL databases** | `scripts/backup.sh` (daily at 22:00 before the host powers off, or by hand): DB dumps + rsync → `/srv/data/backups/nvme` |
| `/srv/docker/stacks` | compose files, scripts, docs + `.env.secrets` | Git + GitHub; secrets copied to `/srv/data/backups/nvme/stacks` |
| External HDD | rsync mirror of all of `/srv/data`, NVMe backup included | `scripts/backup-external.sh`, run by hand |

```text
NVMe ──backup.sh: dumps + rsync──► ZFS /srv/data ──backup-external.sh: rsync──► external HDD
                                                  GitHub: how it's built (compose, scripts, docs)
```

**Rebuild** = Debian → clone the repo → `host/bootstrap.sh` → rsync the backups back →
`scripts/portainer-stacks.py apply` ([playbook 10](playbooks/10-disaster-recovery.md#scenario-c--rebuild-the-host)).
Everything on the disk is plain files: `ls`, `cp` and `rsync` are all a restore needs.

**Rules that keep data safe across stop/start:**

* Everything persistent is an **absolute bind mount** — no named volumes, no anonymous volumes
  holding data (image-declared `VOLUME`s get an explicit bind, e.g. ONLYOFFICE).
* Never `docker compose down -v`, never `docker volume prune` without looking first.

👉 [`playbooks/04-backup-and-restore.md`](playbooks/04-backup-and-restore.md)

---

## ➕ Adding a service — checklist

- [ ] `<app>/docker-compose.yml` starting with the standard header comment
- [ ] Resource anchors (size tier + role) copied in
- [ ] Data in `/srv/docker/volumes/<app>` (config/DB) or `/srv/data/<app>` (bulk) — absolute bind mounts
- [ ] Secrets in `<app>/.env.secrets` (mode 600), referenced by absolute path
- [ ] Traefik labels with `certresolver=stepca` and `<app>.home`
- [ ] Pi-hole DNS record `<app>.home` → host IP
- [ ] `security_opt: no-new-privileges`, `cap_drop: ALL` (or a comment saying why not)
- [ ] Healthcheck, `restart: unless-stopped`, no unnecessary published ports
- [ ] Listed in `stacks.toml`, created with `scripts/portainer-stacks.py apply`; tile added to Homepage

👉 [`playbooks/05-add-a-new-service.md`](playbooks/05-add-a-new-service.md) · templates:
[`docker-compose.traefik.yml`](docker-compose.traefik.yml),
[`docker-compose.db.yml`](docker-compose.db.yml),
[`docker-compose.socket.yml`](docker-compose.socket.yml)

---

## 📖 Documentation & playbooks

**Deep dives:** [🔐 TLS & internal PKI](docs/tls.md)

**Playbooks** — [index & ground rules](playbooks/README.md):

| # | Playbook | Use it when… |
|---|---|---|
| 01 | [Start & stop apps](playbooks/01-start-stop-apps.md) | you want to use an on-demand app |
| 02 | [Deploy a change](playbooks/02-deploy-a-change.md) | you edited a compose file |
| 03 | [Update images](playbooks/03-update-images.md) | an app has a new version |
| 04 | [Backup & restore](playbooks/04-backup-and-restore.md) | before risky changes, or something broke |
| 05 | [Add a new service](playbooks/05-add-a-new-service.md) | you want a new app |
| 06 | [Infrastructure stacks](playbooks/06-infrastructure-stacks.md) | touching Traefik, step-ca, socket proxy or Portainer |
| 07 | [Secrets](playbooks/07-secrets.md) | adding or rotating a secret |
| 08 | [Reboot, shutdown & power](playbooks/08-reboot-and-power.md) | restarting the host, or skipping tonight's 22:00 power-off |
| 09 | [Troubleshooting](playbooks/09-troubleshooting.md) | something doesn't load |
| 10 | [Disaster recovery](playbooks/10-disaster-recovery.md) | Portainer, Git or the host is gone |
| 11 | [Health check](playbooks/11-health-check.md) | monthly once-over |
| 12 | [TLS & certificates](playbooks/12-tls-certificates.md) | certificate warnings, new hostnames, CA work |

---

<div align="center">

**Stable. Predictable. Boring.** That's the point. 🧱

</div>
