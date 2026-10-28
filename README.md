# Homelab Docker Baseline (SRE-style)

A homelab built with an **SRE / platform-first** philosophy:
**stable**, **predictable**, **reproducible**, and **easy to maintain** infrastructure.

The primary goal is to **prevent global host failures** (OOM, freezes, DNS outages)
and **isolate problems at the service level**.

---

## Table of Contents

- [Core Principles](#-core-principles)
- [Directory Structure](#-directory-structure)
- [Resource Limits](#-resource-limits)
- [Docker Compose Policy](#-docker-compose-policy)
- [OOM Policy](#️-oom-policy)
- [Swap Configuration](#-swap-configuration)
- [Networking, DNS & TLS](#-networking-dns--tls)
- [Traefik & step-ca Certificate Architecture](#-traefik--step-ca-certificate-architecture)
- [Docker API Access](#-docker-api-access)
- [Container Hardening](#-container-hardening)
- [Observability](#-observability)
- [ZFS Snapshots](#-zfs-snapshots)
- [Compose Templates](#-compose-templates)
- [Checklist for New Services](#-checklist-for-new-services)
- [Adding a New Service (Walkthrough)](#-adding-a-new-service)

---

## 🧱 Core Principles

* **Every Docker service has real resource limits** (memory, CPU, PIDs)
* **Nothing relies on hacks** (`/etc/hosts`, unnecessary open ports, etc.)
* **Internal DNS and TLS are first-class citizens**
* **Clear separation** between:
  * stacks (`/srv/docker/stacks`) — compose files and configuration
  * data (`/srv/docker/volumes`) — persistent volumes
* **OOM Killer as a last resort**, not a scheduler

---

## 📂 Directory Structure

```text
/srv/docker/
├── stacks/                         # One docker-compose.yml per service
│   ├── resource-limits.yaml        # Central resource anchor reference
│   ├── docker-compose.traefik.yml  # Template: simple Traefik service
│   ├── docker-compose.db.yml       # Template: service + PostgreSQL
│   ├── docker-compose.socket.yml   # Template: service needing Docker API
│   ├── traefik/
│   ├── step-ca/
│   ├── docker-socket-proxy/
│   ├── portainer/
│   ├── homepage/
│   ├── forgejo/
│   ├── jellyfin/
│   ├── immich/
│   ├── invidious/
│   ├── paperless/
│   ├── podsync/
│   ├── navidrome/
│   ├── nextcloud/
│   ├── kavita/
│   └── musicbrainz-picard/
│
└── volumes/                        # Persistent data per service
    ├── traefik/
    ├── step-ca/
    ├── forgejo/
    ├── jellyfin/
    ├── immich/
    ├── paperless/
    ├── homepage/
    ├── portainer/
    └── ...
```

Each stack directory contains:
* `docker-compose.yml` — the service definition
* `.env` — non-secret environment variables
* `.env.secrets` — secrets (gitignored)

A shared `../.env.global` file is loaded by all stacks for common variables (e.g. `TZ`, `PUID`, `PGID`).

---

## 📐 Resource Limits

All resource defaults are centrally defined in [`resource-limits.yaml`](resource-limits.yaml).

> **Important:** Docker Compose does not share YAML anchors between files
> (not via `include:` nor `COMPOSE_FILE`). Each `docker-compose.yml` must
> copy the required anchors locally.

### Size Tiers

| Tier     | Memory Limit | Memory Reservation | CPUs | PIDs Limit |
|----------|-------------:|-------------------:|-----:|-----------:|
| xsmall   | 128 MB       | 32 MB              | 0.25 | 128        |
| small    | 256 MB       | 64 MB              | 0.5  | 256        |
| medium   | 512 MB       | 128 MB             | 1.0  | 512        |
| large    | 1 GB         | 256 MB             | 2.0  | 1024       |
| xlarge   | 2 GB         | 512 MB             | 4.0  | 2048       |

### Role Anchors

Role anchors define `stop_grace_period` and `oom_score_adj` per service role:

| Role     | Stop Grace Period | OOM Score Adj | Description                                  |
|----------|------------------:|--------------:|----------------------------------------------|
| core     | 60 s              | −400          | Infrastructure (Traefik, step-ca, DNS proxy)  |
| cache    | 20 s              | −200          | Redis, in-memory caches                       |
| db       | 60 s              | −100          | PostgreSQL, databases                         |
| service  | 30 s              | +200          | Application services (web UIs, APIs)          |
| worker   | 45 s              | +300          | Background workers, task queues               |
| batch    | 120 s             | +500          | Long-running batch jobs                       |

Usage in a compose file (anchors must be copied locally):

```yaml
x-resource-medium: &resource_medium
  mem_limit: 512m
  mem_reservation: 128m
  cpus: 1.0
  pids_limit: 512

x-resource-service: &resource_service
  stop_grace_period: 30s
  oom_score_adj: 200

services:
  myapp:
    image: my/image:tag
    <<: [*resource_medium, *resource_service]
```

---

## 🧠 Docker Compose Policy

### 🚫 Forbidden

* `deploy.resources` — only works in Docker Swarm, silently ignored in Compose
* Containers without resource limits
* Mounting `/var/run/docker.sock` directly in application containers
* Core services without OOM protection

### ✅ Required on **every service**

```yaml
mem_limit: <hard limit>
mem_reservation: <soft limit>
cpus: <cpu limit>
pids_limit: <pid limit>
```

---

## ☠️ OOM Policy

The Linux OOM killer decides which process to terminate when memory is exhausted.
`oom_score_adj` ranges from −1000 (never kill) to +1000 (kill first).

### Core services (must survive longest)

Traefik, step-ca, Pi-hole, docker-socket-proxy:

```yaml
oom_score_adj: -400
```

### Database services

PostgreSQL, Redis:

```yaml
oom_score_adj: -100   # databases
oom_score_adj: -200   # caches
```

### Application services (expendable)

Invidious, Jellyfin, Podsync, Immich, Homepage, etc.:

```yaml
oom_score_adj: 200   # standard apps
oom_score_adj: 300   # workers
oom_score_adj: 500   # batch jobs
```

This teaches the kernel **which processes to sacrifice first** under memory pressure,
keeping infrastructure alive while apps restart.

---

## 🔁 Swap Configuration

Even with plenty of RAM, swap is **mandatory in a homelab**:

* Prevents hard freezes and soft lockups
* Gives the kernel breathing room under transient spikes
* Protects the host when a container leaks memory

Recommended setup:

```bash
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf
```

> `swappiness=10` keeps swap as a safety net rather than an active paging target.

---

## 🌐 Networking, DNS & TLS

### DNS

* **Pi-hole** serves as internal DNS resolver (`*.home`)
* The host itself uses Pi-hole as its DNS server (consciously accepted dependency)
* No `/etc/hosts` hacks are used anywhere
* Pi-hole is designed to be migrated off the server in the future (e.g. to the router)

### TLS / PKI

* Internal Certificate Authority: **step-ca** (Smallstep) deployed in Docker
* Internal domain: `*.home`
* Root CA certificate installed system-wide (`/usr/local/share/ca-certificates/`)
* Traefik requests certificates from step-ca via ACME

---

## 🔒 Traefik & step-ca Certificate Architecture

This homelab uses a full **internal PKI** with automatic certificate issuance.
Every service gets valid TLS certificates — no self-signed certs, no cert warnings.

### How It Works

```
┌────────────┐      ACME (HTTP-01)       ┌────────────┐
│   Traefik  │ ◄──────────────────────── │   step-ca  │
│  (reverse  │   certificate request     │ (internal  │
│   proxy)   │ ────────────────────────► │    CA)     │
└─────┬──────┘                           └────────────┘
      │  TLS termination                       │
      │  for all *.home                        │
      ▼                                        │
┌────────────┐                           Root CA installed
│  Services  │                           on host + containers
│ (backends) │                           that need to verify
└────────────┘                           internal TLS
```

### step-ca Configuration

step-ca runs as a Docker container on the `proxy` network with a network alias `ca.home`:

```yaml
services:
  step-ca:
    image: smallstep/step-ca:latest
    networks:
      proxy:
        aliases:
          - ca.home   # Traefik reaches the CA at this address
    ports:
      - "9000:9000"   # ACME directory exposed for bootstrapping
    volumes:
      - /srv/docker/volumes/step-ca:/home/step
```

### Traefik ACME Resolver

In Traefik's static configuration (`traefik.yml`), the ACME resolver points to step-ca:

```yaml
certificatesResolvers:
  stepca:
    acme:
      caServer: https://ca.home:9000/acme/traefik-acme/directory
      email: admin@home
      storage: /certs/acme-stepca.json
      httpChallenge:
        entryPoint: web
```

Traefik also needs the root CA certificate mounted so it trusts step-ca's TLS:

```yaml
services:
  traefik:
    volumes:
      - /path/to/root_ca.crt:/usr/local/share/ca-certificates/step-root-ca.crt:ro
    command:
      - sh
      - -lc
      - |
        update-ca-certificates || true
        traefik --configFile=/etc/traefik/traefik.yml
```

### How Services Get Certificates

Each service uses Traefik labels to request a TLS certificate from step-ca automatically:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.myapp.rule=Host(`myapp.home`)
  - traefik.http.routers.myapp.entrypoints=websecure
  - traefik.http.routers.myapp.tls=true
  - traefik.http.routers.myapp.tls.certresolver=stepca
  - traefik.http.services.myapp.loadbalancer.server.port=8080
```

When Traefik sees these labels, it:
1. Requests a certificate for `myapp.home` from step-ca via ACME
2. Stores the certificate in `acme-stepca.json`
3. Terminates TLS and proxies traffic to the backend on the specified port

### Services That Need to Trust the Internal CA

Some services make HTTPS calls to other internal services (e.g. Homepage calling
Immich's API). These containers need the root CA certificate mounted:

```yaml
volumes:
  - /path/to/root_ca.crt:/usr/local/share/ca-certificates/home-root-ca.crt:ro
```

Some applications use environment variables instead (e.g. Node.js apps like ONLYOFFICE):

```yaml
environment:
  NODE_EXTRA_CA_CERTS: /usr/local/share/ca-certificates/home-root-ca.crt
```

### Port-Based Access (Fallback)

In addition to DNS-based routing (`myapp.home`), Traefik exposes numbered ports as
a fallback for direct IP access. Each port maps to a dedicated entrypoint:

```yaml
# In traefik.yml
entryPoints:
  portainer-port:
    address: ":9001"
    http:
      tls:
        certResolver: stepca
```

This allows accessing services via `https://<host-ip>:9001` when DNS is unavailable.

---

## 🔐 Docker API Access

* **Never** mount `/var/run/docker.sock` directly in application containers
* A **docker-socket-proxy** (Tecnativa) is used as a read-only gateway
* Traefik and Portainer consume the Docker API via `tcp://docker-socket-proxy:2375`
* The proxy container is the **only** one that mounts the Docker socket

```yaml
# docker-socket-proxy/docker-compose.yml
services:
  docker-socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - dockersock
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

Services that need Docker API access join the `dockersock` external network
and set `DOCKER_HOST: "tcp://docker-socket-proxy:2375"`.

---

## 🛡️ Container Hardening

All containers follow these hardening guidelines where compatible:

```yaml
security_opt:
  - no-new-privileges:true    # Prevent privilege escalation
cap_drop:
  - ALL                       # Drop all Linux capabilities
cap_add:
  - <only what's needed>      # Add back only required caps
```

> **Note:** Some images (e.g. Forgejo) have compatibility issues with `cap_drop: ALL`.
> In those cases, `cap_drop` is intentionally omitted and documented in the compose file.

Additional hardening:
* `read_only: true` where possible (with `tmpfs` mounts for `/tmp` and `/run`)
* `tmpfs` for transient data to reduce disk I/O and improve security
* `user: "UID:GID"` to avoid running as root when the image supports it

---

## 📊 Observability

* No alerting stack: this is a small personal setup
* **Portainer** provides the Docker management UI (logs, stats, start/stop) and talks to the Docker socket directly

---

## 📸 ZFS Snapshots

The storage backend is a ZFS mirror (`2×4 TB`). Snapshots are taken at key milestones:

* `@initial` — after first setup
* `@post-oom-hardening` — after applying resource limits
* Before adding complex services (e.g. Immich, Nextcloud)

```bash
zfs snapshot tank/srv@post-oom-hardening
```

The ZFS pool is designed for future migration from mirror to RAIDZ1.

---

## 📋 Compose Templates

Three reusable templates are provided in the `stacks/` directory:

### Simple service behind Traefik

See [`docker-compose.traefik.yml`](docker-compose.traefik.yml) — a minimal service
that joins the `proxy` network and gets TLS via Traefik labels.

### Service with PostgreSQL database

See [`docker-compose.db.yml`](docker-compose.db.yml) — an app + PostgreSQL pattern
using an internal network for DB traffic and the `proxy` network for Traefik.

### Service needing Docker API

See [`docker-compose.socket.yml`](docker-compose.socket.yml) — for services like
Portainer or Homepage that need Docker API access via the socket proxy.

### Real-world examples

| Service         | Pattern             | Size Tier | Compose File                                      |
|-----------------|---------------------|-----------| --------------------------------------------------|
| Traefik         | Core infrastructure | small     | [`traefik/docker-compose.yml`](traefik/docker-compose.yml)                 |
| step-ca         | Core infrastructure | small     | [`step-ca/docker-compose.yml`](step-ca/docker-compose.yml)                 |
| Socket Proxy    | Core infrastructure | xsmall    | [`docker-socket-proxy/docker-compose.yml`](docker-socket-proxy/docker-compose.yml) |
| Portainer       | Docker API          | medium    | [`portainer/docker-compose.yml`](portainer/docker-compose.yml)               |
| Homepage        | Docker API          | small     | [`homepage/docker-compose.yml`](homepage/docker-compose.yml)                |
| Forgejo         | App + PostgreSQL    | medium    | [`forgejo/docker-compose.yml`](forgejo/docker-compose.yml)                 |
| Jellyfin        | Simple (media)      | xlarge    | [`jellyfin/docker-compose.yml`](jellyfin/docker-compose.yml)               |
| Immich          | Multi-container     | xlarge    | [`immich/docker-compose.yml`](immich/docker-compose.yml)                  |
| Paperless       | App + DB + Redis    | large     | [`paperless/docker-compose.yml`](paperless/docker-compose.yml)              |

---

## 🧪 Checklist for New Services

Before deploying any new service:

- [ ] `docker-compose.yml` with real resource limits (from [`resource-limits.yaml`](resource-limits.yaml))
- [ ] Persistent data in `/srv/docker/volumes/<service>`
- [ ] TLS via Traefik labels with `certresolver=stepca`
- [ ] Internal DNS name (`<service>.home`)
- [ ] `oom_score_adj` set according to service role
- [ ] No unnecessary exposed ports
- [ ] No temporary hacks
- [ ] `security_opt: no-new-privileges:true`
- [ ] `cap_drop: ALL` (unless incompatible — document why)
- [ ] Healthcheck defined
- [ ] `restart: unless-stopped`

---

## ➕ Adding a New Service

For a step-by-step walkthrough on how to add a new service to this homelab,
see [`prompt.md`](prompt.md). It includes:

* Full system context (hardware, storage, networking)
* The working methodology (step-by-step, with checkpoints)
* An example of adding Forgejo with PostgreSQL
* Resource limit templates ready to copy

---

## 🎯 Design Goal

> **A single app failure must never take down the host.**

This README is the operational contract for the homelab.

Current state: **stable, hardened, and ready to grow** 🚀
