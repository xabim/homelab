# 08 · Reboot, shutdown & power

**Use when:** kernel/OS updates, hardware work, or powering the server down overnight.
**Risk:** 🟡 everything is down for 1–2 minutes.

## What comes back after boot

| Stack state before shutdown | After boot |
|---|---|
| Infra (`traefik`, `step-ca`, `docker-socket-proxy`, `portainer`) | ✅ up (`restart: unless-stopped`) |
| App stack **running** | ✅ up |
| App stack **stopped in Portainer** | ⛔ stays off (its containers don't exist) |
| Single container stopped with *Stop* on the container | ⛔ stays off (`unless-stopped`) |

So: **the server comes back exactly as you left it.** Stop the on-demand apps you don't want
running before shutting down.

## Planned reboot

```bash
# 1. (optional) quiesce Nextcloud
docker exec -u www-data nextcloud php occ maintenance:mode --on
# 2. reboot — Docker stops containers using each service's stop_grace_period
sudo systemctl reboot
```

After boot:

```bash
docker exec -u www-data nextcloud php occ maintenance:mode --off   # if you turned it on
docker ps --format '{{.Names}}\t{{.Status}}' | sort
```

Then run the quick checks in [11 · Health check](11-health-check.md#quick-check-2-minutes).

## Shutdown overnight / Wake-on-LAN

* `sudo systemctl poweroff` — same behaviour as a reboot on the next start.
* Wake-on-LAN: send a magic packet to the server's MAC (`ip link show enp2s0`), e.g.
  `wakeonlan <server-mac>` from another machine. WoL must be enabled in the BIOS and on the
  NIC (`ethtool -s enp2s0 wol g`, persisted via a systemd-networkd/udev rule).
* DNS keeps working while the server is off — Pi-hole runs on a separate device.

## If something doesn't come back

→ [09 · Troubleshooting](09-troubleshooting.md)
