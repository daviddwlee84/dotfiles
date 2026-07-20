# Plan: `appsrc` — detect how an installed app / CLI was installed & managed

## Context

**Problem.** On both macOS and Ubuntu the same app can arrive through many
mechanisms (Homebrew cask/formula, Mac App Store, direct-download dmg/pkg,
manual drag-in; apt, snap, flatpak, AppImage, Linuxbrew; plus language package
managers cargo/npm/pipx/uv/mise/go/gem). There is **no single OS command** that
tells you which one produced a given app — you must combine several signals,
ordered by specificity, and some "obvious" signals are traps (this repo's
`pitfalls/tailscale-another-copy-app-store-leftover.md` proves `_MASReceipt`
exists in *both* App Store and standalone Tailscale bundles → not a reliable
discriminator; the ollama pitfall proves you must judge on the *observable
on-disk owner*, not a proxy).

**Goal.** A new in-house CLI `appsrc` that:
- **`appsrc which <name>`** — `which`-style single lookup, live (no cache). Takes
  a shell command (`docker`) **or** a GUI app name (`"Google Chrome"`),
  auto-detecting which; prints the canonical install source + evidence.
- **`appsrc` / `appsrc scan`** (no args) — batch-inventory **GUI apps + CLI
  tools**, attribute each to its manager, cache the (slow) result.
- **`--json`** on both for machine/`tv` consumption.

**Prompted by** today's design conversation (`.specstory/history/2026-07-20_04-02-20Z-*.md`)
where the user asked "can we tell how an app is managed?" and chose to build the
full CLI. Decisions locked: name `appsrc`; scan covers GUI + CLI; cache the scan
(per-app mtime invalidation) but run single `which` live.

---

## Design

**Archetype:** single-file `uv run --script` launcher, exactly like
`dot_dotfiles/bin/executable_pqsum` (system-inspection tool: cache + `--json` +
dataclasses, only `rich` as a dep, shells out to system tools). No `scripts/`
package, no ansible entry needed (`rich` is a pure lib — pqsum has none either).

**New binary:** `dot_dotfiles/bin/executable_appsrc`
- Header verbatim from pqsum:
  ```python
  #!/usr/bin/env -S uv run --quiet --script
  # /// script
  # requires-python = ">=3.11"
  # dependencies = [
  #   "rich>=13.9",
  # ]
  # ///
  ```
- argparse, positional subcommand: `scan` (default) | `which`. Flags:
  `scan`: `--json`, `--kind {gui,cli,all}` (default `all`), `--source FILTER`,
  `-r/--refresh`, `--no-cache`.
  `which <name>`: `--json`, `--path PATH` (skip name→path resolution).

### Data model (dataclass → `asdict` → `json.dumps`, pqsum idiom)

```python
@dataclass
class AppRecord:
    name: str                 # "Google Chrome" / "docker"
    kind: str                 # "gui" | "cli"
    path: str | None          # realpath: /Applications/….app or …/bin/docker
    source: str               # canonical id (table below)
    manager: str | None       # human label, e.g. "Homebrew cask"
    package: str | None       # owning cask/formula/deb/snap/crate if known
    confidence: str           # "authoritative" | "heuristic"
    bundle_id: str | None     # macOS CFBundleIdentifier
    signer: str | None        # macOS codesign Authority / TeamID
    origin_url: str | None    # macOS kMDItemWhereFroms (direct download)
    detail: str | None        # freeform note (e.g. drift, dedupe hint)
    mtime: float | None       # cache invalidation key
```

**Canonical `source` values** — macOS: `homebrew-cask`, `homebrew-formula`,
`mac-app-store`, `direct-download-pkg`, `direct-download-dmg`, `manual`;
Linux: `apt`, `snap`, `flatpak`, `appimage`, `linuxbrew`, `manual`;
both (CLI): `cargo`, `npm`, `pipx`, `uv`, `mise`, `go`, `gem`; fallback `unknown`.

### Detection engine — two passes (hybrid: fast forward inventory + heuristic fallback)

**Pass A — forward inventory (authoritative, `confidence="authoritative"`).**
Query each manager *once* (cheap), snapshot into in-memory maps keyed by realpath
and by app basename — the "snapshot once, match in memory, no per-item forks"
idiom already used in `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl:181-235`:
- macOS: `brew list --cask` + one `brew info --cask --json=v2 <all casks>` to map
  `.app`→cask; `brew list --formula` (binaries under `$(brew --prefix)/bin`);
  `mas list` (App Store id+name); `pkgutil --pkgs`. Arch-aware Caskroom resolver
  copied from `run_onchange_after_30_brew_bundle.sh.tmpl:173-179`.
- Linux: `snap list`; `flatpak list --app`; `dpkg -l`/`apt-mark showmanual`;
  Linuxbrew prefix (`/home/linuxbrew/.linuxbrew` | `~/.linuxbrew`).
- both (CLI): path-prefix attribution — `~/.cargo/bin`, mise shims, `~/.local/share/uv`
  / `~/.local/bin` (pipx/uv), `~/go/bin`, gem dir, npm `-g` prefix. One list call
  per manager only when a binary falls in its prefix.

**Pass B — per-item heuristic decision tree (`confidence="heuristic"`),** for
GUI apps / commands *not* claimed in Pass A, and for every `which` lookup (always
live). Ordered, first match wins:
- **macOS** (`.app` at resolved path): (1) Caskroom metadata present → `homebrew-cask`;
  (2) `mas list` / `mdls -name kMDItemAppStoreHasReceipt` == 1 → `mac-app-store`;
  (3) `pkgutil --file-info <path>` receipt → `direct-download-pkg`;
  (4) `xattr -p com.apple.metadata:kMDItemWhereFroms` present → `direct-download-dmg`
  (record URL); else `manual`. **Tie-break / evidence always captured:**
  `codesign -dv --verbose=4` `Authority=` (`Apple Mac OS Application Signing` ⇒
  App Store; `Developer ID Application: Vendor (TeamID)` ⇒ cask/direct) +
  `CFBundleIdentifier`. Bake in the Tailscale caveat: never rely on `_MASReceipt`
  alone. `mdfind -name "<X>.app"` dedupe note when >1 copy exists.
- **Linux** (`realpath "$(command -v <name>)"` first): (1) path under `/snap/` →
  `snap`; (2) `flatpak list` / path under `/var/lib/flatpak`|`~/.local/share/flatpak`
  → `flatpak`; (3) `dpkg -S <realpath>` owner (RPM: `rpm -qf`) → `apt` (refine w/
  `apt-mark showmanual`); (4) Linuxbrew prefix → `linuxbrew`; (5) `file` shows
  embedded squashfs / single exec, `dpkg -S` misses → `appimage`; (6) language-PM
  prefixes → cargo/npm/pipx/uv/mise/go/gem; (7) `/usr/local/*` unowned → `manual`;
  else `unknown`.

### Enumeration (batch scan)

- macOS GUI: glob `/Applications` + `~/Applications` (`.app` dirs). *(Skip
  `/System/Applications` — all Apple system, low signal; add later behind a flag.)*
- Linux GUI: reuse the 5-directory `.desktop` scan loop + `awk -F=` Name/Exec
  parsing from `dot_config/shell/56_linux_apps.sh.tmpl:170-199` (already debugged,
  incl. the "absolute `Exec=` only" filter).
- CLI (both): the union of Pass-A manager inventories (each manager lists what it
  owns) — this *is* the CLI inventory, no PATH walk needed for owned tools; a
  final optional PATH sweep flags unowned `/usr/local/bin` binaries as `manual`.

### Output

- Default: `rich` table grouped by `source` (columns: name, source, package,
  path). `--source FILTER` and `--kind` narrow it. `--json`: `json.dumps([asdict(r)
  for r in records], indent=2, default=str)`.

### Cache (scan only; `which` never caches)

Copy pqsum's `_cache_path/_cache_lookup/_cache_save` (`executable_pqsum:610-652`)
verbatim, adapted for per-app mtime invalidation:
- Path: `${XDG_CACHE_HOME:-~/.cache}/appsrc/<host>.json`.
- Envelope: `{version:"v1", generated_at, host, apps:{<path>: {record…, mtime}}}`.
- On scan: enumerate items → for each, `stat` mtime; if cached entry exists with
  equal mtime → reuse (skip the expensive codesign/xattr/pkgutil probes); else
  recompute that one item. Pass-A inventory calls are cheap → always re-run.
- `-r/--refresh` bypasses read; `--no-cache` skips read+write. Atomic write
  (tmp + `os.replace`).

---

## Integration surfaces (per CLAUDE.md cross-file rules)

| # | Surface | Action | Path |
|---|---|---|---|
| 0 | binary | create | `dot_dotfiles/bin/executable_appsrc` |
| 1 | zsh completion | create | `dot_config/zsh/tools/57_appsrc_completion.zsh` |
| 2 | bash completion | create | `dot_config/bash/57_appsrc_completion.bash` |
| 3 | completion registry | edit (Section F table row) | `docs/zsh/zsh-completions.md` |
| 4 | aliases catalog | edit (add `CLI (bin)` row) | `docs/shells/aliases.md` |
| 5 | agent skill | edit (bullet in "Custom in-house CLIs") | `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` |
| 6 | tv channel | create | `dot_config/television/cable/appsrc.toml` |
| 7 | just recipe | edit (passthrough) | `justfile` |
| 8 | deep doc | create + nav entry | `docs/tools/appsrc.md`, `mkdocs.yml` |

Notes / grounding:
- **Completions = Strategy B hand-written** (subcommands + `--json`), mirror
  `_fleet` structure (`dot_config/{zsh/tools,bash}/45_fleet_completion.*`); guard
  `(( $+commands[appsrc] ))` / `command -v appsrc`. Dynamic candidate for
  `which <name>`: shell out to `appsrc scan --list-names` (a hidden helper) like
  `_fleet_hosts_one` runs `fleet hosts --list`. Verify next free completion number
  (56_view_ebook is current highest → **57**).
- **No A–Z row in `tool-managers.md`** — in-house CLIs are excluded from that
  table (verified: no existing `fleet`/`pqsum`/`yth` rows). Only add a reverse
  pointer if desired. No `python_uv_tools` ansible entry (`rich`-only, like pqsum).
- **tv channel** is non-templated (`appsrc` self-adapts per-OS): `[source]` =
  `appsrc scan --json` or a TSV mode; `[preview]` = `appsrc which '{…}'`;
  keybindings use **`Alt+`** not `Ctrl+` (tmux prefix shadows `ctrl-b`); actions
  e.g. copy-install-command / reveal-in-Finder.
- **Standalone — stays OUT of the app-* 4-file contract** (`54_macos_apps.sh` ↔
  `56_linux_apps.sh` ↔ `mac-apps.toml` ↔ `linux-apps.toml`). That contract is a
  *symmetric lifecycle-verb* guarantee; provenance detection is inherently
  asymmetric (codesign/mas vs dpkg/snap) and would force a "document the gap"
  exception. `appsrc` reuses that layer's `.desktop` scan *loop* but adds no verb.

## Reuse map (copy, don't reinvent)

- pqsum skeleton + cache: `dot_dotfiles/bin/executable_pqsum` (shebang/PEP723,
  `_cache_*` at 610-652, argparse+dispatch at 1025-1100, dataclass→`asdict`).
- Linux `.desktop` enumeration + `awk` parse: `dot_config/shell/56_linux_apps.sh.tmpl:170-199`.
- Arch-aware Caskroom resolver + `/Applications` & `mas list` snapshot idiom:
  `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl:173-235`.
- `pkgutil` receipt probe idiom: `run_once_before_02_fix_intel_homebrew.sh.tmpl:65-93`.
- Detection decision tables (verbatim, incl. caveats): earlier design answer +
  `docs/sysadmin/cookbook.md:562`; Tailscale `_MASReceipt` trap:
  `pitfalls/tailscale-another-copy-app-store-leftover.md:58-59`.

## Verification (end-to-end, per CLAUDE.md "validate with the app")

1. **Run from source before deploy** (works pre-apply): `just appsrc which docker`,
   `just appsrc which "Google Chrome"` (mac) — confirm each prints a plausible
   source + evidence line; cross-check by hand (`brew list --cask`, `mas list`,
   `dpkg -S $(realpath $(command -v docker))`).
2. **Known-source ground truth on this mac**: pick one cask app, one App Store
   app (if any), one drag-installed app → `appsrc which` each must classify
   correctly; verify the Tailscale-style dual-copy case is flagged, not
   mis-labeled from `_MASReceipt`.
3. **Batch + cache**: `appsrc scan --json | jq 'length'` non-empty; re-run and
   confirm it's fast (cache hit) and `~/.cache/appsrc/<host>.json` exists;
   `touch` an app bundle → next scan recomputes only that row; `--refresh`
   recomputes all; `--no-cache` writes nothing.
4. **JSON schema stable**: `appsrc scan --json | jq '.[0] | keys'` matches the
   `AppRecord` fields (the `tv` channel + completions depend on it).
5. **Completions**: new shell → `appsrc <Tab>` offers `scan`/`which`;
   `appsrc which <Tab>` offers app/command names; both shells (zsh + bash).
6. **tv channel**: `tv appsrc` opens, rows render, preview shows `appsrc which`,
   Alt-key actions fire. (Headless caveat: validate the source/preview commands
   standalone per `memory/tv-channel-headless-validation.md` — don't launch the
   TUI without a TTY.)
7. **Docs/lint**: `uv run mkdocs build --strict` (nav entry added); `just check`
   / pre-commit for drift.
8. **Linux path** (if a Linux host is reachable via `fleet`): repeat 1–4 for a
   snap, a flatpak, an apt binary, an AppImage, a cargo/uv tool.
