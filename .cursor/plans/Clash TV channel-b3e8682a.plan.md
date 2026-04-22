<!-- b3e8682a-5c23-458c-ba65-4ecb22a2680c -->
---
todos:
  - id: "parser"
    content: "Add dot_config/television/executable_clash-parse.py (PyYAML-based, uv run --script; subcommands: proxies/groups/rules/summary/path/yaml/server)"
    status: pending
  - id: "source"
    content: "Add dot_config/television/executable_clash-source.sh (dispatches to clash-parse.py; api mode curls external-controller for /version + /configs health)"
    status: pending
  - id: "preview"
    content: "Add dot_config/television/executable_clash-preview.sh (main YAML via bat, latency via API or nc+ping fallback, meta kind-dependent)"
    status: pending
  - id: "channel"
    content: "Add dot_config/television/cable/clash.toml (5-source Ctrl+S cycle, 3-view Ctrl+F preview, Alt-key actions including reload/close/switch — adjust set based on clarifying answer)"
    status: pending
  - id: "gitleaks"
    content: "Append 3 rules to .gitleaks.toml with secretGroup=1: clash-vmess-uuid, clash-vmess-share-link, azure-cloudapp-hostname"
    status: pending
  - id: "docs"
    content: "Add ### clash channel section to docs/tools/tv.md (matches azure/pueue structure: source cycling + preview cycling + keybinding tables + notes)"
    status: pending
  - id: "verify"
    content: "Run gitleaks detect on working dir to confirm no regression; run tv clash end-to-end to confirm all 5 sources + 3 previews + Alt-key actions work against user's live Clash config"
    status: pending
isProject: false
---
# Clash TV channel + redact hardening

## Goal

1. Fuzzy-search a Clash/mihomo config (proxies / groups / rules / summary / API health) from `tv clash`, with latency tests and dashboard shortcuts.
2. Teach `.gitleaks.toml` to catch the sensitive parts of a Clash config (vmess UUIDs, Azure proxy-VM hostnames, `vmess://` share links) so `scripts/redact_secrets.py` auto-redacts them in `.specstory/history/`, `.claude/plans/`, `.cursor/plans/`, `.opencode/plans/`.

## Files to add

- `dot_config/television/executable_clash-parse.py` — PyYAML-based parser with `uv run --script` shebang (mirrors `scripts/redact_secrets.py` pattern). Subcommands: `proxies`, `groups`, `rules`, `summary`, `path`, `yaml`, `server`. Config discovery: `$CLASH_CONFIG` → `~/.config/{clash,mihomo}/config.{yaml,yml}` → `~/Library/Application Support/{clash,mihomo}/config.{yaml,yml}`.
- `dot_config/television/executable_clash-source.sh` — bash source dispatcher for TSV row emission; adds an `api` mode that curls `http://<external-controller>/version` + `/configs` and emits health rows.
- `dot_config/television/executable_clash-preview.sh` — three views: `main` (YAML block via `bat -l yaml`), `latency` (API `/proxies/:name/delay` preferred, direct `nc -z` + `ping` fallback), `meta` (related rules / group members / API connections count).
- `dot_config/television/cable/clash.toml` — channel TOML with 5-source Ctrl+S cycle, 3-view Ctrl+F preview, Alt-key actions.

Row schema (TSV): `kind\tname\ttype_or_meta\tserver_or_target\textra` where `kind ∈ {proxy, group, rule, config, api, none}`.

## Files to edit

- `.gitleaks.toml` — append three rules with `secretGroup = 1` so only the sensitive portion is replaced by `redact_secrets.py` (e.g. `uuid: 418...c56`, YAML keys kept intact):
  - `clash-vmess-uuid` — `\buuid\s*:\s*['"]?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})['"]?`
  - `clash-vmess-share-link` — `\b(vmess://[A-Za-z0-9+/=]{40,})\b`
  - `azure-cloudapp-hostname` — `\b([a-z0-9][a-z0-9-]*\.(?:[a-z]+\d?\.)?cloudapp\.azure\.com)\b`
- `docs/tools/tv.md` — add a `### clash channel` section mirroring the `azure` / `pueue` structure (source cycling table, preview cycling, keybindings table, implementation notes).

## No changes needed

- `scripts/redact_secrets.py` — the existing `redact_file()` loop already consumes `finding["Secret"]`; with `secretGroup = 1` the Secret field carries only the UUID/hostname/link, so redaction kicks in automatically.
- `AGENTS.md` / `CLAUDE.md` — no new keybinding conflict surface (all Alt+ actions are within the TV channel scope).
- No ansible role gate — `curl` (base) + `uv` (bootstrap) are always available; the channel degrades gracefully when Clash config or external-controller is missing.

## Channel design

### Source cycling (Ctrl+S)

- Proxies — one row per entry in `proxies:` (name, type, `server:port`, tls/udp/ws flags)
- Proxy Groups — one row per entry in `proxy-groups:` (name, group type, first member, `N members`)
- Rules — one row per entry in `rules:` (index `#NNNN`, match type, pattern, target+modifier)
- Summary — top-level scalars (`port`, `mixed-port`, `external-controller`, `mode`, `log-level`, …)
- API — `external-controller` health + selected runtime values from `/configs` (only if reachable)

### Preview cycling (Ctrl+F)

1. YAML block of the selected entry (`clash-parse.py yaml --kind --name`) via `bat -l yaml`
2. Latency — Clash API `/proxies/:name/delay?timeout=5000&url=http://www.gstatic.com/generate_204` if controller reachable, else `nc -z -w3` + `ping -c 3` on the resolved server/port
3. Meta — kind-dependent (group members + current selection via API; rule neighbours; API connections count)

### Keybindings (Alt+ namespace)

- `Enter` — show full YAML in execute mode
- `Alt+T` — run latency test (Clash API or TCP probe)
- `Alt+S` — switch PROXY group selection (if chosen answer is `a`: picks the group via fzf then `PUT /proxies/:group`)
- `Alt+C` — close all connections (`DELETE /connections`)
- `Alt+R` — reload config (`PUT /configs?force=true`)
- `Alt+D` — open dashboard (`http://127.0.0.1:9090/ui` or external `yacd.haishan.me` / `clash.razord.top`)
- `Alt+E` — edit config file in `$EDITOR`
- `Ctrl+Y` / `Alt+Y` — copy server address / proxy name to clipboard (pbcopy/wl-copy/xclip/OSC 52 fallback — same helper pattern as azure/lan-devices channels)

Authorization header: parser emits `secret:` alongside `external-controller:` in `summary`; source/preview scripts add `-H "Authorization: Bearer <secret>"` when non-empty.

## Graceful degradation

- No config found → single synthetic row `none  no-clash-config  -  Set CLASH_CONFIG or place under ~/.config/clash/  -`; Enter on that row opens `${EDITOR}` on an empty `~/.config/clash/config.yaml`.
- `uv` missing → row `none  uv-not-installed  -  Run chezmoi bootstrap  -`.
- External-controller unreachable → api mode row flagged `unreachable`; latency preview falls back to `nc` + `ping`; mutating actions (Alt+S/C/R) show a 1-second toast and no-op.

## Validation (manual, not automated)

- `tv clash` against user's `~/.config/clash/config.yaml` — verify all 5 Ctrl+S cycles render, Ctrl+F previews work, Alt+T latency test completes.
- `python3 -m pyyaml` smoke: a malformed YAML file should produce a single `none invalid-yaml` row, not crash.
- `gitleaks detect --config .gitleaks.toml --source . --no-git -v` across the repo to confirm no new false-positives on existing content; verify the three new rules fire on the user's pasted config.
- Per AGENTS.md, no bats/smoke tests — Python scripts are out of unit-test scope.
