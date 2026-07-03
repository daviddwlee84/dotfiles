---
name: Migrate copilot-proxy to fork
overview: Switch the default copilot-api package to the maintained fork (@jeffreycao/copilot-api) while keeping the original ericc-ch package working via COPILOT_API_PKG, with package-aware conditional flags and docs updates.
todos:
  - id: pkg-default
    content: Add _copilot_pkg_flavor helper; flip default COPILOT_API_PKG to @jeffreycao/copilot-api@1.13.14
    status: completed
  - id: start-flags
    content: Make copilot-proxy start pass --rate-limit/--wait only for the original package
    status: completed
  - id: whoami
    content: Make whoami use check-usage (original) vs /usage curl or debug (fork)
    status: completed
  - id: quiet-env
    content: Add opt-in COPILOT_PROXY_QUIET env injection to copilot-run and copilot-here (off removes keys unconditionally)
    status: completed
  - id: precedence-comments
    content: Fix settings.local.json-beats-shell-env precedence comments in the script header and copilot-run
    status: completed
  - id: docs
    content: "Update docs/tools/copilot-claude-proxy.md: fork default, env table, dashboard URL, new gotchas"
    status: completed
  - id: verify
    content: Restart proxy on fork default, verify status/whoami, rollback test with original pkg, quiet-env on/off round-trip
    status: completed
  - id: todo-1783042747011-xrz5cj80t
    content: git commit changes
    status: completed
isProject: false
---

# Migrate copilot-proxy to the maintained fork (dual-package support)

## Background

The original `ericc-ch/copilot-api` is officially unmaintained ([issue #233](https://github.com/ericc-ch/copilot-api/issues/233)); the community successor is [caozhiyuan/copilot-api](https://github.com/caozhiyuan/copilot-api) (npm `@jeffreycao/copilot-api`, v1.13.14). The previous chat verified live: same token file is reused (no re-auth), native `/v1/messages` passthrough fixes thinking blocks / WebSearch / tool loops. CLI differences (verified from the fork's `src/start.ts`): the fork's `start` has **no `--rate-limit` / `--wait`** flags, and there is **no `check-usage`** subcommand (it has `auth`, `start`, `debug`, `mcp`, plus a local `/usage` endpoint + bundled `/usage-viewer`).

## Decisions (per user)

- **Dual support**: detect the package from `COPILOT_API_PKG` and conditionally pass flags — but flip the **default** to the fork, pinned: `@jeffreycao/copilot-api@1.13.14`. Rollback is one env var: `COPILOT_API_PKG=copilot-api@0.7.0`.
- **Quota-saving env vars**: add as **opt-in, default OFF** (user prioritizes experience over Copilot quota).

## Changes to [dot_config/shell/43_copilot_proxy.sh](dot_config/shell/43_copilot_proxy.sh)

### 1. Package flavor detection + new default

- `_copilot_pkg()` default becomes `@jeffreycao/copilot-api@1.13.14`.
- New helper `_copilot_pkg_flavor()`: returns `original` when the package name (version stripped) is exactly `copilot-api`, else `fork`. Only the exact original gets the legacy flags.

### 2. `copilot-proxy start` — conditional flags

- `original` → keep `--rate-limit "${COPILOT_PROXY_RATE:-15}" --wait` as today.
- `fork` → plain `start --port "$port"` (no rate limiting exists; adjust the startup message so it doesn't claim a rate limit).

### 3. `copilot-proxy whoami` — conditional implementation

- `original` → `bunx "$pkg" check-usage` (unchanged).
- `fork` → if the proxy is alive, `curl $(base)/usage` and jq-summarize plan/quota; else fall back to `bunx "$pkg" debug` (shows auth status/paths). Both fail loudly when the token file is missing, as today.

### 4. Opt-in quiet env (new knob, default off)

- New env var `COPILOT_PROXY_QUIET` (default `0`, documented in the header next to `COPILOT_PROXY_PORT`). When `1`:
  - `copilot-run` additionally injects: `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0`, `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1`.
  - `copilot-here on` merges the same keys into `settings.local.json`; the keys are added to `_copilot_here_keys` so `copilot-here off` always removes them regardless of the current knob value.

### 5. Header comments

- Update the file header: fork is the default runner, original still works via `COPILOT_API_PKG`; `COPILOT_PROXY_RATE` is original-only.
- Fix the **settings-precedence comment** (lines 26–27): the previous chat empirically found current Claude Code lets `settings.local.json` env beat inherited shell env — the opposite of what's documented. Same fix in the `copilot-run` comment ("shell env vars beat every settings-file env block").

## Changes to [docs/tools/copilot-claude-proxy.md](docs/tools/copilot-claude-proxy.md)

- Intro/links: fork is the maintained proxy (link both repos + issue #233); note the token file is shared so switching needs no re-auth.
- Env-var table: new default `COPILOT_API_PKG`, `COPILOT_PROXY_RATE` marked original-only, add `COPILOT_PROXY_QUIET` (default off, what it trades off).
- "How it works": note the fork prefers Copilot's **native Anthropic `/v1/messages`** (Enterprise: `api.enterprise.githubcopilot.com`) instead of Anthropic→OpenAI translation — this is what fixes thinking blocks, WebSearch, and tool-loop bugs.
- Usage dashboard URL: bundled locally at `http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage` (replace the `ericc-ch.github.io` link).
- New gotchas:
  - **`settings.local.json` env beats shell env** in current Claude Code → `claude-copilot`/`copilot-run` cannot override a project where `copilot-here on` points elsewhere; trialing another port requires `copilot-here off` first. Update the precedence diagram/table in "Settings-layer design" accordingly.
  - Fork has **no rate limiter** — mitigation is `COPILOT_PROXY_QUIET=1` (off by default) or falling back to the original package.
  - Known fork wart: injected `context_management` can 400 against Copilot's native endpoint ([caozhiyuan#305](https://github.com/caozhiyuan/copilot-api/issues/305)); didn't trigger in real Claude Code runs, but watch for it.
  - Keep existing `/model` picker gotcha (dated Anthropic ids still unsupported); note the fork also accepts hyphenated ids (`claude-opus-4-8`) so the Claude Code 2.1.x hyphenation issue is gone.

## Verification

1. `copilot-proxy start` with the new default → answers on 4141, `copilot-proxy status` lists Claude models.
2. `copilot-proxy whoami` on the fork → prints plan/quota via `/usage`.
3. `COPILOT_API_PKG=copilot-api@0.7.0 copilot-proxy restart` → original still starts with `--rate-limit`.
4. `claude-copilot` one-shot smoke test (this repo has `copilot-here on` → same port, so no precedence trap).
5. `copilot-here off && copilot-here on` in a scratch dir with `COPILOT_PROXY_QUIET=1` → extra keys present; `off` removes them.
