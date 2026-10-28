# 12 · TLS & certificates

**Use when:** a device shows certificate warnings, you add a hostname, a certificate looks wrong,
or you're working on step-ca / Traefik ACME.
**Background:** read [`docs/tls.md`](../docs/tls.md) first — this playbook assumes it.

```bash
CA_CRT=/srv/docker/volumes/step-ca/certs/root_ca.crt
CA="--cacert $CA_CRT"
```

| # | Task | Risk |
|---|---|---|
| 1 | [Trust the root CA on a device](#1-trust-the-root-ca-on-a-device) | 🟢 |
| 2 | [Inspect the certificate a site serves](#2-inspect-the-certificate-a-site-serves) | 🟢 |
| 3 | [List every certificate Traefik holds](#3-list-every-certificate-traefik-holds) | 🟢 |
| 4 | [Add a hostname](#4-add-a-hostname) | 🟢 |
| 5 | [Troubleshoot issuance](#5-troubleshoot-issuance) | 🟢 |
| 6 | [Check step-ca health](#6-check-step-ca-health) | 🟢 |
| 7 | [Back up & restore the CA](#7-back-up--restore-the-ca) | 🟢 / 🔴 |
| 8 | [Change the certificate lifetime](#8-change-the-certificate-lifetime) | 🟡 restarts |
| 9 | [Remove stale certificates / force re-issue](#9-remove-stale-certificates--force-re-issue) | 🟡 Traefik restart |
| 10 | [Re-issue the intermediate CA](#10-re-issue-the-intermediate-ca-rare) | 🔴 rare |

---

## 1. Trust the root CA on a device

**Get the file** (and check it's the right one):

```bash
curl -sk https://192.168.1.101:9000/roots.pem -o homelab-root-ca.crt     # or copy $CA_CRT
openssl x509 -in homelab-root-ca.crt -noout -subject -fingerprint -sha256
# subject=O=marxa CA, CN=marxa CA Root CA
# SHA256 Fingerprint=C2:78:1A:B3:59:3C:4F:0F:13:80:94:05:54:F3:EE:7C:7B:20:7F:5A:AF:E5:FD:31:02:5E:F7:75:00:6A:11:CB
```

> Only install a root whose fingerprint matches. Whoever controls a trusted root can impersonate any site.

| Platform | Steps |
|---|---|
| **Debian / Ubuntu** | `sudo cp homelab-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| **Fedora / Arch** | `sudo trust anchor --store homelab-root-ca.crt` |
| **macOS** | double-click → *Keychain Access* → System → open the cert → *Trust* → **Always Trust** |
| **Windows** | `certutil -addstore -f Root homelab-root-ca.crt` (admin) — or double-click → *Install* → Local Machine → *Trusted Root Certification Authorities* |
| **iOS / iPadOS** | AirDrop/mail the file → *Settings → Profile Downloaded* → Install → then **Settings → General → About → Certificate Trust Settings → enable full trust** (easy to forget) |
| **Android** | *Settings → Security → Encryption & credentials → Install a certificate → CA certificate*. Some apps ignore user CAs. |
| **Firefox** (own store) | *Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import* (or set `security.enterprise_roots.enabled = true` to use the OS store) |
| **A container** | mount `$CA_CRT` into `/usr/local/share/ca-certificates/` and run `update-ca-certificates`; Node.js apps also need `NODE_EXTRA_CA_CERTS` |

---

## 2. Inspect the certificate a site serves

```bash
h=cloud.home
echo | openssl s_client -connect 192.168.1.101:443 -servername $h -showcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -startdate -enddate -ext subjectAltName
curl -sv $CA https://$h/ -o /dev/null 2>&1 | grep -E 'SSL certificate verify|subject:|issuer:|expire'
```

Expect `issuer=… CN=marxa CA Intermediate CA`. `TRAEFIK DEFAULT CERT` means Traefik has **no**
certificate for that name (no router, or issuance failed → task 5).

Quick sweep:

```bash
for h in portainer cloud office paperless podsync invidious; do
  printf '%-12s ' $h; echo | openssl s_client -connect 192.168.1.101:443 -servername $h.home 2>/dev/null \
  | openssl x509 -noout -enddate -issuer | tr '\n' ' '; echo; done
```

---

## 3. List every certificate Traefik holds

The ACME store `/srv/docker/volumes/traefik/certs/acme-stepca.json` is root-only (mode 600) and holds
private keys — **never copy it anywhere public**. List domains and expiry without exposing keys:

```bash
docker run --rm -v /srv/docker/volumes/traefik/certs:/c:ro alpine:3 cat /c/acme-stepca.json | python3 -c '
import base64, json, subprocess, sys
for r, d in json.load(sys.stdin).items():
    for c in d.get("Certificates") or []:
        pem = base64.b64decode(c["certificate"]).decode().split("-----END CERTIFICATE-----")[0] + "-----END CERTIFICATE-----\n"
        end = subprocess.run(["openssl","x509","-noout","-enddate"], input=pem, capture_output=True, text=True).stdout.strip().split("=",1)[-1]
        print(c["domain"]["main"].ljust(24), "expires", end)' | sort
```

Hostnames here that no router uses anymore are stale → task 9.

---

## 4. Add a hostname

1. **DNS first:** Pi-hole → *Local DNS → DNS Records* → `<app>.home` → `192.168.1.101`.
   Check from the host *and* from step-ca:
   ```bash
   getent hosts <app>.home
   docker exec step-ca getent hosts <app>.home
   ```
2. Give the service the standard labels (`tls.certresolver=stepca`, `Host(\`<app>.home\`)`) and deploy it.
3. Watch issuance (usually < 5 s):
   ```bash
   docker logs -f traefik 2>&1 | grep -iE '<app>.home|acme'
   ```
4. Verify with task 2.

---

## 5. Troubleshoot issuance

```bash
docker logs --since 1h traefik 2>&1 | grep -iE 'acme|certificate' | tail -20
docker logs --since 1h step-ca 2>&1 | grep -iE 'error|challenge' | tail -20
```

| Error (Traefik log) | Cause | Fix |
|---|---|---|
| `the server didn't respond to our request (status=pending)` / `connection refused` on challenge | step-ca can't fetch `http://<host>/.well-known/acme-challenge/…` — usually **no DNS record** | Add the Pi-hole record (task 4) |
| `x509: certificate signed by unknown authority` (to `ca.home:9000`) | Traefik doesn't trust step-ca | Check the root mounts and `LEGO_CA_CERTIFICATES` in `traefik/.env`; restart Traefik |
| `dial tcp: lookup ca.home` | Traefik not on `proxy`, or step-ca down / lost its alias | `docker ps \| grep step-ca`; `docker network inspect proxy` |
| `unable to obtain ACME certificate` right after creating a router | DNS propagation / typo in `Host()` | Fix, then Traefik retries on its own |
| Site serves `TRAEFIK DEFAULT CERT` | Router missing `tls.certresolver=stepca`, or issuance failed | Labels + errors above |
| Browser warning but `curl $CA` works | The device doesn't trust the root | Task 1 |
| Warning only on `https://192.168.1.101:900x` | Expected: no hostname → default cert | Use the `*.home` name |

---

## 6. Check step-ca health

```bash
curl -s $CA https://ca.home:9000/health                     # {"status":"ok"}
docker exec step-ca step ca health                          # ok
curl -s $CA https://ca.home:9000/acme/traefik-acme/directory | python3 -m json.tool | head
docker exec step-ca cat /home/step/config/ca.json | python3 -c \
  'import json,sys; [print(p["type"], p["name"], p.get("claims")) for p in json.load(sys.stdin)["authority"]["provisioners"]]'
```

---

## 7. Back up & restore the CA

The CA directory contains **private keys and their password**. Back it up **encrypted** and
**off-host**, and never into Git.

```bash
BK=/srv/data/backups/$(date +%Y%m%d); mkdir -p $BK
docker run --rm -v /srv/docker/volumes:/v:ro -v $BK:/b alpine:3 \
  tar -C /v -czf /b/step-ca.tar.gz step-ca traefik/certs
gpg --symmetric --cipher-algo AES256 $BK/step-ca.tar.gz && shred -u $BK/step-ca.tar.gz
# → step-ca.tar.gz.gpg — copy it off the server
```

**Restore** (stack stopped): `gpg -d step-ca.tar.gz.gpg | docker run --rm -i -v /srv/docker/volumes:/v alpine:3 tar -C /v -xzf -`,
then `cd /srv/docker/stacks/step-ca && docker compose up -d` and restart Traefik.
Restoring the **same** root means no device needs re-trusting.

Losing `/srv/docker/volumes/step-ca` without a backup = new CA = **re-trust every device**.

---

## 8. Change the certificate lifetime

Two values must always agree: step-ca's issued lifetime and Traefik's `certificatesDuration`
(see [docs/tls.md § 6](../docs/tls.md#6-lifecycle--renewal)).

1. step-ca — `/srv/docker/volumes/step-ca/config/ca.json`, provisioner `traefik-acme`:
   `claims.defaultTLSCertDuration` / `maxTLSCertDuration` (e.g. `720h`).
2. Traefik — `/srv/docker/volumes/traefik/traefik.yml`, resolver `stepca`:
   `certificatesDuration: <same value in hours>`.
3. Restart both:
   ```bash
   cd /srv/docker/stacks/step-ca && docker compose restart step-ca
   cd /srv/docker/stacks/traefik && docker compose restart -t 5 traefik
   ```
4. Verify: `docker logs --since 2m traefik | grep -c 'Renewing ACME'` stays near 0 for valid certs;
   new certificates show the new lifetime (task 2).

---

## 9. Remove stale certificates / force re-issue

Traefik keeps renewing every certificate in its store, even for hostnames no router uses.
Edit the store **only while Traefik is stopped**. `-t 5` keeps the outage short (the default stop
waits up to the 60 s grace period):

```bash
cd /srv/docker/stacks/traefik
docker run --rm -v /srv/docker/volumes/traefik/certs:/c:ro -v /srv/data/backups:/b alpine:3 \
  cp /c/acme-stepca.json /b/acme-stepca-$(date +%Y%m%d-%H%M).json        # backup (contains keys!)
docker compose stop -t 5 traefik                                        # ⚠️ all *.home down from here
docker run --rm -v /srv/docker/volumes/traefik/certs:/c python:3-alpine python -c '
import json
STALE = {"old-app.home"}                                                 # hostnames to drop
p = "/c/acme-stepca.json"; s = json.load(open(p))
for r in s.values():
    before = len(r["Certificates"]); r["Certificates"] = [c for c in r["Certificates"] if c["domain"]["main"] not in STALE]
    print("removed", before - len(r["Certificates"]))
json.dump(s, open(p, "w"), indent=2)'
docker compose start traefik
```

* **Force re-issue of one hostname:** put it in `STALE` — Traefik requests a fresh certificate as
  soon as it starts, because the router still exists.
* **Re-issue everything:** stop Traefik, move `acme-stepca.json` aside, start Traefik (new ACME
  account, every cert re-issued within seconds).
* **Rollback:** stop Traefik, copy the backup back, start.

---

## 10. Re-issue the intermediate CA (rare)

Only needed if the intermediate key leaks or nears expiry (2035). Leaf certs renew onto the new
intermediate automatically; devices trust the root, so nothing changes for them.

```bash
# back up first (task 7), then inside the container:
docker exec -it step-ca sh -c 'cd /home/step && step certificate create "marxa CA Intermediate CA" \
  certs/intermediate_ca.crt.new secrets/intermediate_ca_key.new \
  --profile intermediate-ca --ca certs/root_ca.crt --ca-key secrets/root_ca_key --not-after 87600h'
# swap the .new files in (the new key must be encrypted with secrets/password — see step-ca docs),
# then: cd /srv/docker/stacks/step-ca && docker compose restart step-ca
```

Follow Smallstep's documentation for this one — a mistake here stops all issuance.
