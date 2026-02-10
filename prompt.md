# System Context — SRE / Homelab

> **Use this file as a prompt template when asking an AI assistant to help you
> add a new service to the homelab.** Copy it, update the "Next Task" section
> at the bottom, and paste it into your conversation.

Act as a senior SRE / homelab engineer, focused on clean, reproducible, and maintainable infrastructure.

## Server

**Debian 13**

- Hardware: Intel i5-12400, 16 GB RAM

## Storage

**ZFS mirror (2×4 TB) on pool `tank`**

- Main dataset mounted at `/srv/data`
- External ext4 drive for incremental backups
- Data already migrated and verified
- Pool ONLINE, initial snapshot taken
- Layout designed for future migration from mirror → RAIDZ1

## Docker

Docker already migrated from the previous server.

### Directory Layout

- Stacks: `/srv/docker/stacks`
- Volumes / data: `/srv/docker/volumes`

## Networking, DNS & TLS

### DNS

- No `/etc/hosts` hacks are used
- We have control over DNS records

### PKI / TLS

**step-ca deployed in Docker as an internal CA**

- Internal domain: `*.home`
- Root CA installed system-wide (`/usr/local/share/ca-certificates`)

### Reverse Proxy

**Traefik v3 in Docker**

- Uses ACME against step-ca
- Certificates stored in `acme-stepca.json`
- Current certificates are issued correctly with ~30-day validity

## Current State

### ✅ Completed Services

- Traefik
- Step-CA
- Pi-hole
- Docker-Socket-Proxy
- Portainer
- Homepage
- Podsync
- Invidious
- Jellyfin
- Paperless
- Immich
- Nextcloud
- Navidrome

## Chat Objective

Add and deploy new services behind Traefik, one at a time.

### Maintain

- Valid TLS with step-ca
- Declarative configuration (Docker Compose + labels)
- Clear separation between data and configuration
- Zero temporary hacks

### Planned Services (not necessarily all at once)

- Forgejo

## Working Method

- Step by step, with clear checkpoints
- Warn before any irreversible decisions
- Prioritize simplicity, low resource usage, and operational clarity

### Always Keeping in Mind

- Maintainability
- Future storage migration
- Future removal of Pi-hole from the server

---

We start from here. The next task is to deploy the next service cleanly behind Traefik.

## Next Task

We are going to deploy **Forgejo**, using this resource-limits template
(see [`resource-limits.yaml`](resource-limits.yaml)):

```yaml
# Size anchors — copy only the ones you need into your docker-compose.yml

x-resource-xsmall: &resource_xsmall
  mem_limit: 128m
  mem_reservation: 32m
  cpus: 0.25
  pids_limit: 128

x-resource-small: &resource_small
  mem_limit: 256m
  mem_reservation: 64m
  cpus: 0.5
  pids_limit: 256

x-resource-medium: &resource_medium
  mem_limit: 512m
  mem_reservation: 128m
  cpus: 1.0
  pids_limit: 512

x-resource-large: &resource_large
  mem_limit: 1g
  mem_reservation: 256m
  cpus: 2.0
  pids_limit: 1024

x-resource-xlarge: &resource_xlarge
  mem_limit: 2g
  mem_reservation: 512m
  cpus: 4.0
  pids_limit: 2048

# Role-specific stop/oom anchors (merge with size anchors as needed)

x-resource-core: &resource_core
  stop_grace_period: 60s
  oom_score_adj: -400

x-resource-cache: &resource_cache
  stop_grace_period: 20s
  oom_score_adj: -200

x-resource-db: &resource_db
  stop_grace_period: 60s
  oom_score_adj: -100

x-resource-service: &resource_service
  stop_grace_period: 30s
  oom_score_adj: 200

x-resource-worker: &resource_worker
  stop_grace_period: 45s
  oom_score_adj: 300

x-resource-batch: &resource_batch
  stop_grace_period: 120s
  oom_score_adj: 500
```

### Usage in a compose file

```yaml
services:
  myservice:
    <<: [*resource_small, *resource_service]
```

### Hardening tips

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
tmpfs:
  - /tmp
```

> **Note:** Be careful with `cap_drop: ALL` — it has caused issues with some
> images (e.g. Forgejo). If the service fails to start, remove `cap_drop` and
> document the reason in the compose file.

### Read-only filesystem

```yaml
read_only: true
tmpfs:
  - /tmp
  - /run
```



