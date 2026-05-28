# `opencodebox` wrapper for the containerized opencode image

**Status**: P? deferred — needs use-case validation
**Effort**: M (script + flag design + Brewfile/ansible touchpoints + docs)
**Related**: `dot_ansible/roles/coding_agents/tasks/main.yml` (native install,
just-shipped official-installer path); `dot_config/homebrew/Brewfile.darwin.tmpl`
(already has `cask "opencode-desktop"` for the GUI variant);
[pitfalls/opencode-docker-opentui-glibc-loader-missing.md](../pitfalls/opencode-docker-opentui-glibc-loader-missing.md)
(blocker on the raw image as of 1.15.11)

## Context

OpenCode's startup-tip rotation surfaced this:

```
Tip  Run docker run -it --rm ghcr.io/anomalyco/opencode for containerized
```

The image (`ghcr.io/anomalyco/opencode`, multi-arch linux/amd64 + linux/arm64,
~50 MB compressed, tracks each upstream release within hours) lets you run
opencode as an agent without touching the host. Native install (the
just-shipped `coding_agents` ansible role using `curl …opencode/install |
bash --no-modify-path`) stays the primary path because the image has none
of our mise/uv/cargo/brew tooling — the agent inside the container can't
run `python`, `cargo`, `mlf`, etc. unless we layer them in.

But there are real use cases the native install doesn't cover:

1. **Sandboxed agent runs** — let opencode try an aggressive refactor /
   `rm -rf` / `npm install` without risk to the host filesystem or PATH.
2. **CI / scheduled jobs** — GitHub Actions or pueue task that runs one
   opencode prompt and exits; `--rm` cleans up.
3. **Try-on-untrusted-machine** — drop into opencode on a borrowed box
   without leaving binaries / config / auth tokens behind (use a temp auth
   volume).
4. **Reproducible across hosts** — same `bun`/`node`/`ripgrep` versions
   regardless of brew vs apt vs musl on the host.

The raw `docker run` invocation needed is verbose and has at least one
must-know gotcha (the OpenTUI glibc loader bug on the Alpine base image):

```sh
docker run -it --rm \
  -v "$PWD":/workspace -w /workspace \
  -v "$HOME/.local/share/opencode":/root/.local/share/opencode \
  ghcr.io/anomalyco/opencode
# → Failed to initialize OpenTUI render library: Failed to open library "..."
#   Error loading shared library ld-linux-x86-64.so.2: No such file or directory
```

A wrapper would absorb that ceremony.

## Investigation

### Image properties (verified 2026-05-28)

```
$ docker inspect ghcr.io/anomalyco/opencode:latest --format '{{.Os}}/{{.Architecture}}'
linux/amd64

$ docker run --rm --entrypoint sh ghcr.io/anomalyco/opencode:latest \
    -c 'cat /etc/os-release | head -3 && uname -m && ldd --version 2>&1 | head -1'
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.23.4
x86_64
musl libc (x86_64)
```

- Base: Alpine 3.23 (musl libc), `ENTRYPOINT ["opencode"]`, no `CMD`
- Bundled OpenTUI native `.so` is glibc-linked → fails at runtime on the
  Alpine base (see the pitfall doc for the verbatim trace + workaround
  confirmation)
- Auth state lives at `/root/.local/share/opencode/` inside the container
  (mirrors the host's `~/.local/share/opencode/`)
- Sessions / config / logs same directory tree

### Workaround for the OpenTUI loader bug

```sh
docker run --rm --entrypoint sh ghcr.io/anomalyco/opencode:latest \
  -c 'apk add --no-cache gcompat >/dev/null 2>&1 && opencode --version'
# 1.15.11
```

`apk add gcompat` provides the glibc dynamic-linker shim Alpine needs to
load glibc-built native libraries. ~1 MB. Has to run on every container
start unless we pre-bake it into a derived image. Upstream fix would be to
either base the image on `oven/bun:debian` (10× larger but no shim needed)
or build OpenTUI against musl — until then, the wrapper handles it.

### Two implementation tiers

| Tier | Form | Pros | Cons |
|---|---|---|---|
| **Lightweight** | Shell function in `dot_config/shell/<NN>_opencodebox.sh` | One file; bash + zsh both get it; matches the existing `dot_config/shell/` tier-A convention; trivial to extend with `--no-net` / `--ro` flags via case-statement | No tab completion beyond what the shell guesses; harder to ship rich `--help` |
| **Full** | Python uv-script at `dot_dotfiles/bin/executable_opencodebox` alongside `fleet` / `mlf` / `pqsum` | Rich `--help` via tyro; cross-shell completion via the hand-written eager-load pattern (`dot_config/{zsh/tools,bash}/4N_opencodebox_completion.*`); easier to add `--report` / `--archive` post-run hooks | New surface; +1 AGENTS.md cross-file row; needs uv at install time |

Default recommendation: **start lightweight**, promote to Python only if
flags multiply past ~6 or a non-trivial post-run flow gets bolted on.

### Auth / session sharing decision

Three options for the `~/.local/share/opencode` volume:

| Option | Mount | Implication |
|---|---|---|
| A. Share with host | `-v "$HOME/.local/share/opencode":/root/.local/share/opencode` | Single login; container sessions show up in host `tv agent-sessions`; **risk**: agent in container can corrupt host opencode state |
| B. Per-run ephemeral | (no mount; `--rm` wipes) | Most sandboxed; cost: re-OAuth every run |
| C. Per-project ephemeral | `-v "$PWD/.opencodebox-state":/root/.local/share/opencode` | Persistent per-project; needs `.gitignore` entry; sessions don't unify into the host's tv channel |

Wrapper default should probably be **A** (matches the convention that
`docker run … claude-code` shares auth), with `--ephemeral-auth` flag
flipping to **B** and `--project-auth` flipping to **C**.

### TTY / color / size forwarding

Without explicit handling the container terminal looks degraded:

- `-it` is mandatory (no TTY → opencode TUI exits immediately)
- `-e TERM` / `-e COLORTERM` / `-e LANG` / `-e LC_*` — forward host's
- `-e TZ` — so timestamps in sessions match host wall-clock
- Terminal size auto-detected by docker once `-it` is set; no extra flag

## Options considered

### Approach A — lightweight shell function (recommended first cut)

```sh
# dot_config/shell/<NN>_opencodebox.sh
opencodebox() {
  local image="ghcr.io/anomalyco/opencode:latest"
  local auth_mount="-v $HOME/.local/share/opencode:/root/.local/share/opencode"
  local extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ephemeral-auth) auth_mount=""; shift ;;
      --no-net)         extra_args+=("--network=none"); shift ;;
      --ro)             extra_args+=("--read-only"); shift ;;
      --tag)            image="ghcr.io/anomalyco/opencode:$2"; shift 2 ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done
  docker run -it --rm \
    -v "$PWD":/workspace -w /workspace \
    $auth_mount \
    -e TERM -e COLORTERM -e LANG -e TZ \
    --entrypoint sh "${extra_args[@]}" \
    "$image" \
    -c 'apk add --no-cache gcompat >/dev/null 2>&1; exec opencode "$@"' -- "$@"
}
```

Pros: ~25 LOC; ships with existing shared-shell layer machinery;
`opencodebox --help` can be a follow-up.

### Approach B — full Python uv-script

Mirrors `executable_pqsum` / `executable_mlf`. Justified when flag count
grows past ~6, or when a post-run pipeline (e.g. archive session to
`~/notes/opencode-box/`, summarize via `aisum`) gets bolted on. Requires
also adding completion files + AGENTS.md inventory rows + Section F entry
in `docs/zsh/zsh-completions.md`.

### Approach C — don't ship it; document the raw command in `docs/tools/opencode.md`

Lowest cost; bets on the use case being rare enough that copy-paste
suffices. Reasonable position if 3+ months pass without the
pitfalls/opencode-docker-* doc getting referenced by anyone.

## Current blocker

No concrete use case has surfaced yet — the maintainer has the native
install working well, and sandboxing hasn't bitten anyone enough to demand
the container.

## Activation triggers (any one promotes to P2 + ship Approach A)

- First time an opencode session inside `chezmoi apply` / system-cleanup
  / install-script context goes sideways and a sandbox would have saved
  the day.
- A scheduled-prompt use case (e.g. nightly "summarize today's commits via
  opencode") shows up; CI / pueue task wants ephemeral.
- The pitfall doc gets referenced by someone hitting the OpenTUI loader
  bug for the second time — signal that more than one user is trying the
  raw command.
- Upstream publishes a `ghcr.io/anomalyco/opencode:debian` (or otherwise
  fixes the glibc/musl mismatch); the `apk add gcompat` line in the
  wrapper becomes unnecessary, simplifying the implementation.

## Done-criteria when activated

- [ ] `dot_config/shell/<NN>_opencodebox.sh` (or
      `dot_dotfiles/bin/executable_opencodebox` if Approach B)
- [ ] `--help` output covers: cwd mount, auth-share/-ephemeral/-project,
      `--no-net` / `--ro`, `--tag` / `:latest` override
- [ ] Pre-flight: `docker info >/dev/null 2>&1` or warn-and-bail
- [ ] Row in `docs/shells/aliases.md` (Approach A) or the catalog +
      Section F + AGENTS.md cross-file row (Approach B)
- [ ] Cross-reference from the OpenTUI glibc pitfall doc:
      "if you're hitting this often, use `opencodebox`"
- [ ] Move this entry to `TODO.md` `## Done`

## References

- Image: <https://github.com/anomalyco/opencode/pkgs/container/opencode>
- Pitfall (loader bug): [pitfalls/opencode-docker-opentui-glibc-loader-missing.md](../pitfalls/opencode-docker-opentui-glibc-loader-missing.md)
- Native install path (current primary): `dot_ansible/roles/coding_agents/tasks/main.yml:73-107`
- Convention precedent — shell-function tier: `dot_config/shell/22_sesh.sh`
- Convention precedent — Python uv-script tier: `dot_dotfiles/bin/executable_mlf`, `dot_dotfiles/bin/executable_pqsum`
