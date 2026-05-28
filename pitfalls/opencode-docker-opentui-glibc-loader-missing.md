# OpenCode docker image: `Failed to initialize OpenTUI render library` / `ld-linux-x86-64.so.2: No such file or directory`

**Symptoms** (grep this section):

```
$ docker run -it --rm \
    -v "$PWD":/workspace -w /workspace \
    -v "$HOME/.local/share/opencode":/root/.local/share/opencode \
    ghcr.io/anomalyco/opencode
Unable to find image 'ghcr.io/anomalyco/opencode:latest' locally
latest: Pulling from anomalyco/opencode
6a0ac1617861: Pull complete
5e1c9dbe669a: Pull complete
8a3807e264ee: Pull complete
62878e53b1b7: Pull complete
Digest: sha256:11a9c42b7fb7823c33505de6119f65c94eef8ffd0fe958c939d3e304e414b4e6
Status: Downloaded newer image for ghcr.io/anomalyco/opencode:latest
Error: Unexpected error, check log file at /root/.local/share/opencode/log/2026-05-28T065324.log for more details

Failed to initialize OpenTUI render library: Failed to open library "/tmp/.79ffbc74dafffa35-00000001.so": Error loading shared library ld-linux-x86-64.so.2: No such file or directory (needed by /tmp/.79ffbc74dafffa35-00000001.so)
```

Key tells:

- Image pulls and starts (so the architecture matches the host or is being
  Rosetta-translated correctly)
- `bun` (the runtime opencode is built with) unpacks a bundled native `.so`
  to `/tmp/.<random>-00000001.so` at startup
- That `.so` is linked against the **glibc** dynamic linker
  (`ld-linux-x86-64.so.2`)
- The container's libc is **musl** (Alpine) — `ld-linux-x86-64.so.2` is
  not present → loader fails → opencode exits before the TUI ever paints

**First seen**: 2026-05-28 on Intel mac (Docker Desktop, image
`ghcr.io/anomalyco/opencode:1.15.11` digest
`sha256:11a9c42b7fb7823c33505de6119f65c94eef8ffd0fe958c939d3e304e414b4e6`)

**Affects**: every host pulling the published image as of 1.15.11 (likely
also earlier — at minimum 1.15.7 onward, when the multi-arch publication
landed). Both linux/amd64 and linux/arm64 variants are Alpine-based and
inherit the same bug. Independent of host OS — reproduces on macOS Docker
Desktop, native Linux docker, and probably colima / orbstack since the
breakage is inside the container image.

**Status**: **upstream image bug** — OpenTUI native lib ABI does not match
the Alpine base. No upstream fix in the registry as of 1.15.11. Workaround
is one shell line per `docker run`; long-term solutions all require either
rebuilding the image or shipping a sibling `:debian` tag (see "Fix paths"
below).

## Why

The image is Alpine for size (~50 MB compressed vs ~250 MB for a Debian
base with bun + node + ripgrep), which is the right default for a CLI
container — but the bundled OpenTUI render library (one of opencode's
runtime dependencies, shipped as a precompiled native `.so` and unpacked
to `/tmp` by bun at startup) is **glibc-linked**.

Verification from a fresh shell into the image:

```sh
$ docker inspect ghcr.io/anomalyco/opencode:latest --format '{{.Os}}/{{.Architecture}}'
linux/amd64

$ docker run --rm --entrypoint sh ghcr.io/anomalyco/opencode:latest -c '
    cat /etc/os-release | head -3
    uname -m
    ldd --version 2>&1 | head -1
    ls /lib/ld-musl* /lib64/ld-linux* /lib/ld-linux* 2>&1'
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.23.4
x86_64
musl libc (x86_64)
/lib/ld-musl-x86_64.so.1
ls: /lib64/ld-linux*: No such file or directory
ls: /lib/ld-linux*: No such file or directory
```

So:
- Container's only loader is `/lib/ld-musl-x86_64.so.1` (musl)
- The OpenTUI `.so` declares a `NEEDED` entry for `ld-linux-x86-64.so.2`
  (glibc) — Alpine doesn't have it, fail at first `dlopen`
- bun's runtime gives up before opencode can render anything

It is **not** a Rosetta / x86-on-arm64 emulation issue — confirmed by
running the same image on a native amd64 host. The architecture is
correct; the libc is wrong.

## Workaround (per-run)

Alpine ships a glibc-shim package called `gcompat`. Installing it inside
the container provides the missing loader symbol:

```sh
docker run --rm --entrypoint sh ghcr.io/anomalyco/opencode:latest \
  -c 'apk add --no-cache gcompat >/dev/null 2>&1 && opencode --version'
# 1.15.11
```

So the full working invocation becomes:

```sh
docker run -it --rm \
  -v "$PWD":/workspace -w /workspace \
  -v "$HOME/.local/share/opencode":/root/.local/share/opencode \
  -e TERM -e COLORTERM -e LANG -e TZ \
  --entrypoint sh \
  ghcr.io/anomalyco/opencode \
  -c 'apk add --no-cache gcompat >/dev/null 2>&1; exec opencode "$@"' -- "$@"
```

Cost: ~1 MB and one `apk add` per container start (since `--rm` discards
the layer). For interactive use the latency is negligible.

The wrapper-to-be in [`backlog/opencodebox-wrapper.md`](../backlog/opencodebox-wrapper.md)
absorbs this so users don't have to remember it.

## Verifying the workaround stuck

If you see the `Failed to initialize OpenTUI render library` line even
after adding `gcompat`, double-check:

1. The `--entrypoint sh` override is present — the image's default
   ENTRYPOINT is `opencode`, which runs **before** any `apk add` chance.
   Without `--entrypoint sh`, the `-c` payload is passed as opencode args
   instead of being interpreted as a shell command.
2. `apk add` actually succeeded — try without `>/dev/null 2>&1` once to
   see the apk output. Common cause: blocked egress to `dl-cdn.alpinelinux.org`
   on locked-down corporate networks.
3. `exec opencode "$@"` (not just `opencode "$@"`) — otherwise opencode
   runs as a child of `sh`, which intercepts signals and produces a less
   clean Ctrl-C experience.

## Fix paths

### A. Wait for an upstream image with glibc base (preferred)

Track <https://github.com/anomalyco/opencode/pkgs/container/opencode>. If
a `:debian` / `:bookworm` tag appears, switch the wrapper's default image
to that and drop the `apk add gcompat` step.

### B. Build a derived image locally that pre-bakes `gcompat`

```dockerfile
# Dockerfile
FROM ghcr.io/anomalyco/opencode:latest
RUN apk add --no-cache gcompat
ENTRYPOINT ["opencode"]
```

```sh
docker build -t opencode:gcompat .
docker run -it --rm \
  -v "$PWD":/workspace -w /workspace \
  -v "$HOME/.local/share/opencode":/root/.local/share/opencode \
  opencode:gcompat
```

Pros: no per-run `apk add` latency; clean entrypoint. Cons: needs rebuild
on every upstream tag; adds a maintenance surface this repo doesn't
currently have.

### C. Use the native install (current primary path)

`~/.opencode/bin/opencode` installed by the just-shipped
`coding_agents` ansible role (`dot_ansible/roles/coding_agents/tasks/main.yml:73-107`,
official installer with `--no-modify-path`) avoids the whole container
question. Reach for the container only when you specifically need
sandboxing / ephemerality.

## Related

- Backlog item that would productionize the workaround: [`backlog/opencodebox-wrapper.md`](../backlog/opencodebox-wrapper.md)
- Adjacent musl-vs-glibc trap with prebuilt binaries on Alpine: general bun
  ecosystem issue, see <https://bun.sh/docs/runtime/alpine> ("Alpine
  requires `glibc` compatibility layer (`gcompat`) for some native
  modules")
- Why we moved opencode off Homebrew formula in the first place
  (different problem, same "binary I can't actually update" pattern):
  commit message of `coding_agents` switch to official installer

## References

- Image registry: <https://github.com/anomalyco/opencode/pkgs/container/opencode>
- gcompat package: <https://pkgs.alpinelinux.org/package/edge/community/x86_64/gcompat>
- Bun's documented Alpine caveat: <https://bun.sh/docs/runtime/alpine>
