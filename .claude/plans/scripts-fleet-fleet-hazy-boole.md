# `fleet hosts` — interactive picker for SSH'ing into fleet-configured machines

## Context

The fleet inventory at `~/.config/fleet/machines.toml` is the SSOT for every cross-host operation (`fleet chezmoi apply`, `fleet tmux`, `fleet info`, `fleet pueue`, `fleet exec`). Today you can introspect it indirectly (each command's `--hosts` flag) but there is no quick "give me a picker, let me pick one, SSH me in" path. Meanwhile `dot_config/television/cable/ssh-config.toml` already gives exactly that UX for `~/.ssh/config` via `tv ssh-config` — but fleet hosts live in TOML, not `~/.ssh/config`, and some have explicit `hostname` / `user` / `port` / `identity_file` instead of an `ssh_alias`, so a fleet-aware picker is needed.

**Outcome**: a new `tv fleet-hosts` cable (analog to `tv ssh-config`) and a `fleet hosts` umbrella subcommand backed by `scripts/fleet/hosts.py`. The Python module is the SSOT for inventory listing/preview/connect — the TV cable shells out to it, so there is no duplicate TOML parser. Direct CLI usage (`fleet hosts lab-box` to SSH straight in, `fleet hosts --list` for scripts) also works without `tv`.

## Architecture

```
~/.config/fleet/machines.toml   (existing SSOT)
            │
            ▼
scripts/fleet/hosts.py          (new — uses load_hosts() from apply.py)
            │   subcommand verbs:
            │     --list                       plain names, one per line
            │     --list-tsv                   name<TAB>target<TAB>kind     (TV source)
            │     --list-json                  full inventory JSON
            │     --describe NAME              preview text                (TV preview)
            │     --probe NAME                 BatchMode SSH probe         (Alt+T action)
            │     <NAME>                       SSH connect directly (os.execvp)
            │     (no args)                    exec `tv fleet-hosts`; fallback: numeric menu
            │
            ├──────────────────────────┐
            ▼                          ▼
dot_config/television/cable/   dot_dotfiles/bin/executable_fleet
   fleet-hosts.toml              ("hosts" added to dispatch)
   (TV cable — shells out to
    `fleet hosts --list-tsv`
    `fleet hosts --describe`
    `fleet hosts <NAME>`)
```

## Files to create

### 1. `scripts/fleet/hosts.py` (new)

PEP 723 inline-deps Python module. Uses `tomllib` (stdlib, py>=3.11) — does NOT need `asyncssh` / `rich` / `tyro`. Imports `load_hosts`, `Host`, `DEFAULT_CONFIG_PATH` from `scripts.fleet` (re-exported via `__init__.py`).

Argparse skeleton:

```python
# /// script
# requires-python = ">=3.11"
# dependencies = []  # stdlib only
# ///
"""fleet hosts — pick a fleet host, SSH in."""
from scripts.fleet import DEFAULT_CONFIG_PATH, Host, load_hosts

# Modes (mutually exclusive, dispatched in order):
#   --list / --list-tsv / --list-json        → print, exit 0
#   --describe NAME                          → print preview block, exit 0
#   --probe NAME                             → run ssh -o BatchMode=yes ... true
#   <NAME positional>                        → os.execvp("ssh", [...])
#   (no args) and tv on PATH                 → os.execvp("tv", ["tv", "fleet-hosts"])
#   (no args) and no tv                      → numeric stdin menu fallback

def _ssh_argv(host: Host) -> list[str]:
    """Build argv for `ssh ...` matching _connect_kwargs() semantics."""
    if host.ssh_alias:
        return ["ssh", host.ssh_alias]
    # Explicit fields path
    argv = ["ssh"]
    if host.port:        argv += ["-p", str(host.port)]
    if host.identity_file: argv += ["-i", str(Path(host.identity_file).expanduser())]
    target = f"{host.user}@{host.hostname}" if host.user else host.hostname
    argv.append(target)
    return argv

def _kind(host: Host) -> str:
    if host.local:       return "LOCAL"
    if host.ssh_alias:   return f"alias:{host.ssh_alias}"
    parts = [host.hostname or "?"]
    if host.port and host.port != 22: parts.append(f":{host.port}")
    return f"explicit:{host.user + '@' if host.user else ''}{''.join(parts)}"
```

**`--describe NAME` output** (preview pane — multi-section, plain text):

```
# host: lab-box        (defined in: ~/.config/fleet/machines.toml)

connection:
  ssh_alias       lab-box
  user            (from ssh_config)
  hostname        (from ssh_config)
  port            (from ssh_config)
  identity_file   (from ssh_config)

fleet metadata:
  local                false
  no_root_machine      false
  chezmoi_path         auto
  password_source      bitwarden (item=ssh-lab-box-sudo)
  extra_env            (none)

ssh -G resolution (if ssh_alias present):
  hostname 192.0.2.42
  user dwlee
  port 22
  identityfile ~/.ssh/id_ed25519
  proxyjump bastion.example.com

local key check:
  [OK]   ~/.ssh/id_ed25519
```

`ssh -G` block is omitted for explicit-fields hosts. **Never print `password_source_arg` for type=plain** — only show the type label.

**`local = true` hosts**:
- Included in `--list` / `--list-json` (scriptable consumers may want them).
- **Excluded** from `--list-tsv` (TV cable source) by default, so the picker never shows you yourself. A `--include-local` flag overrides for completeness.
- `fleet hosts <name>` on a `local` host: print `"fleet hosts: '<name>' is local = true — nothing to SSH into"` and exit 0.

**No-args dispatch**:
1. If `shutil.which("tv")`: `os.execvp("tv", ["tv", "fleet-hosts"])`.
2. Else: enumerate non-local hosts, print a numbered list, read stdin, dispatch to SSH. This is a *safety net* for headless CI; on every dev machine `tv` is installed via the devtools role.

### 2. `dot_config/television/cable/fleet-hosts.toml` (new)

Modeled directly on `ssh-config.toml` but sourced from `fleet hosts`. Schema:

```toml
[metadata]
name = "fleet-hosts"
description = "Fleet hosts (from ~/.config/fleet/machines.toml)"
requirements = ["fleet", "ssh"]

[source]
command = "fleet hosts --list-tsv"
# Lines look like:   name<TAB>target<TAB>kind
# e.g.   lab-box	lab-box	alias:lab-box
display = "{split:\\t:0}  ({split:\\t:2})"
output  = "{split:\\t:0}"

[preview]
command = "fleet hosts --describe '{split:\\t:0}'"

[keybindings]
enter = "actions:connect"
alt-t = "actions:probe"
alt-s = "actions:status"
alt-i = "actions:info"
alt-p = "actions:pueue"

[actions.connect]
description = "SSH into the selected fleet host"
command = "fleet hosts '{split:\\t:0}'"
mode = "execute"

[actions.probe]
description = "BatchMode SSH probe (does passwordless login work?)"
command = "fleet hosts --probe '{split:\\t:0}'; echo; echo '[Press Enter to exit]'; read -r _"
mode = "execute"

[actions.status]
description = "fleet chezmoi status for this host"
command = "fleet chezmoi status --hosts '{split:\\t:0}'; echo; echo '[Press Enter to exit]'; read -r _"
mode = "execute"

[actions.info]
description = "fleet info for this host"
command = "fleet info --hosts '{split:\\t:0}'; echo; echo '[Press Enter to exit]'; read -r _"
mode = "execute"

[actions.pueue]
description = "fleet pueue for this host"
command = "fleet pueue --hosts '{split:\\t:0}'; echo; echo '[Press Enter to exit]'; read -r _"
mode = "execute"
```

**Header comment** at the top (matching ssh-config.toml's style) documents: source SSOT, keybindings, and the "tv = picker, fleet hosts CLI = direct/scriptable" duality.

## Files to modify

### 3. `dot_dotfiles/bin/executable_fleet`

- Add `_dispatch_hosts(forwarded)` that does `sys.argv = ["fleet hosts", *forwarded]; from scripts.fleet.hosts import main as hosts_main; return hosts_main()` — mirrors `_dispatch_tmux` / `_dispatch_info` / etc. exactly.
- Add `"hosts": _dispatch_hosts` to the `dispatch` dict.
- Extend the `USAGE` string's "Generic primitives" section:
  ```
  hosts [NAME] [--list|--list-tsv|--list-json|--describe NAME|--probe NAME]
                          Interactive picker (via `tv fleet-hosts`) for SSH'ing into
                          a fleet host. `fleet hosts NAME` skips the picker and SSHes
                          directly. `--list` / `--list-tsv` / `--list-json` for scripts.
  ```
- Extend the module-docstring layout summary at the top of the file with the new entry.

### 4. `scripts/fleet/__init__.py`

No changes needed — `hosts.py` re-uses the already-re-exported `load_hosts`, `Host`, `DEFAULT_CONFIG_PATH`. (If a future refactor moves them to `_lib.py` per the file's own TODO, both `apply.py` and `hosts.py` will follow at once.)

### 5. `docs/this_repo/fleet-apply.md`

In the existing "Umbrella `fleet` binary" section, add a row to the subcommand table for `fleet hosts` and a one-line cross-link to the new dedicated doc.

### 6. `docs/tools/fleet-hosts.md` (new)

Mirrors the structure of `docs/tools/fleet-exec.md`:

1. **What it does** (one paragraph).
2. **Two entry points** (table: `tv fleet-hosts` vs `fleet hosts [NAME]` vs `fleet hosts --list*`).
3. **Keybindings** table (Enter / Alt+T / Alt+S / Alt+I / Alt+P).
4. **Inventory source** — links to machines.toml schema (`docs/this_repo/fleet-apply.md`) and notes that `local = true` hosts are hidden from the picker.
5. **Example output** — short paste of `--list-tsv` and `--describe`.

### 7. `mkdocs.yml`

Add a nav entry for `docs/tools/fleet-hosts.md` next to `docs/tools/fleet-exec.md`. Run `uv run mkdocs build --strict` to verify (per CLAUDE.md cross-file rule).

### 8. `CLAUDE.md` (cross-file maintenance row)

Update the `dot_dotfiles/bin/executable_fleet` row in the maintenance table to include `hosts.py` and the new doc:

```
| `dot_dotfiles/bin/executable_fleet` (umbrella `fleet chezmoi <action>` namespace + top-level generic primitives `tmux`/`info`/`pueue`/`exec`/`edit`/`hosts`) / `scripts/fleet/` (`apply.py` / `tmux.py` / `info.py` / `pueue.py` / `exec.py` / `hosts.py`) / `justfile` `fleet` + `fleet-*` recipes / `dot_config/fleet/` / `dot_config/television/cable/fleet-hosts.toml` / sudo helper consumption / `dot_config/tmux/executable_tmux-session-summary.py` `--json` schema / `dot_dotfiles/bin/executable_pqsum` `json`/`ai --stdin-json` schemas / `scripts/fleet/exec.py` PATH-prelude + AIEXEC schema | [docs/this_repo/fleet-apply.md](docs/this_repo/fleet-apply.md), [docs/tools/pueue.md](docs/tools/pueue.md), [docs/tools/fleet-exec.md](docs/tools/fleet-exec.md), [docs/tools/fleet-hosts.md](docs/tools/fleet-hosts.md) | ...
```

(The trailing schema-sync paragraph is unchanged.)

## Reused functions (do NOT reimplement)

- `scripts.fleet.load_hosts(path)` → returns `(list[Host], defaults_dict)`. Already validates `name` uniqueness and `ssh_alias OR hostname OR local`.
- `scripts.fleet.Host` dataclass → fields `name`, `ssh_alias`, `hostname`, `user`, `port`, `identity_file`, `local`, `no_root_machine`, `chezmoi_path`, `extra_env`, `password_source_type`, `password_source_arg`.
- `scripts.fleet.DEFAULT_CONFIG_PATH` → respects `FLEET_CONFIG` env var override.
- `scripts.fleet._connect_kwargs(host)` → **NOT used directly** (it builds asyncssh kwargs). Mirror its precedence logic in the new `_ssh_argv()` helper (ssh_alias wins over explicit fields), keeping the two in semantic lockstep.
- `chezmoi source-path` discovery → already done by `executable_fleet`'s `_source_path()`; `hosts.py` runs inside the same process via `from scripts.fleet.hosts import main`, so `sys.path` is already set.

## Design decisions / tradeoffs

| Decision | Choice | Why |
|---|---|---|
| TOML parser | `tomllib` (stdlib) | py>=3.11 is already required by every other fleet module. No extra deps. |
| Picker engine | TV cable | Matches the user's stated analogy with `tv ssh-config`. Free preview/keybinding UX. |
| Inventory parsing for the cable | shells out to `fleet hosts --list-tsv` | One SSOT (Python `load_hosts`); the cable stays a thin TOML config, no inline TOML parsing. |
| Direct invocation | `fleet hosts NAME` → `os.execvp("ssh", ...)` | Replaces the shell with ssh — the user's terminal is now an interactive SSH session, exactly as they'd expect. |
| `local = true` hosts | Hidden from picker, shown by `--list`/`--list-json` | SSH'ing into yourself is silly, but scripts that want full inventory still see them. |
| `password_source` in preview | Show type only (never `arg` for `plain`) | The TOML file itself is 0600 but preview output may scroll into other logs/screenshots. Defence in depth. |
| Action keys | `Enter` / `Alt+T` / `Alt+S` / `Alt+I` / `Alt+P` | Mirrors `ssh-config.toml`'s `Alt+` namespace (CLAUDE.md keybinding rule: avoid `Ctrl+letter` collisions with tmux). |
| No `Ctrl+E` "fleet exec" action | Out of scope | `fleet exec` needs a command string — picker can't prompt for arbitrary argv. Add later if needed. |

## Verification

After implementing, run these end-to-end checks:

1. **Lint the new Python module**:
   ```bash
   uv run --script scripts/fleet/hosts.py --help
   ```
   Must print argparse help. (`uv run --script` honours PEP 723 inline deps.)

2. **List mode** (script-friendly outputs):
   ```bash
   fleet hosts --list             # plain names, one per line
   fleet hosts --list-tsv         # name<TAB>target<TAB>kind (no local hosts)
   fleet hosts --list-tsv --include-local
   fleet hosts --list-json | jq . # full inventory dump
   ```

3. **Describe mode** (the preview pane content):
   ```bash
   fleet hosts --describe self
   fleet hosts --describe lab-box   # any real host with ssh_alias
   ```
   Must NOT leak `password_source.value` for plain-type hosts.

4. **Direct SSH** (skip picker):
   ```bash
   fleet hosts <some-ssh-alias-host>   # should land you in an interactive ssh session
   fleet hosts self                    # should print "is local — nothing to SSH into", exit 0
   fleet hosts nonexistent             # should print error, exit 2
   ```

5. **Probe mode** (used by Alt+T):
   ```bash
   fleet hosts --probe <some-host>
   echo $?   # 0 = passwordless works, non-zero = needs password / unreachable
   ```

6. **TV cable** (full UX):
   ```bash
   # First deploy the cable
   chezmoi apply ~/.config/television/cable/fleet-hosts.toml
   tv fleet-hosts
   # Inside picker:
   #   - Confirm the host list matches `fleet hosts --list-tsv`
   #   - Cursor a host; preview pane should match `fleet hosts --describe NAME`
   #   - Ctrl+/ to toggle preview (TV builtin) — should work
   #   - Alt+T → BatchMode probe runs, "Press Enter to exit"
   #   - Alt+S/I/P → corresponding fleet command runs scoped to that host
   #   - Enter → drops into SSH session
   ```

7. **Umbrella wiring**:
   ```bash
   fleet hosts        # should exec `tv fleet-hosts` (or fall back to numeric menu in CI)
   fleet --help       # USAGE must list `hosts` under generic primitives
   fleet bogus        # must still error "unknown subcommand"
   ```

8. **Docs build** (per CLAUDE.md rule):
   ```bash
   uv run mkdocs build --strict
   ```
   Must pass — i.e. the new `docs/tools/fleet-hosts.md` is wired into nav and all internal links resolve.

9. **Validator from CLAUDE.md "Validate app configs with the app"**:
   - `tv` itself parses the cable on load. If `tv fleet-hosts` errors with a TOML/schema warning, fix before declaring done.
   - `chezmoi apply --dry-run dot_config/television/cable/fleet-hosts.toml` should be clean.

## Out of scope (deliberately deferred)

- A picker-driven `fleet exec` (would need a command-input modal — TV cable can't prompt).
- `Alt+L` to "live-tail" a host's `fleet chezmoi apply` log — possible later via `fleet chezmoi tail`.
- Multi-select then fan-out (e.g. pick 3 hosts → `fleet exec` on those). TV is single-select; deferred to a Python TUI if ever wanted.
- A `justfile` recipe wrapping `fleet hosts` — both `fleet hosts` and `tv fleet-hosts` are short enough; recipes don't add value here.
- `~/.shellrc.adhoc` alias suggestions (e.g. `alias fh='fleet hosts'`) — leave to the user.
