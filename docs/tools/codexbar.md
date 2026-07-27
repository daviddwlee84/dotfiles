# CodexBar

[CodexBar](https://github.com/steipete/CodexBar) surfaces AI coding-provider limits, reset
countdowns, credits, and local token cost without logging into each vendor's dashboard.
Roughly 63 providers as of v0.45.2 — Codex, Claude, Cursor, Gemini, Copilot, OpenRouter,
Grok, Bedrock, z.ai, Kimi, and a long tail of newer ones.

- **macOS 14+**: menu bar app **plus** a bundled CLI — the cask installs both
- **Linux**: CLI only. Desktop panels are community projects built on this CLI
  ([Waybar](https://github.com/Marouan-chak/codexbar-waybar),
  [GNOME](https://extensions.gnome.org/extension/9841/codexbar/),
  [KDE](https://github.com/tylxr59/KodexBar), Cinnamon)

## How this repo installs it

Everything lives in the `# === CodexBar ===` block of
[`dot_ansible/roles/coding_agents/tasks/main.yml`](../../dot_ansible/roles/coding_agents/tasks/main.yml).

| Platform | Mechanism | Result |
|---|---|---|
| **macOS 14+** (Intel **and** Apple Silicon) | `brew install --cask codexbar` — homebrew-cask **core**, no tap | `/Applications/CodexBar.app` + `codexbar` on PATH |
| **Linux**, glibc ≥ 2.38, Linuxbrew usable | `brew install steipete/tap/codexbar` (CLI formula) | `codexbar` in the brew prefix |
| **Linux**, glibc ≥ 2.38, no Linuxbrew | GitHub release tarball | `~/.local/bin/codexbar` |
| **Linux**, glibc < 2.38 | static-musl GitHub release tarball — Linuxbrew deliberately bypassed | `~/.local/bin/codexbar` |

The role guards on `/Applications/CodexBar.app`, **not** on `which codexbar` — see the
binary-name conflict below.

### macOS: the cask supersedes the CLI formula

Two upstream artifacts both provide a `codexbar` executable:

| | `brew install --cask codexbar` | `brew install steipete/tap/codexbar` |
|---|---|---|
| Ships | `CodexBar.app` **+** CLI (`binary … target: "codexbar"`) | CLI only |
| Menu bar / Settings UI | yes | no |
| Platforms | macOS 14+ only | macOS **and** Linux |

They collide: both link the same `codexbar` name into the brew prefix, so Homebrew declines
to link the cask's binary while the formula owns it. **Pick one.** On macOS the cask is
strictly the superset, so the role removes a pre-existing `codexbar` formula before
installing the cask (with a rescue that restores the formula if the cask install fails).

Because of that collision, a `which codexbar` install-guard is wrong on macOS: a host with
the CLI formula would look "already installed" and never get the app.

### Intel Macs are supported — do not re-add an arm64 gate

| Version | Date | Change |
|---|---|---|
| ≤ v0.25 | — | GUI was arm64-only; the core cask carried `depends_on arch: :arm64` |
| **v0.26.0** | 2026-05-15 | app ships as `CodexBar-macos-universal-*.zip`; **arch requirement dropped** |
| v0.17.0 | 2026-02-02 | cask moved into homebrew-cask **core** — the `steipete/tap` tap is no longer needed for it |

The only requirement left is `depends_on macos: :sonoma` (macOS 14+); the role skips older
macOS with an explicit message instead of letting the cask hard-fail the play.

### Linux: the prebuilt glibc CLI needs a *very* new distro

The `linux-<arch>` tarball is a Swift binary built on modern CI. Reading `.gnu.version_r`
out of v0.45.2's own assets (`objdump -p CodexBarCLI`) shows the real floor, and it is much
higher than the usual Linuxbrew line — **both** `linux-x86_64` and `linux-aarch64` require:

- `GLIBC_2.38` from `libc.so.6`
- `GLIBCXX_3.4.30` (GCC 12+) from `libstdc++.so.6`

| Distro | glibc | Prebuilt glibc CLI |
|---|---|---|
| Ubuntu 24.04 | 2.39 | runs |
| Ubuntu 22.04 | 2.35 | **fails** |
| Debian 12 | 2.36 | **fails** |
| RHEL / Rocky 9 | 2.34 | **fails** |
| CentOS 7 | 2.17 | **fails** |

Upstream's static build (since **v0.37.0**, 2026-06-20) has an empty `NEEDED` list and zero
`GLIBC_*` references, so it runs anywhere. The role probes glibc and picks accordingly:

| Detected glibc | Asset |
|---|---|
| ≥ 2.38 | `CodexBarCLI-v<tag>-linux-<arch>.tar.gz` (~43 MB) |
| < 2.38, or undetectable | `CodexBarCLI-v<tag>-linux-musl-<arch>.tar.gz` (~79 MB, static) |

!!! danger "The probe also gates the Linuxbrew path — on purpose"
    `steipete/tap/codexbar` is a binary-download formula that fetches **the same glibc
    tarball**. On a Jammy / bookworm / RHEL-9 host `brew install` therefore "succeeds" and
    leaves a binary that cannot execute — and because the install guard is `which codexbar`,
    every later run would skip the working musl fallback. So when glibc < 2.38 the role
    bypasses Linuxbrew entirely and goes straight to the static tarball.

Failing *towards* musl when glibc can't be detected is deliberate: the static build runs
anywhere, it just costs ~36 MB more download.

!!! warning "Don't wire up upstream's `.sha256` sidecar"
    Each release asset has a `<asset>.tar.gz.sha256`, but its content is
    `<sha>  /tmp/tmp.XXXXXX/CodexBarCLI-…` — the **build machine's absolute temp path**,
    not a bare filename. Ansible's `get_url` checksum-URL lookup matches on filename and
    can never resolve that, so the download task deliberately has no `checksum:`.

## First run without the GUI

Provider toggles normally live in the app's **Settings → Providers**. On a CLI-only install
(Linux, or macOS before the cask lands) use the `config` subcommand instead — otherwise
bare `codexbar` only reports whatever handful of providers it can auto-detect:

```bash
codexbar config providers                  # list ids + enabled state
codexbar config enable  --provider claude
codexbar config disable --provider cursor
codexbar config validate                   # warnings keep exit 0, errors don't
codexbar config dump --pretty

# API-key providers, without touching shell history
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

`set-api-key` trims the piped value, writes it with restrictive permissions, and enables the
provider (`--no-enable` to skip that).

### Config file location

New installs use the XDG path; the legacy path still works when no XDG config exists:

| Path | Status |
|---|---|
| `~/.config/codexbar/config.json` | current default (honours an absolute `XDG_CONFIG_HOME`) |
| `~/.codexbar/config.json` | legacy, still read by existing installs |
| `$CODEXBAR_CONFIG` | explicit override |

## Commands

| Command | What it does |
|---|---|
| `codexbar usage` | live limits/quotas. **This is the default** — bare `codexbar` runs it |
| `codexbar cost` | local token cost from Claude/Codex/Cursor logs. `--days 1…365`, `--group-by project`, `--refresh` |
| `codexbar cards` | one-shot snapshot as a terminal card grid; `--brief` for a compact table |
| `codexbar serve` | foreground HTTP JSON server (`/health`, `/usage`, `/cost`, `/dashboard/v1/snapshot`) |
| `codexbar guard --provider <id>` | gate automation on remaining quota; stable exit codes |
| `codexbar config …` | providers / enable / disable / set-api-key / validate / dump |
| `codexbar cache clear` | `--cookies`, `--cost`, `--all` |
| `codexbar cookie refresh` | re-import browser cookies for a provider |
| `codexbar hooks …` | list / enable / disable / test external event hooks |

### `--source` semantics

`--source <auto|web|cli|oauth|api>`, default `auto`, and the fallback order is
**per-provider** (e.g. Codex: OpenAI web dashboard → Codex CLI when cookies are missing;
Claude: claude.ai API → Claude CLI). Output always reports the strategy actually used, in
the header: `== Claude 2.1.220 (claude) ==`.

On **Linux**, browser-backed `auto` / `web` modes are unsupported — but `auto` still
resolves, falling through to local files, provider CLIs, OAuth, or a configured manual
cookie. Forcing `--source cli` is therefore no longer required there; it is only useful when
you specifically want the provider-CLI path.

### `guard` exit codes

```bash
codexbar guard --provider codex --min-remaining 20 --window weekly --json
```

| Code | Meaning |
|---|---|
| `0` | at or above the threshold (also what `--fail-open` turns an unavailable result into) |
| `1` | below the threshold |
| `64` | invalid arguments |
| `69` | quota could not be checked, or the selected window is unavailable |

### `serve` security defaults

Binds `127.0.0.1:8080`. `/usage` and `/cost` are unauthenticated **only** on the loopback
bind; on a non-loopback host every data route requires `Authorization: Bearer …` and startup
additionally demands `--allow-plain-http` (the token crosses the network in cleartext).
Prefer `CODEXBAR_DASHBOARD_TOKEN` over `--dashboard-token`, which leaks via `ps`.

## Shell aliases

Defined in [`dot_config/shell/40_codexbar.sh`](../../dot_config/shell/40_codexbar.sh)
(shared layer — both zsh and bash):

| Alias | Command | Description |
|-------|---------|-------------|
| `cbu` | `codexbar usage --provider claude` | Claude usage |
| `cbc` | `codexbar cost --provider claude` | Claude local cost |
| `cbca` | `codexbar cost` | All providers, local cost |

## Gotchas

- **`--provider all` queries every registered provider**, not just the enabled ones — with
  ~63 providers that means a wall of `No available fetch strategy for …` / missing-cookie
  errors before the handful of real results. Enable what you use (`codexbar config enable`)
  and let the default provider set do its job.
- **With three or more providers enabled**, the default stays scoped to enabled providers.
- **`cost` is fully offline** — it scans local JSONL session logs and needs no auth. `usage`
  is the one that reaches out.
- **macOS cookie-backed providers need Full Disk Access** for Safari
  (`Cookies.binarycookies` is unreadable without it); otherwise use another browser, manual
  cookies, API keys, or OAuth/CLI sources.
- **`codexbar --version` reports no version when installed from the cask.** The formula
  ships a `VERSION` file next to the binary in `libexec`, so it prints `CodexBar 0.45.2`;
  the app bundle has no such file next to `Contents/Helpers/CodexBarCLI`, so the same flag
  prints a bare `CodexBar`. Don't build version checks on it — use
  `brew list --cask --versions codexbar`, the app's Info.plist
  (`CFBundleShortVersionString`), or `serve`'s `/health` payload.
- **Upgrades are not automatic** — install-only per the repo's
  [install vs upgrade split](../this_repo/upgrades.md). `just upgrade-brew` picks up both
  the cask and the formula; the Linux tarball fallback has no upgrade path.

*Command surface verified against CodexBar v0.45.2 (2026-07).*
