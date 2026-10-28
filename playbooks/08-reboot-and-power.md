# 08 · Reboot, shutdown & power

**Use when:** kernel/OS updates, hardware work, powering the server down, or changing / skipping the
daily **22:00 backup + power-off**.
**Risk:** 🟡 everything is down for 1–2 minutes.

## What comes back after boot

| Stack state before shutdown | After boot |
|---|---|
| Infra (`traefik`, `step-ca`, `docker-socket-proxy`, `portainer`) | ✅ up (`restart: unless-stopped`) |
| App stack **running** | ✅ up |
| App stack **stopped in Portainer** | ⛔ stays off (its containers don't exist) |
| Single container stopped with *Stop* on the container | ⛔ stays off (`unless-stopped`) |

So: **the server comes back exactly as you left it** — after a manual shutdown and after the daily
22:00 power-off alike. An on-demand app still running at 22:00 starts again on the next boot: stop
it when you're done.

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

## Daily backup + power-off at 22:00

`homelab-shutdown.timer` runs every day at **22:00 Spanish time** (`Europe/Madrid`, summer time
included): it takes the NVMe backup ([04](04-backup-and-restore.md)), then powers the host off. A
running backup or HDD copy is waited for, never cut off; a failed backup still powers off (the error
is in the journal).

```bash
systemctl list-timers homelab-shutdown.timer          # next run
sudo systemctl stop homelab-shutdown.timer            # skip tonight (back at the next boot)
sudo systemctl stop homelab-shutdown.service          # it's 22:00 and the backup is running: cancel both
sudo systemctl disable --now homelab-shutdown.timer   # turn it off for good (bootstrap.sh turns it back on)
journalctl -u homelab-shutdown.service -n 30          # what the last run did
```

Booting after 22:00 doesn't trigger it: the next run is the following evening.

## Shutdown overnight / Wake-on-LAN

* `sudo systemctl poweroff` — same behaviour as a reboot on the next start.
* Wake-on-LAN: send a magic packet to the server's MAC (`ip link show enp2s0`), e.g.
  `wakeonlan <server-mac>` from another machine. WoL must be enabled in the BIOS and on the
  NIC (`ethtool -s enp2s0 wol g`, persisted via a systemd-networkd/udev rule).
* DNS keeps working while the server is off — Pi-hole runs on a separate device.

## If something doesn't come back

→ [09 · Troubleshooting](09-troubleshooting.md)
