# Config file conventions

A quick tour of the dotfile / config organisation patterns this repo
uses, why each exists, and where to place new files.

This is a **conventions reference**, not a chezmoi tutorial — for
chezmoi mechanics see [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md)
and [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md). For
the shell-specific tier rule see
[`shells/architecture.md`](../shells/architecture.md).

---

## A. Where configs live

### A1. XDG Base Directory Specification

[freedesktop.org spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html);
the modern default. Four env vars carve up `$HOME` into purpose-tagged
subtrees:

| Env var             | Default                | What goes there |
| ------------------- | ---------------------- | --------------- |
| `$XDG_CONFIG_HOME`  | `~/.config/`           | User config (this is where 90% of modern tools land) |
| `$XDG_DATA_HOME`    | `~/.local/share/`      | App data, tool installs (mise toolchains, oh-my-zsh, blesh, …) |
| `$XDG_CACHE_HOME`   | `~/.cache/`            | Disposable caches (zsh history search cache, bat cache, …) |
| `$XDG_STATE_HOME`   | `~/.local/state/`      | Runtime state (less critical than data; used less often) |
| `$XDG_RUNTIME_DIR`  | `/run/user/$UID/`      | Volatile, sub-second-scope IPC sockets (Linux only) |

Tools that follow XDG (most modern ones): nvim, git, mise, starship,
zoxide, direnv, bat, eza, atuin, zellij, gh, fd, ripgrep.

Tools that **don't** follow XDG (stuck for backwards-compat):
- bash (`~/.bashrc`, `~/.bash_profile`)
- zsh (`~/.zshrc` — but supports `ZDOTDIR` redirect)
- ssh (`~/.ssh/`)
- some older tools (`~/.tmux.conf`, `~/.gemrc`, `~/.npmrc`, `~/.curlrc`)

In this repo: `dot_config/{nvim,git,mise,starship,zoxide,direnv,bat,
eza,atuin,zellij,gh,fd,ripgrep,zsh,bash,shell}/` — XDG locations.

**Rule — prefer XDG to keep `$HOME` tidy.** When a tool supports *both* a
dotfile at `$HOME` root **and** an XDG path (`~/.config/<tool>/…`), manage the
**XDG** copy (`dot_config/<tool>/…`), not the `$HOME`-root dotfile. A clean
`$HOME` is the goal; only fall back to a root dotfile when the tool genuinely
can't read XDG (see A2 — bash, ssh, the classic `~/.gitconfig`, etc.). Confirm
the tool's XDG support + lookup order from its docs before choosing the path.

> **Watch for "both locations = error" tools.** Some tools search *both* paths
> and **abort** if both exist rather than picking one. AeroSpace is the canonical
> case: it reads `~/.aerospace.toml` **and** `~/.config/aerospace/aerospace.toml`
> and reports an ambiguity error when both are present. So when migrating such a
> tool to XDG, also remove the legacy root dotfile — we do this via a gated
> `.chezmoiremove` entry (`smart` backup captures it first). See
> [`dot_config/aerospace/aerospace.toml`](../../dot_config/aerospace/aerospace.toml)
> + the `.aerospace.toml` block in `.chezmoiremove`.

### A2. Tool-specific dirs (pre-XDG)

OpenSSH lives in `~/.ssh/` with strict 0700 perms. Bash insists on
`~/.bashrc` / `~/.bash_profile` at `$HOME`. tmux defaults to
`~/.tmux.conf` (newer versions also accept `~/.config/tmux/tmux.conf`).
We follow each tool's actual lookup order rather than fighting it.

In this repo: `dot_ssh/`, `dot_bashrc.tmpl`, `dot_zshrc.tmpl`,
`dot_gitconfig.tmpl` (also at `$HOME` — git 2.13+ also reads
`~/.config/git/config`, but `~/.gitconfig` is the classic canonical).

### A3. Platform-specific dirs

Some tools use OS-native dirs even on non-XDG:

| OS       | Convention                                    |
| -------- | --------------------------------------------- |
| macOS    | `~/Library/Application Support/<App>/`        |
| Windows  | `%APPDATA%\<App>\`                            |
| Linux    | usually XDG; sometimes `~/.<app>/`            |

In this repo: `Library/Application Support/{Code,Cursor,Antigravity}/`
(macOS-only chezmoi templates; gated in `.chezmoiignore.tmpl` per OS
to avoid creating phantom dirs on the other OS).

---

## B. How modular config is structured

### B1. Single canonical file

The simplest pattern: one rc file does everything.
Examples: `~/.gitconfig`, `~/.tmux.conf`.

Pros: easy to read top-to-bottom, no load-order surprises.
Cons: grows unwieldy past ~500 lines; merge conflicts when multiple
sources contribute.

### B2. `.d/` drop-in fragments

Old sysadmin pattern from `/etc/` (`/etc/cron.d/`, `/etc/sudoers.d/`,
`/etc/profile.d/`, `/etc/apt/sources.list.d/`). One canonical file +
a `.d/` directory; the tool loops over the dir and sources each
fragment alphabetically.

User-side examples:
- `~/.ssh/config.d/*` (OpenSSH 7.3+; pulled in by `Include config.d/*`
  directive in `~/.ssh/config`)
- `~/.bashrc.d/*` (RHEL/Rocky/Alma/Fedora skel; their `~/.bashrc`
  loops over this dir)
- `~/.bash_completion.d/*` (less standard; some completion frameworks)

Pros: drop a file → enabled. Each fragment is independent; a package
can ship one without modifying the canonical config.
Cons: order is glob-sort fragile (most use `NN_` prefixes). Tools
that don't natively support `.d/` need a manual loader.

In this repo: `dot_ssh/private_config.d/` → `~/.ssh/config.d/*`,
included by `~/.ssh/config`. Plus `~/.bashrc.d/*` is sourced as a
user backward-compat layer in `dot_bashrc.tmpl` step 11 (NOT where
we place chezmoi-managed bash configs — see B3).

### B3. Hybrid: XDG location + `.d`-style modular inside

When a tool's canonical config doesn't natively support `.d/` but we
want the modular benefits: put modular files at the XDG location and
write our own loader.

In this repo: `dot_config/{shell,zsh,bash}/NN_*.{sh,zsh,bash}` —
sourced by a `load_modular_dir` function defined in
`dot_zshrc.tmpl` / `dot_bashrc.tmpl` that globs `*.<ext>` and sources
in alphabetical order. The `NN_` filename prefix controls load order.

Why not just put these in `~/.bashrc.d/`? Because the skel's
`~/.bashrc.d` loop (on RHEL) runs from inside the original `~/.bashrc`
— after we replace that with our managed bashrc, that loop is gone.
Our own bashrc sources `~/.bashrc.d/*` at step 11 (after ble-attach),
which is too late for OMB plugin config or pre-init env. So managed
configs live in `~/.config/{shell,bash}/` (loaded mid-bashrc), and
`~/.bashrc.d/` is reserved for **user-dropped** files only.

Full deep-dive: [`shells/architecture.md`](../shells/architecture.md).

### B4. Plugin manager directories

When a tool has a plugin manager (oh-my-zsh, oh-my-bash, tpm, lazy.nvim,
direnvrc), plugins live in a dedicated dir managed by the framework:

- `~/.oh-my-zsh/custom/plugins/<plugin>/` (OMZ; cloned via
  `.chezmoiexternal.toml.tmpl`)
- `~/.oh-my-bash/custom/plugins/<plugin>/` (OMB; same pattern)
- `~/.tmux/plugins/<plugin>/` (TPM)
- `~/.config/nvim/lazy-lock.json` + `~/.local/share/nvim/lazy/<plugin>/`
  (lazy.nvim — config in XDG_CONFIG_HOME, payloads in XDG_DATA_HOME)

We don't fight these — let the framework own its dir, and clone
upstream plugins via `.chezmoiexternal.toml.tmpl` so chezmoi pulls
them weekly.

---

## C. User customisation layers (override patterns)

These are escape hatches — places where users can stash machine-
local or experimental config without polluting chezmoi-managed files.

### C1. `~/.foorc.local` include (the [include] directive pattern)

Used when the canonical config supports an "include another file"
directive. The managed file ends with a conditional include of
`~/.foorc.local`; the local file is gitignored / chezmoi-ignored.

Examples in this repo:
- `dot_gitconfig.tmpl` includes `~/.gitconfig.local` (per-machine
  `[safe]`, `[credential]`, `[http.proxy]`). Listed in
  `.chezmoiignore.tmpl` so chezmoi never tracks it. Silently
  no-ops when absent (git's `[include] path = ~/.gitconfig.local`
  is forgiving).
- `dot_ssh/dot_config` includes `~/.ssh/config.local` similarly.

When to use: tool has native include directive AND the canonical
config has stable structure that won't break on partial overrides.

### C2. `~/.foorc.adhoc` self-sourced tail (our chezmoi-ignored pattern)

Used when there's no native include directive — we hand-roll one at
the end of the managed rc:

```bash
# end of dot_zshrc.tmpl / dot_bashrc.tmpl
[ -r "$HOME/.zshrc.adhoc" ] && . "$HOME/.zshrc.adhoc"
```

Auto-created on first apply with a header comment. Listed in
`.chezmoiignore.tmpl`. Sourced LAST so the user always wins on
conflict.

When to use: shell rc files where we want a per-machine override
without forcing the user to learn chezmoi templates. See `dot_zshrc
.tmpl` and `dot_bashrc.tmpl` for the canonical examples.

### C3. distro skel conventions (`~/.bash_aliases`, `~/.bashrc.d/*`)

Files / dirs that distro `/etc/skel/` configs tell users to populate.
Not chezmoi-managed; we just source them for backward-compat so
existing user content survives our managed rc taking over.

Examples:
- `~/.bash_aliases` — Debian / Ubuntu skel sources this; our managed
  bashrc step 11 also sources it.
- `~/.bashrc.d/*` — RHEL / Rocky / Alma / Fedora skel loops over it;
  our managed bashrc step 11 also loops.
- `~/.profile` / `~/.bash_profile` — login-shell entry; our
  `dot_bash_profile.tmpl` checks for `~/.profile` and sources it
  before `~/.bashrc` (with a `grep` guard against double-sourcing).

When to use: only for **user-side** legacy compat. Our chezmoi-
managed configs DON'T live here.

### C4. Secrets files (gitignored / chezmoi-ignored)

Per-machine API keys, tokens, proxy URLs — never tracked. Sourced
by the managed rc, presence-gated:

```bash
[ -r "$HOME/.config/zsh/secrets.zsh" ] && . "$HOME/.config/zsh/secrets.zsh"
```

Listed in `.chezmoiignore.tmpl`. We also have a baseline-seed
pattern via `create_99_local_proxy.zsh` (chezmoi creates it once,
then never touches contents).

When to use: anything that contains credentials. The
[`secrets`](https://www.chezmoi.io/user-guide/encryption/age/) topic
in chezmoi docs covers encrypted alternatives if "gitignored" isn't
strong enough.

---

## D. Chezmoi-specific conventions (file prefixes & meta-files)

For full mechanics see [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md)
and [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md). The
TL;DR:

| Prefix / suffix     | Behaviour                                                   |
| ------------------- | ----------------------------------------------------------- |
| `dot_X`             | Deploys to `~/.X`                                            |
| `private_X`         | Deploys with mode 0600                                       |
| `executable_X`      | Deploys with mode 0755 (or +x bit set)                       |
| `*.tmpl`            | Templated; rendered at apply time                            |
| `modify_X`          | Script that takes current target on stdin, writes new on stdout (jq overlays, etc.) |
| `create_X`          | Seed once; chezmoi never touches contents after creation     |
| `run_once_before_*` | One-shot pre-apply scripts                                   |
| `run_onchange_after_*` | Re-runs on hash change of inlined dependencies            |

| Meta-file                         | Purpose                                       |
| --------------------------------- | --------------------------------------------- |
| `.chezmoi.toml.tmpl`              | User config (prompts → data values)            |
| `.chezmoiignore.tmpl`             | Source files to skip / OS-conditional gates   |
| `.chezmoiremove`                  | Paths to delete from `$HOME` on apply (migrations) |
| `.chezmoiexternal.toml.tmpl`      | Upstream sources (git clones, file downloads) |
| `.chezmoidata*`                   | Static data injected into all templates       |
| `.chezmoiscripts/`                | Run-scripts not deployed as files             |

---

## E. Other related conventions worth knowing

### E1. PATH directory conventions

| Directory             | Convention | What lives there |
| --------------------- | ---------- | ---------------- |
| `~/.dotfiles/bin/`    | This repo  | chezmoi-managed user scripts (source: `dot_dotfiles/bin/executable_*`) — fleet, sms, mi-router, sesh-preview, x |
| `~/bin/`              | Old POSIX  | Legacy / user-placed binaries (transitional; PATH entry will be removed once every host has cleaned up the old `~/bin/*` chezmoi-deployed copies) |
| `~/.local/bin/`       | XDG-ish    | Auto-installed CLIs (uv, mise, chezmoi, just, fd, eza, `go install`, …) |
| `~/.cargo/bin/`       | Rust       | cargo-installed binaries |
| `~/.local/share/go/`  | Go (XDG)   | `GOPATH` — module cache (`pkg/mod`); **not** on PATH. `go install` targets go to `~/.local/bin` (GOBIN), so `~/go` is never created |
| `~/.bun/bin/`         | Bun        | bun runtime + globally-installed JS CLIs |
| `~/Library/pnpm/`     | macOS pnpm | pnpm global store |
| `/opt/homebrew/bin/`  | macOS brew | Apple Silicon brew |
| `/usr/local/bin/`     | macOS brew | Intel brew & legacy `/usr/local` |

Order in our `dot_config/shell/00_exports.sh.tmpl` is deliberate:
later prepends win, so `$HOME/bin` and `$HOME/.local/bin` end up at
the front.

### E2. Lock files

Lock files pin transitive dep versions. Some are chezmoi-managed,
some are gitignored, some are seed-once:

| File                                      | Pattern              | Why |
| ----------------------------------------- | -------------------- | --- |
| `uv.lock`                                 | tracked              | reproducible Python tool installs |
| `.chezmoi.toml`                           | gitignored           | output of `chezmoi init`, machine-local |
| `~/.config/nvim/lazy-lock.json`           | `create_` (seed once) | chezmoi never touches after first apply |
| `~/.agents/.skill-lock.json`              | `modify_` (jq merge) | chezmoi-managed AND mergeable |

The choice of pattern depends on whether the file should be
identical across machines, partly identical, or fully machine-local.

### E3. Login vs interactive vs non-interactive shell loading

Bash and zsh distinguish three shell modes; each reads different
files:

| Mode                  | Bash reads                                   | zsh reads                          |
| --------------------- | -------------------------------------------- | ---------------------------------- |
| Login (TTY/SSH login) | `/etc/profile`, then first of `~/.bash_profile`/`~/.bash_login`/`~/.profile` | `/etc/zprofile`, `~/.zprofile`, `/etc/zlogin`, `~/.zlogin` (and `.zshenv` always) |
| Interactive non-login | `/etc/bash.bashrc`, `~/.bashrc`              | `~/.zshenv`, `~/.zshrc`            |
| Non-interactive (scripts) | nothing (unless `BASH_ENV` set)         | `~/.zshenv` only                   |

Implication: **env vars that need to be available to scripts** must
go in `~/.zshenv` (zsh) or be exported via `~/.profile` (bash login
chain) — not `~/.zshrc` / `~/.bashrc` (interactive only).

In this repo: most env vars live in `dot_config/shell/00_exports.sh.tmpl`
which gets sourced from BOTH `~/.bashrc` AND `~/.zshrc` — interactive
shells only. Things that genuinely need non-interactive scope (PATH
for `cron`, `ssh user@host cmd`) belong in `~/.profile` /
`~/.zshenv` instead. We accept this tradeoff because: (a) most
non-interactive scripts set their own PATH, (b) cron scripts should
hardcode tool paths anyway for reproducibility.

### E4. Filename-prefix ordering

When a `.d/`-style or hybrid loader sorts files alphabetically,
filename prefixes encode load order:

```
dot_config/shell/
├── 00_exports.sh.tmpl     ← runs first  (env / PATH)
├── 01_starship.sh         ← prompt init (after env)
├── 02_legacy_tools.sh     ← legacy PATH additions
├── 05_mise.sh             ← runtime manager
├── 10_aliases.sh          ← aliases (after env)
├── 10_fzf.sh
├── 20_zoxide.sh
├── 27_thefuck.sh
└── 30_direnv.sh           ← runs last
```

Convention: `00–09` for env / PATH, `10–19` for prompt + tools that
depend on env, `20–29` for navigation / utility tools, `30+` for
late hooks (direnv, OSC 133, etc). Leave gaps for future inserts —
prefer `15_` to inserting between `10_` and `11_`.

### E5. Per-OS / per-profile gating in templates

When the same source needs different behavior per OS or profile, two
patterns:

1. **chezmoi template `if`** at template-render time:
   ```go
   {{ if eq .chezmoi.os "darwin" -}}
       eval "$(/opt/homebrew/bin/brew shellenv)"
   {{ else -}}
       # Linuxbrew path
   {{ end -}}
   ```

2. **runtime detection** at source-time:
   ```bash
   if [ -n "$ZSH_VERSION" ]; then
       eval "$(starship init zsh)"
   elif [ -n "$BASH_VERSION" ]; then
       eval "$(starship init bash)"
   fi
   ```

When to use: chezmoi template if the diff is large (whole conditional
blocks of config) or if the value is fixed at apply time. Runtime
detection if the same file needs to work in different shells (our
shared layer) or under different runtime conditions (presence of a
binary).

Don't double-gate: if a chezmoi template `if` already excludes a
branch, the runtime check inside it is dead code. Pick one.

---

## F. Cross-references

- [`tools/chezmoi-templating.md`](../tools/chezmoi-templating.md) —
  the chezmoi template language, OS detection, when to use templates
  vs static files.
- [`tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md) — full
  catalog of `dot_`, `private_`, `executable_`, `modify_`, `create_`
  prefix semantics with case studies.
- [`shells/architecture.md`](../shells/architecture.md) — three-tier
  shell layout (`dot_config/shell/` vs `dot_config/zsh/` vs
  `dot_config/bash/`), migration story, future-shell extension.
- [`shells/aliases.md`](../shells/aliases.md) — alias / function
  inventory keyed by source file.
- [`tools/agent-overlays.md`](../tools/agent-overlays.md) — case
  study of `modify_` prefix for jq-based config overlays.
- [`CLAUDE.md`](../../CLAUDE.md) — agent-facing maintenance contract;
  cross-file rules (`README.md`, `mkdocs.yml`, `docs/`,
  `docs/shells/aliases.md` updates).
