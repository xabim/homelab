#!/usr/bin/env python3
"""Keep Portainer's Git stacks in line with ../stacks.toml.

  portainer-stacks.py plan               show differences (read-only)
  portainer-stacks.py apply [--yes]      create missing stacks (on-demand ones are stopped after)
  portainer-stacks.py redeploy <name> [--pull]
                                         pull from Git and redeploy (also starts the stack);
                                         resends stack variables, so Invidious keeps its secrets

Never deletes, stops or restarts an existing stack except through `redeploy`.

Environment:
  PORTAINER_URL          default https://portainer.home
  PORTAINER_TOKEN_FILE   default ~/.config/portainer-api.hdr  ("X-API-Key: <token>")
  PORTAINER_ENDPOINT     endpoint id; only needed if Portainer has more than one
"""

import argparse
import json
import os
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "stacks.toml"
URL = os.environ.get("PORTAINER_URL", "https://portainer.home").rstrip("/")
TOKEN_FILE = Path(os.environ.get("PORTAINER_TOKEN_FILE", "~/.config/portainer-api.hdr")).expanduser()

ACTIVE, INACTIVE = 1, 2  # Portainer stack status


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def api(method, path, body=None, retry_busy=0):
    name, _, value = TOKEN_FILE.read_text().strip().partition(":")
    headers = {name.strip(): value.strip(), "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retry_busy + 1):
        req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            # 409: a previous deploy of this stack is still running
            if e.code == 409 and attempt < retry_busy:
                time.sleep(5)
                continue
            die(f"{method} {path} -> {e.code}: {e.read().decode(errors='replace')[:300]}")
        except urllib.error.URLError as e:
            die(f"{method} {path} -> {e.reason}")


def endpoint_id():
    if "PORTAINER_ENDPOINT" in os.environ:
        return int(os.environ["PORTAINER_ENDPOINT"])
    eps = api("GET", "/api/endpoints")
    if len(eps) != 1:
        die("Portainer has several endpoints; set PORTAINER_ENDPOINT")
    return eps[0]["Id"]


def load_manifest():
    m = tomllib.loads(MANIFEST.read_text())
    for name, s in m["stacks"].items():
        if s.get("mode") not in ("always-on", "on-demand"):
            die(f"{name}: mode must be always-on or on-demand")
        if not (REPO / name / "docker-compose.yml").is_file():
            die(f"{name}: {name}/docker-compose.yml not found")
    return m


def stack_env(name, spec):
    """Stack variables as Portainer expects them; values never printed."""
    keys = spec.get("env", [])
    if not keys:
        return []
    values = {}
    for line in (REPO / spec["env_from"]).read_text().splitlines():
        k, sep, v = line.partition("=")
        if sep and not k.lstrip().startswith("#"):
            values[k.strip()] = v.strip().strip("'\"")
    missing = [k for k in keys if not values.get(k)]
    if missing:
        die(f"{name}: {spec['env_from']} lacks {', '.join(missing)}")
    return [{"name": k, "value": values[k]} for k in keys]


def plan(m, current):
    """Return (missing stack names, list of report lines)."""
    missing, lines = [], []
    for name, spec in m["stacks"].items():
        s = current.get(name)
        if s is None:
            missing.append(name)
            lines.append(f"+ {name:20} create ({spec['mode']})")
            continue
        git = s.get("GitConfig") or {}
        drift = []
        if git.get("URL") != m["repository"]:
            drift.append(f"repository={git.get('URL')}")
        if git.get("ReferenceName") != m["branch"]:
            drift.append(f"branch={git.get('ReferenceName')}")
        if git.get("ConfigFilePath") != f"{name}/docker-compose.yml":
            drift.append(f"compose={git.get('ConfigFilePath')}")
        if s.get("AutoUpdate"):
            drift.append("auto-update is on")
        have = sorted(e["name"] for e in s.get("Env") or [])
        if have != sorted(spec.get("env", [])):
            drift.append(f"variables={have}")
        if drift:
            lines.append(f"~ {name:20} drift: {'; '.join(drift)}  (fix in Portainer)")
        else:
            running = s["Status"] == ACTIVE
            note = "running" if running else "stopped"
            if running != (spec["mode"] == "always-on"):
                note += f"  (mode is {spec['mode']})"
            lines.append(f"  {name:20} ok, {note}")
    for name in sorted(set(current) - set(m["stacks"])):
        lines.append(f"? {name:20} in Portainer but not in stacks.toml")
    return missing, lines


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    a = sub.add_parser("apply")
    a.add_argument("--yes", action="store_true", help="don't ask for confirmation")
    r = sub.add_parser("redeploy")
    r.add_argument("name")
    r.add_argument("--pull", action="store_true", help="re-pull every image of the stack")
    args = p.parse_args()

    m = load_manifest()
    ep = endpoint_id()
    current = {s["Name"]: s for s in api("GET", "/api/stacks") if s["EndpointId"] == ep}

    if args.cmd == "plan":
        missing, lines = plan(m, current)
        print("\n".join(lines))
        sys.exit(2 if missing or any(l[0] in "~?" for l in lines) else 0)

    if args.cmd == "apply":
        missing, lines = plan(m, current)
        print("\n".join(lines))
        if not missing:
            print("nothing to create")
            return
        if not args.yes and input(f"create {len(missing)} stack(s)? [y/N] ").lower() != "y":
            return
        for name in missing:
            spec = m["stacks"][name]
            print(f"creating {name} ...", flush=True)
            s = api("POST", f"/api/stacks/create/standalone/repository?endpointId={ep}", {
                "name": name,
                "repositoryURL": m["repository"],
                "repositoryReferenceName": m["branch"],
                "composeFile": f"{name}/docker-compose.yml",
                "repositoryAuthentication": False,
                "autoUpdate": None,
                "env": stack_env(name, spec),
            })
            if spec["mode"] == "on-demand":
                api("POST", f"/api/stacks/{s['Id']}/stop?endpointId={ep}", retry_busy=60)
                print(f"  {name} stopped (on-demand)")
        return

    if args.cmd == "redeploy":
        spec = m["stacks"].get(args.name) or die(f"{args.name} is not in stacks.toml")
        s = current.get(args.name) or die(f"{args.name} does not exist in Portainer; run apply")
        api("PUT", f"/api/stacks/{s['Id']}/git/redeploy?endpointId={ep}", {
            "env": stack_env(args.name, spec),
            "prune": False,
            "pullImage": args.pull,
            "repositoryReferenceName": m["branch"],
            "repositoryAuthentication": False,
        }, retry_busy=60)
        print(f"{args.name}: redeploy requested (async; containers are recreated, then started)")


if __name__ == "__main__":
    main()
