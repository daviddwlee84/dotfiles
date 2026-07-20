# Plan: `appsrc size` — app footprint + associated storage (cache / data / containers)

## Context

**Problem.** `appsrc` (shipped in `04df259`) tells you *how* an app was installed
but not *how much space it costs*. The real cost is often hidden: empirically on
this Mac, **Docker's bundle is 2.1 GB but it uses 23 GB in
`~/Library/Containers/com.docker.docker`**. Users want "how big is this app, and
what other space (caches, data, containers) does it use?" — the question
AppCleaner-style uninstallers answer.

**Key lever (validated).** `appsrc which` already resolves an app's **bundle id**;
that id is the reverse-lookup key into `~/Library/{Caches,HTTPStorages,Containers,
Preferences,…}/<bundle-id>`. `du -s` on a bundle is fast even at multi-GB
(Docker 2.1 GB in 0.05 s), so sizing is viable.

**Decisions (locked).** Add **both** a dedicated `appsrc size <name>` command and a
`scan --size` bundle-size column. Associated-storage matching = **exact bundle-id
paths + fuzzy name candidates**, every item tagged `exact`/`fuzzy` with its real
path listed. **Never delete** — inspection only, no sudo.

**Goal.**
- `appsrc size <name>` (or `--path`) — live: app bundle size + each associated
  storage location + totals, highlighting the bundle-vs-other split.
- `appsrc scan --size` — adds a bundle-size column (bundle only; mtime-cached).
- `--json` on both.

## Design (all in `dot_dotfiles/bin/executable_appsrc`)

### Data model
```python
@dataclass
class StorageItem:
    category: str        # bundle|cache|data|container|prefs|state|logs|web|launch|xdg
    path: str
    size_bytes: int | None      # None = unreadable / du timed out
    confidence: str             # "exact" | "fuzzy"
    note: str | None = None

@dataclass
class SizeReport:
    name: str; source: str; kind: str; path: str | None
    bundle_bytes: int | None
    associated_bytes: int       # sum of non-bundle items
    total_bytes: int
    items: list[StorageItem]
```
Add one optional field to the existing `AppRecord`: `size_bytes: int | None = None`
(populated only by `scan --size`; rides the mtime-keyed cache, so it invalidates
when the bundle updates). Additive → no cache-version bump needed; in `do_scan`,
if `args.size` and a cache-hit record has `size_bytes is None`, compute it.

### Reuse / refactor
- **Extract resolution** from `do_which` (`executable_appsrc:781-812`, the
  `--path` / `shutil.which` / `_find_gui_app` / `_linux_desktop_apps` ladder) into
  `_resolve_record(args, mac_ctx, lin_ctx) -> AppRecord | None`. Both `do_which`
  and the new `do_size` call it (evidence=True so `bundle_id` is populated).
- `_du_bytes(path, timeout=20)` — `_run(["du","-sk",path])` → KB×1024; `None` on
  non-zero/timeout (guards a pathological cache dir). Reuses existing `_run`.
- `_mac_bundle_id` exists (`:263`); add `_mac_bundle_name(app)` (reads
  `CFBundleName` via `defaults read`) as an extra fuzzy candidate.
- `_human(n)` for table display (existing repo tools inline this).

### Sizing logic
**macOS GUI app** (has `path`, `bundle_id`):
- `bundle_bytes = _du_bytes(app)`.
- **exact** (by `<bid>`): `~/Library/Caches/<bid>`, `HTTPStorages/<bid>`,
  `Containers/<bid>`, `Group Containers/*<bid>*` (glob), `Application Scripts/<bid>`,
  `Preferences/<bid>.plist` (+`ByHost/<bid>.*`), `Saved Application State/<bid>.savedState`,
  `WebKit/<bid>`, `Cookies/<bid>.binarycookies`, `LaunchAgents/*<bid>*.plist`.
- **fuzzy** (per candidate ∈ {app.stem, CFBundleName, bid last segment, `Vendor/Product`
  split from `com.vendor.Product`}): `Application Support/<cand>`, `Caches/<cand>`,
  `Logs/<cand>`. Dedup against exact hits. (Catches Chrome's `Application Support/
  Google/Chrome`, VSCode's `Code`; may still miss deeply-nested vendor dirs — that's
  why each is labeled `fuzzy` and its path shown.)
- Readable **system** paths best-effort (no sudo): `/Library/Application Support/<cand>`,
  `/Library/LaunchDaemons|LaunchAgents/*<bid>*` — unreadable → `note="needs root"`.

**CLI (both OSes)**: `bundle_bytes` = `du` of the resolved binary, or the
`Cellar/<pkg>/<ver>` dir when the realpath is under it (walk up). fuzzy XDG:
`~/.config|.cache|.local/share|.local/state/<name>` (+ mac `~/Library/{Caches,
Application Support}/<name>`).

**Linux GUI/pkg** (designed, unverified — no Linux host this session): apt →
`dpkg-query -f='${Installed-Size}' -W <pkg>` (KB); snap → `du /snap/<name>/current`
+ `~/snap/<name>`,`/var/snap/<name>`; flatpak → `flatpak info` size + `~/.var/app/<id>`;
appimage → `du` the `.AppImage`.

### Output
- `render_size(report)`: header `name (source) — total <human>`, a **bundle X /
  other Y** split line (the reveal), then a table `Category | Size | ? | Path`
  sorted by size desc; `fuzzy` rows dimmed. `--json` = `asdict(SizeReport)`.
- `scan --size`: add a right-aligned "Size" column to `render_table` and a 6th TSV
  field; `--json` already carries the new `size_bytes`.

### CLI surface
- New `size` subparser: positional `name`, `--json`, `--path`. `main()` dispatch:
  `size` → `do_size`. Bare-word routing (`appsrc firefox`) still → `which`.
- `scan` gains `--size` (argparse `store_true`).

## Integration surfaces
| File | Change |
|---|---|
| `dot_dotfiles/bin/executable_appsrc` | all of the above |
| `dot_config/zsh/tools/57_appsrc_completion.zsh` + `dot_config/bash/57_appsrc_completion.bash` | add `size` to subcommand list (+ its `--json`/`--path`, reuse `_appsrc_names`); add `--size` to scan flags |
| `dot_config/television/cable/appsrc.toml` | add `Alt+S` action → `appsrc size --path '{split:\t:2}'` (execute + pause) |
| `docs/tools/appsrc.md` | new "Space & associated storage" section (incl. the Docker 2.1 GB vs 23 GB example + fuzzy-match caveat) |
| `docs/shells/aliases.md` + `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` | mention `size` in the appsrc row/bullet |
| `docs/zsh/zsh-completions.md` | extend the appsrc dynamic-candidate bullet to note `size <name>` |

No new deps (`rich`-only). No `python_uv_tools` / `tool-managers.md` change.

## Verification (this Mac)
1. `just appsrc size docker` → bundle ≈ 2.1 GB, a `container` row ≈ 23 GB for
   `~/Library/Containers/com.docker.docker`, correct total; cross-check with
   `du -sh` by hand. `--json` schema = `SizeReport` keys.
2. `appsrc size "Google Chrome"` and `size "Visual Studio Code"` → confirm fuzzy
   catches `Application Support/Google/Chrome` / `.../Code` (or is honestly absent
   with only exact hits listed — no false "0 B").
3. `appsrc size rg` (CLI) → binary/Cellar size + any XDG dirs.
4. `du` timeout guard: point `--path` at a huge dir, confirm it degrades to
   `size None` + note, never hangs.
5. `appsrc scan --kind gui --size` → Size column populated; re-run fast (mtime
   cache hit reuses sizes); `touch` an app → its size recomputes; `--json` has
   `size_bytes`.
6. Completions: `appsrc size <Tab>` offers app/command names; `appsrc scan --<Tab>`
   lists `--size`. Both shells syntax-check (`zsh -n` / `bash -n`).
7. `tv appsrc` → `Alt+S` runs the size report for the highlighted app (validate the
   action command standalone per `memory/tv-channel-headless-validation.md`).
8. `uv run mkdocs build --strict` adds no new warning beyond the 11 baseline.
9. **Stated gap**: Linux sizing (snap/flatpak/apt/appimage) is unverified — needs a
   Linux host via `fleet`.
