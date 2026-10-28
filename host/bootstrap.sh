#!/usr/bin/env bash
# =============================================================================
# Bring a Debian 13 host to the state these stacks expect
#
#   sudo /srv/docker/stacks/host/bootstrap.sh
#
# Idempotent and safe on the live server: it never recreates running containers,
# never overwrites a daemon.json that differs, and never creates a ZFS pool or
# a new CA. What it can't do on its own is printed as TODO (exit code 2).
#
#   DOCKER_DNS=<ip>   DNS server for containers (default: first nameserver
#                     in /etc/resolv.conf — should be the Pi-hole)
# =============================================================================
set -euo pipefail

STACKS=/srv/docker/stacks
VOLUMES=/srv/docker/volumes
POOL=tank
INFRA=(docker-socket-proxy step-ca traefik portainer)   # start order
PKGS=(docker.io docker-compose docker-buildx linux-headers-amd64 zfs-dkms zfsutils-linux
      rsync curl git python3)

PENDING=0
step() { echo; echo "== $*"; }
ok()   { echo "   ok: $*"; }
todo() { echo "   TODO: $*"; PENDING=1; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "expected Debian 13 (trixie), got ${PRETTY_NAME:-unknown}"
[ "$(cd "$(dirname "$0")/.." && pwd)" = "$STACKS" ] || die "clone the repo to $STACKS first"

# --- Packages ------------------------------------------------------------------
step "packages"
missing=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if [ ${#missing[@]} -eq 0 ]; then
  ok "all installed"
else
  apt-cache policy zfs-dkms | grep -q 'Candidate: [0-9]' \
    || die "zfs-dkms not available: enable the 'contrib' component in APT sources"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  ok "installed ${missing[*]}"
fi
if [ -n "${SUDO_USER:-}" ] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  usermod -aG docker "$SUDO_USER"
  ok "$SUDO_USER added to the docker group (log in again)"
fi

# --- Docker daemon -------------------------------------------------------------
step "docker daemon.json"
dns=${DOCKER_DNS:-$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)}
want=$(python3 -c 'import json,sys; print(json.dumps({
  "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"},
  "dns": [sys.argv[1]]}, indent=2))' "$dns")
if [ ! -s /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  echo "$want" > /etc/docker/daemon.json
  systemctl restart docker
  ok "written (dns $dns), docker restarted"
elif python3 -c 'import json,sys; sys.exit(json.load(open("/etc/docker/daemon.json")) != json.loads(sys.argv[1]))' "$want"; then
  ok "as expected (dns $dns)"
else
  todo "/etc/docker/daemon.json differs from the expected one — left untouched. Expected:"
  echo "$want" | sed 's/^/         /'
fi
systemctl is-active -q docker || die "docker is not running"

# --- ZFS -----------------------------------------------------------------------
step "ZFS pool $POOL"
if ! zpool list -H "$POOL" >/dev/null 2>&1; then
  zpool import "$POOL" 2>/dev/null && ok "imported" \
    || todo "pool $POOL not found: recreate it and restore /srv/data from the external disk (playbook 10, scenario C)"
fi
if mountpoint -q /srv/data; then
  ok "/srv/data mounted"
  systemctl enable --now -q "zfs-scrub-monthly@$POOL.timer"
  ok "monthly scrub timer enabled (catches up after the host was off)"
else
  todo "/srv/data is not mounted"
fi

# --- Docker networks -------------------------------------------------------------
step "docker networks"
for n in proxy dockersock; do
  if docker network inspect "$n" >/dev/null 2>&1; then ok "$n exists"
  else docker network create "$n" >/dev/null; ok "$n created"; fi
done

# --- Backups ---------------------------------------------------------------------
step "backup + 22:00 power-off"
if [ -f /srv/data/backups/nvme/LAST-BACKUP ]; then ok "NVMe backup from $(cat /srv/data/backups/nvme/LAST-BACKUP)"
else todo "no NVMe backup in /srv/data/backups/nvme yet: restore /srv/data, or run scripts/backup.sh"; fi
# homelab-backup.{service,timer} (03:30) were replaced by the 22:00 backup + shutdown
if [ -e /etc/systemd/system/homelab-backup.timer ]; then
  systemctl disable --now -q homelab-backup.timer || true
  rm -f /etc/systemd/system/homelab-backup.{service,timer}
  systemctl daemon-reload
  ok "old homelab-backup timer removed"
fi
changed=false
for u in homelab-shutdown.service homelab-shutdown.timer; do
  if ! cmp -s "$STACKS/host/systemd/$u" "/etc/systemd/system/$u"; then
    install -m 644 "$STACKS/host/systemd/$u" "/etc/systemd/system/$u"; changed=true
  fi
done
$changed && systemctl daemon-reload && ok "systemd units installed/updated"
systemctl enable --now -q homelab-shutdown.timer
ok "22:00 backup + power-off timer enabled"

# --- Infrastructure stacks -------------------------------------------------------
step "infrastructure stacks"
# Without restored data step-ca would create a NEW CA (every device must re-trust it)
restored=true
# (portainer/data may be absent: the backup holds Portainer's own backup archive instead)
for f in step-ca/config/ca.json traefik/traefik.yml traefik/dynamic; do
  [ -e "$VOLUMES/$f" ] || { todo "$VOLUMES/$f missing: restore /srv/docker from /srv/data/backups/nvme (playbook 10, scenario C)"; restored=false; }
done
if $restored; then
  for s in "${INFRA[@]}"; do
    (cd "$STACKS/$s" && docker compose up -d --no-recreate --quiet-pull) || die "$s failed to start"
    ok "$s up"
  done
else
  echo "   skipped until the data is restored"
fi

# --- Next ------------------------------------------------------------------------
step "next steps"
cat <<'EOF'
   * New Portainer data? Create the admin at https://portainer.home within 5 minutes,
     then an API token in ~/.config/portainer-api.hdr (playbook 07).
   * Databases restored from dumps? Load them before starting the apps (playbook 10, scenario C).
   * App stacks:  scripts/portainer-stacks.py plan  →  scripts/portainer-stacks.py apply
EOF

if [ "$PENDING" = 1 ]; then echo; echo "Some steps need you (TODO above)."; exit 2; fi
echo; echo "Host is ready."
