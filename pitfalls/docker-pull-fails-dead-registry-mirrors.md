# `docker pull` fails with "failed to resolve reference" when the image exists — dead registry mirrors

**Symptoms** (grep this section): `Error response from daemon: unknown: failed to resolve reference "docker.io/library/<img>:<tag>": unexpected status from HEAD request to https://<mirror>/v2/...: 403 Forbidden`; `curl: (6) Could not resolve host: docker.mirrors.ustc.edu.cn`; `curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to mirror.baidubce.com:443`; pulls that "randomly" work sometimes and hang for tens of seconds other times; `docker pull` of an image you can see on hub.docker.com in a browser
**First seen**: 2026-07
**Affects**: Docker Engine (any version) on a GFW host with `registry-mirrors` configured; measured on 29.6.2 rootless / Ubuntu 24.04
**Status**: fixed — the managed mirror list was cut from five entries to one (2026-07); `docker-net mirrors` re-measures on demand

## Symptom

```
$ docker pull hello-world:1.2
Error response from daemon: unknown: failed to resolve reference
"docker.io/library/hello-world:1.2": unexpected status from HEAD request to
https://docker.m.daocloud.io/v2/library/hello-world/manifests/1.2?ns=docker.io: 403 Forbidden
```

The phrase **"failed to resolve reference"** reads as *"that image/tag does not exist"*. It usually does exist. Read the URL in the second half of the message: it names the host that actually answered, and here it is a mirror, not Docker Hub.

Other shapes of the same problem:

- Pulls that take 30–60 s before succeeding (each dead mirror in the list burns a connect timeout first).
- Pulls that fail entirely one minute and work the next (whichever mirror is tried first that time).
- `docker info | grep -A10 'Registry Mirrors'` listing mirrors that all look plausible.

Probing the configured mirrors directly is what makes it obvious. Measured 2026-07 from a CN residential line:

```
$ curl -o /dev/null -sS -w '%{http_code} %{time_total}s\n' --max-time 8 --noproxy '*' https://<mirror>/v2/

docker.m.daocloud.io          401 0.047s     <- healthy (401 = registry answered, needs auth)
docker.mirrors.ustc.edu.cn    curl: (6) Could not resolve host: docker.mirrors.ustc.edu.cn
docker.nju.edu.cn             403 0.132s
mirror.iscas.ac.cn            502 0.094s
mirror.baidubce.com           curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to mirror.baidubce.com:443
```

Four of five entries in the repo's managed list were non-functional.

## Root cause

Two independent things compound.

**1. Mirror lists rot silently.** Nothing tells you an entry died. `chezmoi apply` still writes it, `docker info` still lists it, the daemon still starts. The list was written when those mirrors worked; CN academic Docker mirrors have since been shut down or restricted (USTC's domain no longer resolves at all; NJU restricts to campus IPs; Baidu's is reachable only from inside Baidu Cloud).

**2. Docker's fallback is weaker than it looks.** The daemon tries `registry-mirrors` **in order**, then `docker.io`. A dead entry is not free:

- A DNS failure or connect timeout costs the full timeout before moving on.
- A mirror that *answers* with `403`/`502` produces a hard `unexpected status from HEAD request` error, and containerd surfaces it as `failed to resolve reference` rather than quietly continuing.

A pull-through mirror also returns `403 Forbidden` for images it has not cached or has rate-limited — DaoCloud does this. So even the *healthy* mirror produces this error for the "image not in the mirror" case, which is the third distinct failure hiding behind one message.

And `registry-mirrors` only ever covers Docker Hub. For `ghcr.io` / `gcr.io` / `quay.io` / `registry.k8s.io` the list is irrelevant no matter how long it is.

## Workaround

Measure first — never edit the list from guesswork:

```bash
docker-net mirrors      # per-mirror verdict: healthy / DNS gone / 403 / 502 / TLS reset / timeout
docker-net doctor       # plus the same question asked from the DAEMON's side
```

Cut the list to what actually answers. In this repo that is
[`dot_config/docker/modify_daemon.json.tmpl`](../dot_config/docker/modify_daemon.json.tmpl); then:

```bash
chezmoi apply ~/.config/docker/daemon.json
systemctl --user reload docker      # SIGHUP — running containers survive
```

For an image no mirror carries, do not lengthen the list. Use the fallback ladder, whose third rung fetches client-side through your shell's proxy and needs no daemon restart at all:

```bash
docker-net pull ghcr.io/foo/bar:v1
```

Or give the daemon itself a proxy, once, and stop depending on mirrors for coverage:

```bash
docker-net on           # writes daemon.json `proxies`; restarts the daemon
```

## Prevention

- **Treat the mirror list as a measurement, not a preference.** Re-run `docker-net mirrors` before adding or trusting an entry.
- **Prefer one working mirror over five hopeful ones.** Extra entries buy latency on failure and, per
  [mirrors.md → Security and trust model](../docs/tools/mirrors.md#security-and-trust-model), an extra party that gets to decide what `latest` resolves to.
- **When an error names a URL, read the URL.** `failed to resolve reference` plus a mirror hostname is a mirror problem, not a missing image.
- `CLAUDE.md` requires any change to `registry-mirrors` to be mirrored into `containers.md` + `mirrors.md` (both plus `.zh-TW`) with a stated security reason.

## Related

- [docs/tools/docker-net.md](../docs/tools/docker-net.md) — the diagnostic tool and the fallback ladder
- [docs/tools/containers.md](../docs/tools/containers.md) — mirror strategy A/B, per-install-variant recipes
- [docs/tools/mirrors.md](../docs/tools/mirrors.md) — trust model for pull-through caches
- [`docker-proxy-set-but-docker-info-shows-empty`](docker-proxy-set-but-docker-info-shows-empty.md) — the other half of "my Docker networking is configured but nothing works"
- [`npm-postinstall-github-releases-hang`](npm-postinstall-github-releases-hang.md) — the same "the mirror covers the registry but not the artifact" class, npm flavour
- [DaoCloud/public-image-mirror#2328](https://github.com/DaoCloud/public-image-mirror/issues/2328) — the large-image stall
