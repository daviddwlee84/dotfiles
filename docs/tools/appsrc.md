# `appsrc` — how was this app installed?

`appsrc` answers a question no single OS command does: **where did this app come
from — Homebrew cask, the Mac App Store, a direct-download dmg/pkg, apt, snap,
flatpak, an AppImage, a language package manager, or a manual drop-in?** It
combines several signals, ordered by specificity, and captures the evidence.

- Source: [`dot_dotfiles/bin/executable_appsrc`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_dotfiles/bin/executable_appsrc) (single-file `uv run --script`, `rich`-only)
- Deployed to `~/.dotfiles/bin/appsrc` (on PATH); run from the repo via `just appsrc …`
- Picker twin: `tv appsrc` · Completions: `57_appsrc_completion.{zsh,bash}`

## Usage

```console
# Single lookup (live, no cache) — a shell command OR a GUI app name:
$ appsrc which docker
docker  (Homebrew cask)
  kind       cli
  path       /Applications/Docker.app/Contents/Resources/bin/docker
  package    docker-desktop
  note       CLI shim into Docker.app

$ appsrc which "Google Chrome"          # GUI app by name
$ appsrc firefox                        # bare word == `appsrc which firefox`
$ appsrc which --path /Applications/Foo.app   # classify a path directly

# Batch inventory (GUI apps + CLI tools), cached:
$ appsrc                 # == appsrc scan
$ appsrc scan --kind gui                # GUI apps only
$ appsrc scan --source cask             # filter by source id/label
$ appsrc scan --json | jq '.[] | select(.source=="manual")'
$ appsrc scan --tsv                     # name<TAB>source<TAB>path<TAB>kind<TAB>package
$ appsrc scan --refresh                 # ignore cache, recompute
```

`which` is always live and gathers full evidence (codesign signer, bundle id,
download-provenance URL). `scan` is cached (see below) and skips the slow
per-app forks for anything an authoritative inventory already claims.

## What it detects

| Source id | Label | Platform |
|---|---|---|
| `homebrew-cask` / `homebrew-formula` | Homebrew cask / formula | macOS |
| `mac-app-store` | Mac App Store | macOS |
| `direct-download-pkg` / `direct-download-dmg` | Direct download (pkg / dmg-web) | macOS |
| `apt` / `snap` / `flatpak` / `appimage` / `linuxbrew` | apt·dpkg / snap / flatpak / AppImage / Linuxbrew | Linux |
| `cargo` `npm` `pipx` `uv` `mise` `go` `gem` | language package managers | both |
| `macos-system` / `manual` / `unknown` | OS-bundled / hand-placed / unattributable | both |

Each record carries a `confidence` — `authoritative` (a manager explicitly owns
it) or `heuristic` (inferred from provenance/signing).

## How it decides (two passes)

**Pass A — forward inventory (authoritative).** Ask each manager once what it
owns and match in memory (no per-item forks): `brew list --cask` + a single
`brew info --cask --json=v2` to map `.app`→cask, `brew list --formula`,
`mas list`; on Linux `snap list` / `flatpak list` / `dpkg -S` / Linuxbrew prefix;
CLI tools by resolved-path prefix (`~/.cargo/bin`, `~/.local/share/uv`, …).

**Pass B — per-item heuristics.** For anything Pass A doesn't claim (and every
`which`), walk an ordered decision tree:

- **macOS `.app`**: Caskroom metadata → cask; `mas list` / App-Store receipt /
  Apple re-signing → App Store; `pkgutil --file-info` receipt → pkg;
  `mdls kMDItemWhereFroms` provenance URL → dmg/web; else manual. `codesign`
  Authority + `CFBundleIdentifier` are captured as tie-break evidence.
- **Linux command**: `realpath` → `/snap/` → snap; `/var/lib/flatpak` → flatpak;
  `.appimage` → AppImage; Linuxbrew prefix → linuxbrew; `dpkg -S`/`rpm -qf`
  owner → apt; `/usr/local` or `$HOME` unowned → manual.

### Caveats baked in

- **`_MASReceipt` is NOT trusted alone** — it exists in some standalone bundles
  too (see [`pitfalls/tailscale-another-copy-app-store-leftover.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tailscale-another-copy-app-store-leftover.md)).
  App Store is confirmed by `mas list` membership, `mdls` receipt, **or** the
  `Apple Mac OS Application Signing` codesign Authority.
- **Shared user-bin trap.** A binary in `~/.local/bin` can't be attributed by
  path (uv, pipx, and go-with-a-redirected `GOBIN` all land there). `appsrc`
  content-checks it with `go version` — genuine Go binaries are labelled `go`,
  everything else `manual`. It deliberately ignores `GOBIN` when it points at a
  shared dir.
- **Cask drift.** A cask that declares an app but has no Caskroom entry (a
  drag-installed `.app`, per [`pitfalls/brew-bundle-redownloads-manually-installed-cask.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/brew-bundle-redownloads-manually-installed-cask.md))
  is flagged `homebrew-cask` with `confidence: heuristic` and a drift note.

## Cache

`scan` caches to `${XDG_CACHE_HOME:-~/.cache}/appsrc/<hostname>.json`, keyed
**per item by mtime** — a re-scan only recomputes apps whose bundle changed. The
forward-inventory calls (cheap) always re-run. Flags: `-r/--refresh` (recompute
all), `--no-cache` (don't read or write). Ballpark on a laptop: full GUI+CLI
scan ~15 s cold, ~5 s warm (~2 200 items); `which` is instant.

## Integration

- **`tv appsrc`** — browse GUI apps by install source. `Enter` = detail,
  `Alt+C` = copy path, `Alt+O` = reveal in Finder / open, `Alt+J` = JSON.
  Sources `appsrc scan --kind gui --tsv`; preview is `appsrc which --path`.
- **Completions** shell out to `appsrc scan --list-names` for GUI app names and
  add PATH commands, so `appsrc which <Tab>` completes either.

`appsrc` is the *runtime* companion to
[`docs/this_repo/tool-managers.md`](../this_repo/tool-managers.md), which records
how **this repo** installs tools by design; `appsrc` inspects whatever is
actually on the machine.
