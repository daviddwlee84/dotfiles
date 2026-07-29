# Docker proxy is configured on disk but `docker info` reports none — orphaned rootful drop-in after the rootless pivot

**Symptoms** (grep this section): `/etc/systemd/system/docker.service.d/http-proxy.conf` exists with correct-looking `Environment="HTTPS_PROXY=..."` lines, yet `docker info | grep -i proxy` prints empty values (`HttpProxy: ""`, `HttpsProxy: ""`, `NoProxy: ""`); `docker pull` of `ghcr.io` / `gcr.io` images fails as if no proxy were set; `systemctl is-enabled docker.service` → `disabled`; `systemctl is-active docker.service` → `inactive`; the daemon you are actually talking to is `systemctl --user status docker`
**First seen**: 2026-07
**Affects**: Linux hosts set up before this repo's rootful → rootless Docker pivot (commit `ec3434a`); any host where a rootful proxy drop-in or `/etc/docker/daemon.json` was hand-written before switching to rootless
**Status**: detected and reported by `docker-net doctor`; cleanup is advisory (never automatic)

## Symptom

```
$ cat /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1"

$ docker info --format '{{json .}}' | jq '{HttpProxy, HttpsProxy, NoProxy}'
{
  "HttpProxy": "",
  "HttpsProxy": "",
  "NoProxy": ""
}
```

The file is present, the syntax is right, the port is even listening. The daemon reports nothing. Every diagnosis that starts from "is the proxy configured?" answers *yes* and goes nowhere.

The tell:

```
$ systemctl is-enabled docker.service docker.socket
disabled
disabled
$ systemctl is-active docker.service docker.socket
inactive
inactive
$ echo $DOCKER_HOST
unix:///run/user/1000/docker.sock
```

`/etc/docker/daemon.json` is orphaned the same way — a `{"dns": ["8.8.8.8", "8.8.4.4"]}` written for the rootful daemon keeps sitting there doing nothing.

## Root cause

There are **two** Docker daemons' worth of config paths on a Linux box, and the rootless pivot silently changed which set is live:

| | rootful (`docker.service`, root) | rootless (`docker.service`, `systemctl --user`) |
|---|---|---|
| systemd drop-in | `/etc/systemd/system/docker.service.d/*.conf` | `~/.config/systemd/user/docker.service.d/*.conf` |
| daemon.json | `/etc/docker/daemon.json` | `~/.config/docker/daemon.json` |

The ansible `docker` role disables and stops rootful `docker.service` + `docker.socket`, then installs the rootless user unit. Nothing removes the old root-owned config — correctly, since a host might switch back. But the leftover files are exactly the ones a human greps for, and `systemd` gives no hint that the unit they patch is inactive.

The client makes it worse: `DOCKER_HOST` points at the rootless socket, so `docker info` talks to the rootless daemon while `/etc/...` describes the dead one. Both halves are internally consistent; only the pairing is wrong.

## Workaround

Ask the live daemon which config it read, rather than reading files:

```bash
docker-net doctor
```

It reports the install shape, the daemon.json path actually in effect, and flags orphaned rootful config explicitly:

```
Stale configuration
  ! stale config    /etc/systemd/system/docker.service.d/http-proxy.conf targets the DISABLED rootful daemon — it does nothing
                    → sudo rm /etc/systemd/system/docker.service.d/http-proxy.conf
  ! stale config    /etc/docker/daemon.json is read only by the disabled rootful daemon
                    → the live config is /home/<you>/.config/docker/daemon.json
```

Then configure the daemon that is actually running:

```bash
docker-net on           # writes ~/.config/docker/daemon.json `proxies` + restarts
docker info --format '{{.HTTPSProxy}}'   # now non-empty
```

Remove the orphans by hand only if you are sure you will not go back to rootful:

```bash
sudo rm /etc/systemd/system/docker.service.d/http-proxy.conf
```

## Prevention

- **Verify against `docker info`, never against a config file.** A file proves intent; only the daemon proves effect.
- Two facts to check before believing any Docker config on Linux: `echo $DOCKER_HOST` and `systemctl is-enabled docker.service`. If the first points into `/run/user/$UID` and the second says `disabled`, everything under `/etc` is decoration.
- Watch out for the Go-template trap while checking: `docker info --format` addresses the **struct field** (`.HTTPProxy`), while `docker info --format '{{json .}}' | jq` shows the **JSON tag** (`.HttpProxy`). Using the JSON name in a template fails the whole template, not just that field:
  `template: :1:21: executing "" at <.HttpProxy>: can't evaluate field HttpProxy in type system.dockerInfo`
- Related good news worth knowing when you do configure the live daemon: rootless `dockerd` runs in the **host** network namespace on Docker ≥ 25 (RootlessKit ≥ 2.0 `--detach-netns`), so a `127.0.0.1` proxy URL does work. `docker-net doctor` verifies this per host rather than assuming it.

## Related

- [docs/tools/docker-net.md](../docs/tools/docker-net.md) — `docker-net doctor`, and why the daemon-side probe is the only authoritative one
- [docs/tools/container-config-map.md](../docs/tools/container-config-map.md) — the full who-reads-what table across rootful / rootless / Desktop / OrbStack / Podman
- [docs/tools/containers.md → Migration note: pre-pivot rootful installs](../docs/tools/containers.md) — the same trap for `registry-mirrors` instead of the proxy
- [`docker-pull-fails-dead-registry-mirrors`](docker-pull-fails-dead-registry-mirrors.md) — the other half of "my Docker networking is configured but nothing works"
- [`centos7-systemd-user-instance-missing`](centos7-systemd-user-instance-missing.md) — hosts where the rootless user unit cannot exist at all
