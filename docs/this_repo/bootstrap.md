# `bootstrap.sh` — first-touch entry for a new machine

The repo's one-liner installer:

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
```

does just three things (the script itself is ~75 lines, mostly logging):

1. **Install [`uv`](https://github.com/astral-sh/uv)** if missing (Astral's
   installer → `~/.local/bin/uv`).
2. **Reattach stdin to `/dev/tty`** so [`questionary`](https://github.com/tmbo/questionary)
   prompts inside `dotfiles_init.py` can read keystrokes (otherwise the curl
   pipe would steal stdin and the wrapper would silently fall back to
   non-interactive stubs).
3. **`exec uv run --script <URL>`** — fetches
   [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py)
   over HTTPS, resolves its PEP 723 inline deps (`questionary`, `rich`, `tyro`)
   into an ephemeral venv, runs it. No global pip install, no `pyproject.toml`.

`bootstrap.sh` is in [`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl) — `chezmoi
apply` does **not** deploy it to `$HOME/bootstrap.sh`.

## "It's been 5 minutes and there's no output — is it stuck?"

Most likely the wrapper is downloading something silently. Three layers can
each take 30 s – several minutes on a slow / throttled network with **zero
visible output**:

| Layer | What's happening | How to confirm |
|---|---|---|
| `curl https://astral.sh/uv/install.sh \| sh` | Downloading the `uv` binary tarball from GitHub Releases | `pgrep -af 'uv\|curl\|install.sh'` |
| `uv run --script <URL>` (deps stage) | Resolving + downloading `questionary`/`rich`/`tyro` wheels from PyPI; building any sdists | `lsof -p $(pgrep -f dotfiles_init) -i \| head` |
| `chezmoi init` (after prompts) | `git clone` the dotfiles repo (~MBs of submodules, agent skills, etc.) over HTTPS / SSH | `pgrep -af 'git\|chezmoi'` |

### Diagnose without killing the run

In **another shell** on the same machine:

```bash
# 1) see the full process tree under bootstrap
echo "=== process tree ==="
pgrep -af 'bootstrap|dotfiles_init|uv|chezmoi|ansible|brew|apt|git'

# 2) what is the leaf doing right now?
LEAF=$(pgrep -f 'dotfiles_init|chezmoi|ansible' | tail -1)
[ -n "$LEAF" ] && {
  ps -p "$LEAF" -o pid,ppid,etime,stat,command
  lsof -p "$LEAF" 2>/dev/null -i | head -10        # network sockets
  lsof -p "$LEAF" 2>/dev/null -p "$LEAF" | grep REG | tail -10  # files being read
}

# 3) which remote is slow?
for url in https://astral.sh https://raw.githubusercontent.com \
           https://pypi.org https://github.com https://get.chezmoi.io; do
  printf '%-40s ' "$url"
  curl -fsS --max-time 5 -o /dev/null -w 'HTTP %{http_code}  %{time_total}s\n' "$url" \
    || echo 'TIMEOUT/FAIL'
done
```

Common patterns:

- **`curl` to `astral.sh` taking >30 s** → GFW; set `https_proxy` (see below).
- **`uv` process exists but has no TCP socket** → resolver is CPU-bound on a
  big sdist build (rare for these three deps; usually means a transitive
  pulled in something heavy). Wait it out or run with `DOTFILES_BOOTSTRAP_VERBOSE=1`.
- **`git-remote-https` / `git-remote-ssh` child** → `chezmoi init` is cloning;
  GFW slowness is normal here.
- **Python process in `select()` with no children** → it's waiting for
  keyboard input. The TTY reattach failed; kill and re-run from a real
  terminal (not over a non-PTY SSH session).

### Verbose mode

Re-run with progress output everywhere:

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh \
  | DOTFILES_BOOTSTRAP_VERBOSE=1 bash
```

That sets `set -x` in `bootstrap.sh`, prints timestamped stage logs, and adds
`uv run --verbose` so you see every wheel download / venv operation.

## Skipping `bootstrap.sh` entirely (recommended on slow networks)

Once you've cloned the repo locally, you don't need the curl-piped bootstrap
at all — call the wrapper script directly via the `just` recipe:

```bash
git clone https://github.com/daviddwlee84/dotfiles ~/.local/share/chezmoi
cd ~/.local/share/chezmoi

just bootstrap-local                 # interactive (same as bootstrap.sh)
just bootstrap-local-verbose         # shows uv resolver progress

# Pass through args after `--`:
just bootstrap-local -- --yes --bundle minimal     # non-interactive
just bootstrap-local -- doctor                     # schema parity check
just bootstrap-local -- list-bundles               # see all bundles
```

Advantages:

- **No `raw.githubusercontent.com` round-trip** for the wrapper script (only
  the deps still need PyPI, and PyPI is mirrorable; see below).
- **No `/dev/tty` re-exec gymnastics** — you're already in a real shell.
- **You can `git pull` and re-run** to test wrapper changes without re-running
  the curl pipeline.
- **You can `git checkout <branch>`** and run a feature branch's wrapper
  before merging.

The only thing `bootstrap.sh` does that `just bootstrap-local` doesn't is
auto-installing `uv`. If `uv` is missing on the new host, install it once:

```bash
curl -fsSL https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

then `just bootstrap-local`.

## Behind GFW / corporate proxy

Three layers each need separate proxy/mirror config. The cheapest setup is a
local SOCKS/HTTP proxy (clash, v2ray, etc.) listening on `127.0.0.1:7890`:

```bash
# (1) shell layer — curl, git, uv installer
export https_proxy=http://127.0.0.1:7890
export http_proxy=$https_proxy
export all_proxy=socks5://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1

# (2) git layer — chezmoi init clones via git
git config --global http.https://github.com.proxy "$https_proxy"
# (or globally: git config --global http.proxy "$https_proxy")

# (3) uv / PyPI layer — switch index instead of routing through proxy
export UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# Tencent / Aliyun mirrors also work:
#   https://mirrors.cloud.tencent.com/pypi/simple
#   https://mirrors.aliyun.com/pypi/simple/
```

If `raw.githubusercontent.com` itself is the bottleneck (the very first
`curl` in the bootstrap pipeline), point at a mirror:

```bash
# ghproxy.com proxies *.githubusercontent.com transparently
export DOTFILES_RAW_URL="https://ghproxy.com/https://raw.githubusercontent.com/daviddwlee84/dotfiles"
export DOTFILES_REF=main

curl -fsSL "${DOTFILES_RAW_URL}/${DOTFILES_REF}/bootstrap.sh" | bash
```

`bootstrap.sh` itself respects `DOTFILES_RAW_URL` / `DOTFILES_REF` when
constructing the inner script URL, so the inner `uv run --script` will also
go through the mirror.

> **Caveat — jsdelivr / cdn.statically.io** style CDNs use a different URL
> scheme (`/gh/owner/repo@ref/path`) and will not work as a drop-in
> `DOTFILES_RAW_URL`. Stick with `ghproxy.com`-style transparent proxies, or
> just clone locally and use `just bootstrap-local`.

## Why bootstrap edits `~/.bashrc` and then `apply` undoes it

Step 7 of `run_once_before_00_bootstrap.sh.tmpl` appends this to `~/.bashrc`:

```bash
# Added by chezmoi bootstrap - ~/.local/bin for uv, mise, chezmoi
export PATH="$HOME/.local/bin:$PATH"
```

and a later `chezmoi diff` shows it being **removed** again (red on the left side = "on the machine now, apply will delete it" — see [cheatsheet → Reading `chezmoi diff`](cheatsheet.md#reading-chezmoi-diff--which-side-is-which)). **This is expected, and nothing is lost.**

The script is `run_once_**before**_`, so it runs before chezmoi has written a single dotfile. `chezmoi`, `uv` and `mise` all live in `~/.local/bin`, and the append is a shim for exactly that pre-apply window — it keeps them reachable if you open a bash shell before apply finishes, or if apply dies half-way. Once apply writes `~/.bashrc` from `dot_bashrc.tmpl` the shim is superseded: the managed `~/.bashrc` sources `$XDG_CONFIG_HOME/shell`, and [`dot_config/shell/00_exports.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/00_exports.sh.tmpl) already exports `PATH="$HOME/.dotfiles/bin:$HOME/bin:$HOME/.local/bin:$PATH"` for **both** shells (the in-script comment claiming "dotfiles only wire this up in zsh" is stale — `00_exports.sh` predates it).

On a normal `chezmoi init --apply` both steps happen inside one invocation, so you never see the intermediate state. You see the diff only if you look between them — e.g. bootstrap ran but the apply that rewrites `.bashrc` hasn't, or a previous apply was interrupted. Running `chezmoi apply` clears it.

Do **not** "fix" it by redirecting the append to `~/.bashrc.adhoc`: that file is an untracked [user-override surface](../shells/adhoc-and-secrets.md), so the duplicate `PATH` entry would then persist forever instead of being cleaned up.

## What the inner `dotfiles_init.py` does

See `scripts/init/dotfiles_init.py` (~836 lines) — it pre-flights chezmoi /
git / SSH, presents grouped feature-flag prompts via `questionary`, and
shells out to `chezmoi init <repo> --apply --promptString …`. Subcommands:

- `init` (default) — the interactive flow.
- `doctor` — greps `.chezmoi.toml.tmpl` + `Dockerfile` and verifies every
  prompt key is mirrored in the script's `PROMPTS` tuple. CI-friendly; exits
  non-zero on drift. See [AGENTS.md → Dockerfile + dotfiles_init wrapper](../../AGENTS.md).
- `list-bundles` — show the pre-canned feature-flag bundles
  (`personal-mac` / `work-mac` / `server-linux` / `minimal`).

## Related

- [`scripts/init/dotfiles_init.py`](../../scripts/init/dotfiles_init.py) — the wrapper.
- [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) — the prompt definitions chezmoi sees.
- [`Dockerfile`](../../Dockerfile) — the third file that must stay in sync (CHEZMOI_* build args).
- [docs/this_repo/initial_setup/](initial_setup/) — narrative walk-through of a fresh-machine install.
- [docs/this_repo/fleet-apply.md](fleet-apply.md) — once one machine is up, push to a fleet from there.
