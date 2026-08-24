# Zsh & Bash Completions

How tab completions are organized in this dotfiles project — for both upstream tools and in-house CLIs (`fleet`, `mlf`, `pqsum`, `mi-router`, `x`).

## How autocomplete works (mechanics)

Tab completion is the same idea on both shells but the plumbing differs.

### zsh — `compinit` + `fpath` + autoload `_<tool>` functions

1. **`compinit`** scans every directory in `$fpath` for files starting with `_` and registers them as completion candidates. Run by oh-my-zsh once at startup.
2. **`$fpath`** is zsh's function search path. Order in this repo (`dot_zshrc.tmpl:67-70`):
   ```
   ~/.zfunc                                             ← user-generated (this repo's lazy autoload target)
   ~/.oh-my-zsh/custom/plugins/zsh-completions/src/     ← community (184 tools)
   ~/.docker/completions/                               ← Docker-shipped
   $(brew --prefix)/share/zsh/site-functions/           ← Homebrew-managed
   ```
3. **The first line of each file** matters: `#compdef <name>` tells zsh which command to bind to. If you write `#compdef fleet`, then `fleet<TAB>` invokes the file's `_fleet` function.
4. **Autoload vs eager-load**: a file in `$fpath` is *parsed* the first time the user actually TABs the command (lazy). Files sourced explicitly at startup (e.g. via `load_modular_dir` in this repo) call `compdef _<func> <cmd>` directly — parsed eagerly, no need to be in `$fpath`.
5. **`_arguments` DSL** (zsh-only) lets you describe options + positional args declaratively: `'--hosts=[help text]:hosts:_fleet_hosts_csv'` defines the flag, hint, and a custom completer function. See `dot_config/zsh/tools/45_fleet_completion.zsh`.

### bash — `bash-completion v2` + `complete -F` + `COMPREPLY`

1. **bash-completion v2** is sourced at shell startup by `dot_config/bash/03_completion.bash`. It auto-loads completion files on first TAB.
2. **The user dir** is `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/` — drop a file named after the command (e.g. `mi-router`) here and v2 lazy-loads it on TAB.
3. **`complete -F _func cmd`** registers a bash function as the completer for `cmd`. The function reads `$COMP_WORDS` / `$COMP_CWORD` and writes candidates to `$COMPREPLY`.
4. **`_init_completion` + `compgen`** are bash-completion v2 helpers — `_init_completion` populates `cur`/`prev`/`words`/`cword`; `compgen -W "list" -- "$cur"` filters a wordlist by the current prefix.
5. **Eager vs lazy** mirrors zsh: a file in the user dir is lazy; a file sourced via `load_modular_dir` (this repo's `dot_config/bash/`) calls `complete -F` immediately.

### Three generation strategies in this repo

| Strategy | Where the file lives | Trigger | Best for |
|---|---|---|---|
| **A. Lazy autoload** | zsh `~/.zfunc/_<tool>` / bash `${XDG_DATA_HOME}/bash-completion/completions/<tool>` | First TAB on the command | Tools that ship `--print-completion <shell>` or similar (tyro, click, clap-derive — including this repo's `mi-router`) |
| **B. Eager-load at startup** | `dot_config/zsh/tools/<NN>_<tool>_completion.zsh` + `dot_config/bash/<NN>_<tool>_completion.bash` | Sourced via `load_modular_dir` after compinit / bash-completion v2 init | Hand-written completion (this repo's `fleet`, `mlf`, `pqsum`, `x`) |
| **C. Cached eval at startup** | `${XDG_CACHE_HOME}/<shell>/<tool>_completion.<ext>` | Sourced via shell `init` script (`dot_config/shell/<NN>_<tool>.sh`) | Slow generators whose output has side effects beyond `compdef` (e.g. `thefuck --alias` outputs an `alias` line — needs to land in the running shell's namespace, not just a deferred `_<tool>` function) |

Cache invalidation in classes A and C uses **binary-mtime check**:
```sh
[ ! -f "$cache" ] || [ "$(command -v <tool>)" -nt "$cache" ]  # → regenerate
```
This catches `brew upgrade`, `uv tool upgrade`, `mise install <NEW>` — anything that bumps the binary's mtime. Manual `<tool>-update-completion` helpers (in `dot_config/{shell,zsh}/10_aliases.zsh`) cover edge cases (gem-only upgrades, in-place replacements, cache corruption).

## Architecture

```
compinit runs once (inside oh-my-zsh.sh)
        │
        ├── ~/.zfunc/                          ← user-generated completions (NOT tracked by chezmoi)
        ├── ~/.oh-my-zsh/custom/plugins/       ← community completions (184 files, cloned by ansible)
        │     └── zsh-completions/src/
        ├── ~/.docker/completions/             ← Docker-shipped completions
        ├── $(brew --prefix)/share/zsh/        ← Homebrew-managed completions (via `brew completions link`)
        │     └── site-functions/
        └── $ZSH/completions/                  ← oh-my-zsh built-in completions
```

All `fpath` additions are in `dot_zshrc.tmpl` **before** `source "$ZSH/oh-my-zsh.sh"`, so `compinit` runs exactly once and picks up everything.

## Completion Categories

Tools fall into four categories:

### A. Self-generating (`tool completion zsh > ~/.zfunc/_tool`)

Most modern CLI tools can output their own completion script. **Auto-generated for both shells** by the `chezmoi apply` hook (`run_after_50_generate_completions.sh.tmpl` → `scripts/generate_completions.sh`); see [Generating Completions After Fresh Install](#generating-completions-after-fresh-install) for opt-out + manual rerun.

| Tool | Command |
|------|---------|
| `uv` | `uv generate-shell-completion zsh` |
| `mise` | `mise completion zsh` |
| `chezmoi` | `chezmoi completion zsh` |
| `just` | `just --completions zsh` |
| `bat` | `bat --completion zsh` |
| `delta` | `delta --generate-completion zsh` |
| `starship` | `starship completions zsh` |
| `rg` | `rg --generate complete-zsh` |
| `fd` | `fd --gen-completions zsh` |
| `zellij` | `zellij setup --generate-completion zsh` |
| `sesh` | `sesh completion zsh` |
| `pueue` | `pueue completions zsh` |
| `docker` | `docker completion zsh` |
| `gh` | `gh completion -s zsh` |
| `opencode` | `opencode completion zsh` |
| `bw` | `bw completion --shell zsh` |

**Usage pattern:**

```bash
# Generate once (or after upgrade)
mkdir -p ~/.zfunc
uv generate-shell-completion zsh > ~/.zfunc/_uv
mise completion zsh > ~/.zfunc/_mise
```

### B. Pre-bundled (no action needed)

Completions ship with the package or via the `zsh-completions` community plugin.

| Tool | Source |
|------|--------|
| `eza` | Homebrew formula installs `_eza` into site-functions |
| `git` | oh-my-zsh `git` plugin |
| `yazi` | Ships `_yazi` in release assets (also in zsh-completions) |
| `lazygit` | No completion support; not needed (TUI app) |
| `btop` | No completion support; not needed (TUI app) |
| Many others | `zsh-completions` plugin covers 184 tools |

### C. Eval/source at startup (shell integration)

These tools inject completions as part of broader shell integration. Most live in the POSIX `dot_config/shell/` layer (sourced by both zsh and bash); zsh-only ones live in `dot_config/zsh/tools/`.

| Tool | Where | How | Cached? |
|------|-------|-----|---------|
| `fzf` | `dot_config/shell/10_fzf.sh` | `eval "$(fzf --zsh)"` (zsh) / `eval "$(fzf --bash)"` (bash) | — |
| `zoxide` | `dot_config/shell/20_zoxide.sh` | `eval "$(zoxide init <shell>)"` | — |
| `direnv` | `dot_config/shell/30_direnv.sh` | `eval "$(direnv hook <shell>)"` | — |
| `marimo` | `dot_config/shell/29_marimo.sh` | `_MARIMO_COMPLETE=<shell>_source marimo` | ✅ `${XDG_CACHE_HOME}/{zsh,bash}/marimo_completion.{zsh,bash}` — refresh via `marimo-update-completion` |
| `thefuck` | `dot_config/shell/27_thefuck.sh` | `thefuck --alias` | ✅ `${XDG_CACHE_HOME}/{zsh,bash}/thefuck_alias.{zsh,bash}` — refresh via `thefuck-update-completion` |
| `try-cli` | `dot_config/zsh/tools/32_try.zsh` | `ruby try.rb init` (zsh-only) | ✅ `${XDG_CACHE_HOME}/zsh/try_init.zsh` — refresh via `try-update-completion` |

> **Cached entries** auto-invalidate when the tool's binary mtime is newer than the cache file (`[ "$(command -v <tool>)" -nt "$cache" ]`) — catches `mise install <NEW>`, `brew upgrade`, `uv tool upgrade`. Manual refresh helpers handle edge cases: gem-only upgrades that don't bump the ruby binary, in-place tool replacements, or cache corruption. The pattern mirrors `dot_config/zsh/tools/95_bitwarden.zsh` (the canonical example).

### D. No completion support

`claude`, `gemini`, `agy`/`agyc` (Antigravity CLI), `btop`, `lazygit` -- no generation command available.

### E. Python tools via `shtab` / `tyro` / `click` / `argcomplete`

Python CLI frameworks can generate completions. Pick by what your script uses:

- **[tyro](https://brentyi.github.io/tyro/tab_completion/)** (this repo's `mi-router` + every `scripts/fleet/*.py` and `scripts/mlf/*.py` subcommand): `<tool> --tyro-write-completion zsh <path>`. Native flag — auto-added when you call `tyro.cli(...)`. tyro emits `#compdef <full-binary-path>` for zsh, so post-process the first line to the short name (see `dot_config/shell/47_mi_router.sh` for the canonical pattern). Bash output already binds `basename`, no fixup needed.
- **[shtab](https://github.com/iterative/shtab)**: `shtab --shell=zsh my_module.parser > ~/.zfunc/_my_tool`. Decorate-an-`argparse.ArgumentParser` style; works for both shells.
- **argcomplete**: `register-python-argcomplete tool_name` (eval-at-startup style, category C). Requires the script to call `argcomplete.autocomplete(parser)` before `parse_args()`. Cross-shell.
- **click** (used by `marimo`, `thefuck`, `mlflow`, `litellm`, etc.): `_TOOL_COMPLETE=zsh_source tool > ~/.zfunc/_tool`. The completion script may include side effects (aliases / functions) — if so, treat as category C and cache via `${XDG_CACHE_HOME}/<shell>/<tool>_completion.<ext>`. See the canonical pattern at `dot_config/shell/29_marimo.sh`.

> **TAB display itself**, not just completion data: see [`oh-my-zsh-plugins.md`](oh-my-zsh-plugins.md) "TAB display upgrades — alternatives evaluated" for fzf-tab (recommended) and rejected alternatives (zsh-autocomplete / carapace-bin / inshellisense).

### F. In-house CLIs (this repo)

| CLI | Source | Framework | Strategy | Files |
|---|---|---|---|---|
| `mi-router` | `dot_dotfiles/bin/executable_mi-router` | tyro | A (lazy autoload) | `dot_config/shell/47_mi_router.sh` (gen + mtime check); refresh helper `mi-router-update-completion` |
| `mi-dhcp-bind` | `dot_dotfiles/bin/executable_mi-dhcp-bind` | tyro | A (lazy autoload) | `dot_config/shell/46_mi_dhcp_bind.sh` (gen + mtime check); refresh helper `mi-dhcp-bind-update-completion` |
| `reyee` | `dot_dotfiles/bin/executable_reyee` | tyro | A (lazy autoload) | `dot_config/shell/48_reyee.sh` (gen + mtime check); refresh helper `reyee-update-completion` |
| `tsnet` | `dot_dotfiles/bin/executable_tsnet` | tyro | A (lazy autoload) | `dot_config/shell/49_tsnet.sh` (gen + mtime check); refresh helper `tsnet-update-completion`. Machine names are deliberately **not** dynamic candidates — enumerating the tailnet on every TAB round-trips the tailscaled socket; use `tv tailnet` instead |
| `ping-monitor` | `dot_dotfiles/bin/executable_ping-monitor` | bash hand-rolled | B | `dot_config/zsh/tools/50_ping_monitor_completion.zsh` + `dot_config/bash/50_ping_monitor_completion.bash` |
| `fleet` | `dot_dotfiles/bin/executable_fleet` + `scripts/fleet/*.py` | hand-rolled umbrella + tyro/argparse subs | B (eager hand-written) | `dot_config/zsh/tools/45_fleet_completion.zsh` + `dot_config/bash/45_fleet_completion.bash` |
| `mlf` | `dot_dotfiles/bin/executable_mlf` + `scripts/mlf/*.py` | hand-rolled umbrella + tyro subs | B | `dot_config/zsh/tools/46_mlf_completion.zsh` + `dot_config/bash/46_mlf_completion.bash` |
| `pqsum` | `dot_dotfiles/bin/executable_pqsum` | argparse | B | `dot_config/zsh/tools/48_pqsum_completion.zsh` + `dot_config/bash/48_pqsum_completion.bash` |
| `x` | `dot_dotfiles/bin/executable_x` | bash hand-rolled | B | `dot_config/zsh/tools/49_x_completion.zsh` + `dot_config/bash/49_x_completion.bash` |
| `dotcfg` | `dot_dotfiles/bin/executable_dotcfg` (thin shell → `scripts/init/dotfiles_init.py reconfigure`) | bash wrapper | B | `dot_config/zsh/tools/51_dotcfg_completion.zsh` + `dot_config/bash/51_dotcfg_completion.bash` (keys mirror PROMPTS) |
| `agent-warmup` | `dot_dotfiles/bin/executable_agent-warmup` | argparse (subcommands) | B | `dot_config/zsh/tools/52_agent_warmup_completion.zsh` + `dot_config/bash/52_agent_warmup_completion.bash` |
| `yth` | `dot_dotfiles/bin/executable_yth` + `scripts/yth/*.py` | hand-rolled umbrella + tyro subs | B | `dot_config/zsh/tools/53_yth_completion.zsh` + `dot_config/bash/53_yth_completion.bash` |
| `wake` | `dot_dotfiles/bin/executable_wake` | argparse | B | `dot_config/zsh/tools/54_wake_completion.zsh` + `dot_config/bash/54_wake_completion.bash` |
| `view-office` | `dot_dotfiles/bin/executable_view-office` | bash hand-rolled | B | `dot_config/zsh/tools/55_view_office_completion.zsh` + `dot_config/bash/55_view_office_completion.bash` |
| `view-ebook` | `dot_dotfiles/bin/executable_view-ebook` | bash hand-rolled | B | `dot_config/zsh/tools/56_view_ebook_completion.zsh` + `dot_config/bash/56_view_ebook_completion.bash` |
| `appsrc` | `dot_dotfiles/bin/executable_appsrc` | argparse (subcommands) | B | `dot_config/zsh/tools/57_appsrc_completion.zsh` + `dot_config/bash/57_appsrc_completion.bash` |
| `raid-perm-check` | `dot_dotfiles/bin/executable_raid-perm-check` | bash hand-rolled | B | `dot_config/zsh/tools/58_raid_perm_check_completion.zsh` + `dot_config/bash/58_raid_perm_check_completion.bash` |
| `docker-net` | `dot_config/shell/51_docker_net.sh` (**shell function**, not a bin CLI) | shell hand-rolled | B | `dot_config/zsh/tools/58_docker_net_completion.zsh` + `dot_config/bash/58_docker_net_completion.bash`. Guard with `command -v`, **not** `$+commands` / a PATH test — the target is a function, so those never see it |
| `herdr-grep` | `dot_dotfiles/bin/executable_herdr-grep` | argparse | B | `dot_config/zsh/tools/59_herdr_grep_completion.zsh` + `dot_config/bash/59_herdr_grep_completion.bash`; `--session` candidates come from `herdr-grep --list-sessions`; `--pick` pipes filtered matches into fzf and focuses/attaches the selection |
| `ytmv` | `dot_dotfiles/bin/executable_ytmv` + `scripts/ytmv/*.py` | hand-rolled umbrella + tyro subs | B | `dot_config/zsh/tools/60_ytmv_completion.zsh` + `dot_config/bash/60_ytmv_completion.bash`; completes `help <leaf>` and `doctor --cookies`; `--profile` candidates come from `ytmv doctor --list-profiles`; enum flags (`--id3-version`, `--lrc-encoding`, `--lyrics`, …) complete their allowed values |
| `copilot-proxy` | `dot_config/shell/43_copilot_proxy.sh` (**shell function**) | shell hand-rolled | B | `dot_config/zsh/tools/61_copilot_proxy_completion.zsh` + `dot_config/bash/61_copilot_proxy_completion.bash`; completes actions, periods, scopes and benchmark/update flags |
| `aiblock` | `scripts/aiblock.py` | questionary (interactive TUI) | — (no CLI args) | (not needed) |

**Dynamic candidates wired up:**

- `fleet` host names — `_fleet_hosts_one` / `_fleet_hosts_csv` shell out to `fleet hosts --list`. Used for the positional `fleet hosts NAME`, `fleet chezmoi diff HOST`, `fleet chezmoi tail HOST`, and the `--hosts=foo,bar,baz` CSV flag everywhere.
- `pqsum -g <GROUP>` — `_pqsum` shells out to `pueue status --json | jq '.groups | keys[]'`.
- `mlf` ids (run-id, experiment-id, model-name) — **not** auto-completed (would round-trip MLflow tracking server, possibly auth-required). Use `tv mlflow` for fuzzy id picking instead.
- `yth` video ids — **not** auto-completed (opaque 11-char ids; enumerating the whole history on every TAB is wasteful). Use `tv yth` or `yth search <query>` instead.
- `wake` host names — `_wake` shells out to `wake --list-names` (reads `~/.config/wake/hosts.toml`), same pattern as `_fleet_hosts_one`.
- `appsrc which <name>` / `appsrc size <name>` — `_appsrc_names` shells out to `appsrc scan --list-names` (installed GUI app names) and adds `_command_names -e` / `compgen -c` (PATH commands), so both a GUI app name and a shell command complete. Same shell-out pattern as `_wake` / `_fleet_hosts_one`.
- `herdr-grep --session <name>` — both completion files shell out to `herdr-grep --list-sessions`, which reads the local Herdr session registry and returns sorted running names. Errors are silent so TAB still works when no Herdr server is running.
- `raid-perm-check user <name>` — `_raid_perm_check_users` reads `getent passwd` filtered to uid ≥ 1000 (real accounts, not system users). The optional trailing `ROOT` argument completes from `findmnt -rno TARGET` minus the kernel pseudo-filesystems, falling back to plain directory completion.

**Adding a new in-house CLI** (decision flow):

1. **Does it use tyro?** → Use Strategy A. Mirror `dot_config/shell/47_mi_router.sh`. Add a `<tool>-update-completion` helper to `dot_config/shell/10_aliases.sh`. Don't forget to rewrite `#compdef` in zsh post-gen.
2. **Does it use argparse?** → Two sub-options:
   - Add `argcomplete.autocomplete(parser)` to the script + Strategy C cached eval at startup.
   - Hand-write Strategy B completion (smaller / no Python dependency at every shell startup).
3. **Hand-rolled / shell script** → Strategy B hand-written. One zsh file in `dot_config/zsh/tools/<NN>_<name>_completion.zsh`, one bash file in `dot_config/bash/<NN>_<name>_completion.bash`. Mirror `_fleet`'s structure: top-level dispatcher → per-subcommand functions → dynamic helpers.
4. **Update this table + `docs/shells/aliases.md`** in the same commit (per the cross-file maintenance rule in `CLAUDE.md`).

## Why `~/.zfunc/` is NOT Tracked by Chezmoi

**Decision: `~/.zfunc/` is not version-controlled.** Rationale:

1. **Completions are tool-version-dependent.** A completion script generated by `uv 0.6` may not match `uv 0.7`. Tracking stale files causes subtle breakage.
2. **Not all users install the same tools.** A `_pueue` completion file is useless (and throws warnings) if pueue isn't installed.
3. **Regeneration is trivial.** One command per tool.
4. **Brew-installed tools auto-manage their completions** via site-functions. Duplicating them in `~/.zfunc/` creates conflicts.

### What we DO track

- `fpath+=~/.zfunc` in `dot_zshrc.tmpl` (ensures the directory is in the search path)
- `zsh-completions` plugin cloned by ansible (community completions)
- `~/.docker/completions` fpath entry
- Tool-specific `eval`/`source` integrations in `dot_config/zsh/tools/`

## Generating Completions After Fresh Install

**Automatic — no manual step needed.** Every `chezmoi apply` runs `.chezmoiscripts/global/run_after_50_generate_completions.sh.tmpl`, which calls `scripts/generate_completions.sh` and regenerates completion for the 14 self-generating tools listed in Section A (`chezmoi`, `mise`, `uv`, `just`, `starship`, `gh`, `docker`, `rg`, `fd`, `bat`, `delta`, `zellij`, `pueue`, `opencode`).

The hook is **idempotent** — it stat-checks each tool's binary mtime against the existing completion file and skips if the cache is fresh. Cost when nothing changed: **~21ms** total (presence checks + 28 stat calls). After an `ansible-playbook` / `brew upgrade` / `mise install <NEW>` that bumps a binary's mtime: ~140ms one-shot to regenerate the affected completions.

Output paths:
- **zsh**: `~/.zfunc/_<tool>` — lazy-loaded by compinit on first TAB (in `$fpath` via `dot_zshrc.tmpl:68`).
- **bash**: `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/<tool>` — lazy-loaded by bash-completion v2 on first TAB.

### Manual rerun

```bash
just completions-refresh                              # force regen all (--force)
bash scripts/generate_completions.sh --force          # same, no `just`
bash scripts/generate_completions.sh                  # mtime-checked (same as the chezmoi hook)
```

Use `just completions-refresh` after a tool upgrade outside the chezmoi flow (e.g. `cargo install <tool>`), or to recover from a corrupted completion file.

### Opt out

```bash
export CHEZMOI_SKIP_COMPLETION_GEN=1   # in ~/.shellrc.adhoc; suppresses the chezmoi-apply hook
```

Existing completion files stay as-is; you can still run `just completions-refresh` manually.

### Add a new tool to the auto-gen inventory

Edit the `regen <tool> "<zsh-args>" "<bash-args>"` block in `scripts/generate_completions.sh`. The arguments are whatever follows the tool name to produce the per-shell completion script — check `<tool> completion --help` or `<tool> --help | grep -i complet`. Examples already in the script cover click (`_TOOL_COMPLETE=`), clap (`--generate complete-<shell>`), tyro (`--tyro-write-completion <shell>`-equivalent), cobra (`completion <shell>`), and ad-hoc styles (`--completions <shell>`).

### What about tools NOT in the auto-gen inventory?

- **`sesh` / `tv` / `worktrunk`**: shell-startup mtime check (each tool has its own `dot_config/zsh/tools/<NN>_<tool>.zsh` file that runs the version check on every shell start — these tools are typically `cargo install`-ed outside chezmoi, so they need the per-startup probe to catch user upgrades).
- **`bw` / `marimo` / `thefuck` / `try-cli`**: cached eval at startup (their completion script has side effects beyond `compdef`, so the file is `source`'d into the running shell rather than autoloaded).
- **`mi-router`**: tyro self-gen, lives in `dot_config/shell/47_mi_router.sh` (not the bulk script — has its own `#compdef` rewrite for tyro's full-path output quirk).
- **`fleet` / `mlf` / `pqsum` / `x` / `dotcfg` / `agent-warmup`**: hand-written completion in `dot_config/{zsh/tools,bash}/45-54_*_completion.*` (in-house CLIs without a built-in completion generator). `dotcfg`'s `--set` key list mirrors the PROMPTS table in `scripts/init/dotfiles_init.py`.

## Priority / Override Order

When the same `_tool` file exists in multiple fpath directories, the **first match wins**:

```
1. ~/.zfunc/                                    (highest - your overrides)
2. ~/.oh-my-zsh/custom/plugins/zsh-completions/src/
3. ~/.docker/completions/
4. $(brew --prefix)/share/zsh/site-functions/   (Homebrew-managed)
5. /usr/share/zsh/*/functions/                  (system, lowest)
```

Current `dot_zshrc.tmpl` order:

```zsh
fpath+=~/.zfunc                     # appended (lowest of custom)
fpath=(zsh-completions/src $fpath)  # prepended (higher than ~/.zfunc)
fpath=(~/.docker/completions $fpath) # prepended (highest of custom)
```

If you want `~/.zfunc/` to override community completions, change to prepend:

```zsh
fpath=(~/.zfunc $fpath)  # prepend instead of append
```

## FAQ

**Q: Should I generate completions for tools that `zsh-completions` already covers?**
A: Only if you want the latest version. The community plugin may lag behind. For fast-moving tools (uv, mise), generating your own is worthwhile.

**Q: A completion file throws errors after I uninstall a tool. What do I do?**
A: Remove the file: `rm ~/.zfunc/_toolname`. Stale `_tool` files in fpath are harmless (silently ignored) unless they have syntax errors.

**Q: How do I debug completion issues?**
A: Run `echo $fpath | tr ' ' '\n'` to see all fpath entries. Use `which _toolname` to see which completion file is being used. Force rebuild with `rm -f ~/.zcompdump && compinit`.
