# Copilot → Claude Code proxy

Back [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the
**Claude models from a GitHub Copilot subscription**, via a local
reverse-engineered proxy — the maintained fork
[`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api)
(npm `@jeffreycao/copilot-api`). The original
[`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api) is
officially unmaintained ([issue #233](https://github.com/ericc-ch/copilot-api/issues/233)
points at the fork) but still works via `COPILOT_API_PKG=copilot-api@0.7.0`.
Both packages share the same token file
(`~/.local/share/copilot-api/github_token`), so switching needs **no re-auth**.

- **Shell helpers**: `~/.config/shell/43_copilot_proxy.sh` (`copilot-proxy`, `claude-copilot`, `copilot-run`, `copilot-here`, `copilot-model`)
- **Runner**: `bunx @jeffreycao/copilot-api` (pinned; matches the `bunx` convention in `07_bunx_cli.sh`)
- **Not installed by ansible** — pulled on demand via `bunx`, so it stays off the
  provisioning path.

!!! warning "This violates GitHub Copilot's Terms of Service"
    Using a Copilot subscription to power a non-GitHub agent is not permitted, and
    copilot-api is reverse-engineered/unofficial. It can trigger GitHub's
    **abuse detection** and lead to **temporary suspension of Copilot access**.
    Claude Code is token-hungry (frequent background calls, large context) —
    note the fork has **no rate limiter** (see Gotchas); `COPILOT_PROXY_QUIET=1`
    reduces background chatter. Use at your own risk; prefer a personal account
    over a corporate seat.

## Quick start

```sh
copilot-proxy auth      # one-time: GitHub device login (stores a ghu_ token)

claude-copilot          # one-off session on the proxy (auto-starts it; no file writes)

copilot-here on         # OR: pin THIS project — plain `claude` uses the proxy
copilot-here off        # unpin — back to the real Anthropic backend
```

## How it works

```
Claude Code ──Anthropic /v1/messages──▶ copilot-api (localhost:4141)
                                          │ native /v1/messages passthrough
                                          │ Authorization: Bearer <copilot token>
                                          ▼
                                   api.githubcopilot.com  (your Copilot sub)
```

- Claude Code speaks only the **Anthropic Messages API** (`/v1/messages`).
- The fork prefers Copilot's **native Anthropic-style `/v1/messages`
  endpoint** when available (Enterprise plans:
  `api.enterprise.githubcopilot.com/v1/messages`) and only falls back to
  translating through the OpenAI-compatible `/chat/completions`. Native
  passthrough is what fixes **extended-thinking blocks**, **WebSearch**
  (routed through a Responses-capable GPT model, default `gpt-5-mini`), and
  the **infinite tool-retry loops** the original's Anthropic→OpenAI→Anthropic
  translation caused.
- The original (`copilot-api@0.7.0`) always translates through
  `/chat/completions` — thinking blocks are dropped and WebSearch doesn't work.
- Claude Code is pointed at the proxy via `ANTHROPIC_BASE_URL` — injected either
  as per-process env (`claude-copilot`) or via the gitignored
  `./.claude/settings.local.json` (`copilot-here on`). See "Settings-layer design".

## Settings-layer design (which file gets the proxy config, and why)

Claude Code merges settings low → high: `~/.claude/settings.json` (user) →
`./.claude/settings.json` (project, committed) → `./.claude/settings.local.json`
(local, gitignored) → CLI flags. The
[docs](https://code.claude.com/docs/en/settings) (and third-party writeups)
claim shell env vars beat every settings-file `env` block, but **empirically
(verified 2026-07) current Claude Code lets the `settings.local.json` `env`
block beat inherited shell env** — see Gotchas.

Two of those layers are already owned by other tooling and must stay clean:

| Layer | Owner | Why proxy config must NOT go here |
|---|---|---|
| `~/.claude/settings.json` | chezmoi (`dot_claude/modify_settings.json`) | always-on for *every* project; fights the chezmoi merge |
| `./.claude/settings.json` | `claude-plans-here` (`plansDirectory`) | committed to git — proxy config would leak to the team |

So the proxy uses the two layers nobody else owns:

| Enable | Mechanism | Scope | Disable |
|---|---|---|---|
| `claude-copilot` / `copilot-run` | per-process env vars | one session | just run plain `claude` next time |
| `copilot-here on` | `./.claude/settings.local.json` (gitignored) | this project, sticky | `copilot-here off` |

```
~/.claude/settings.json          .claude/settings.json         shell env                    .claude/settings.local.json
(chezmoi: hooks/plugins)    <    (git: plansDirectory)     <   (claude-copilot)         <   (copilot-here on/off)
```

(Shell env still beats the user- and project-level settings files, so
`claude-copilot` works everywhere `copilot-here` is off — it just cannot
*override* an active `copilot-here` pin.)

## Shell helpers

### `copilot-proxy [start|stop|restart|status|logs [N]|whoami|auth]`

Manages the background proxy on `$COPILOT_PROXY_PORT` (default `4141`).

| Env var | Default | Meaning |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | port the proxy listens on |
| `COPILOT_API_PKG` | `@jeffreycao/copilot-api@1.13.14` | `bunx` package spec (pin / upgrade; `copilot-api@0.7.0` = old original) |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` seconds — **original package only** (the fork has no rate limiter) |
| `COPILOT_PROXY_QUIET` | `0` | `1` = inject extra quota-saving Claude Code env (see below); off by default because it slightly degrades the UX |

Set these in `~/.shellrc.adhoc` (or the per-shell secrets files). `start` refuses
to run until `copilot-proxy auth` has stored a token, and waits up to ~20s for the
proxy to answer before returning. `start` detects the package flavor from
`COPILOT_API_PKG`: only the exact original `copilot-api` gets
`--rate-limit`/`--wait` (the fork's `start` doesn't have those flags).

`copilot-proxy whoami` is the real login check: it prints your plan / quota
(fails loudly if the token is missing or expired). On the fork it queries the
running proxy's `/usage` endpoint (jq-summarized) and falls back to
`bunx <pkg> debug` when the proxy is down; on the original it runs
`check-usage`. Use it instead of eyeballing the token file — the token is a
plaintext credential and should not be opened in an editor.

### `claude-copilot [--no-specstory] [claude args...]` — one-off session

Layer 1: run a single Claude Code session on the proxy with **zero file
writes**. Auto-starts the proxy if it isn't answering, then launches `claude`
with the `ANTHROPIC_*` env injected per-process (shell env beats the user- and
project-level settings files — but **not** an active `copilot-here` pin in
`settings.local.json`; see Gotchas).

- Wraps in `specstory run claude` when specstory is installed (markdown
  auto-save — same convention as `scode`/`svibe`); opt out with
  `--no-specstory`. Extra args reach the claude CLI via specstory's
  `-c "custom command"` passthrough: `claude-copilot -c` → continue session.
- Revert = nothing to revert; plain `claude` next time is untouched.

### `copilot-run <cmd...>` — generic env injector

The building block under `claude-copilot`: auto-starts the proxy and runs *any*
command with the proxy env. Useful for other Anthropic-compatible tools or a
custom specstory invocation:

```sh
copilot-run specstory run claude    # exactly what claude-copilot does
copilot-run claude --resume         # raw claude, no specstory
```

### `copilot-here [on|off|status]` — sticky per-project toggle

Layer 2: pin **this project** to the proxy via `./.claude/settings.local.json`
so plain `claude` (and `scode`/`svibe` panes, which just run
`specstory run claude`) uses the proxy until you turn it off. Requires `jq`.

- `on` — jq-merges the proxy `env` block into `settings.local.json` (creates it
  if missing) and makes sure git ignores the file (via `.git/info/exclude`;
  Claude Code only auto-gitignores files *it* creates). The committed
  `.claude/settings.json` (`plansDirectory` etc.) is never touched.
- `off` — removes exactly the env keys `on` added; other content you put in
  `settings.local.json` survives, and the file is deleted if it becomes empty.
- `status` — pinned? which base URL / model? warns when the proxy isn't running.

### `copilot-model [<id>|-l|-c]`

Switches the pinned Copilot model. Requires `jq`. Write target — never the
committed `.claude/settings.json`:

- `copilot-here` is ON in the current project → edits
  `./.claude/settings.local.json`.
- otherwise → writes the global state file
  `~/.local/state/copilot-proxy/model`, which `claude-copilot`, `copilot-run`
  and the next `copilot-here on` pick up. (`$COPILOT_CLAUDE_MODEL` overrides
  the state file; final fallback is `claude-opus-4-8[1m]`.)

Behavior:

- Fuzzy id: `copilot-model opus-4-8` resolves to `claude-opus-4-8`; dotted
  input is normalized (`opus-4.8` works too).
- A `[1m]` suffix (`copilot-model 'opus-4-8[1m]'`) is stripped for validation
  and re-appended — it's a Claude Code-only 1M-context hint, see the model-id
  section below.
- Validated against the live proxy `/v1/models` (falls back to a static Claude
  list if the proxy is down); typos and ambiguous prefixes are rejected.
- No argument → `fzf` picker. `-c` prints the current model and which layer it
  came from.
- Writes both `ANTHROPIC_MODEL` and `ANTHROPIC_DEFAULT_OPUS_MODEL` —
  **the change only takes effect on the next `claude` launch** (env is read at
  startup). Switching model does **not** require restarting the proxy.

## Injected env (what both layers set)

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4141",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "claude-opus-4-8[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` is ignored by the proxy but must be set.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` cuts background chatter (helps with
rate limits). Do **not** paste this into the committed `.claude/settings.json` —
use `copilot-here on` instead.

With `COPILOT_PROXY_QUIET=1` (opt-in, default off), both layers additionally
inject the fork-README quota savers:

| Extra env | Effect | UX cost |
|---|---|---|
| `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | no billing/version info in system prompts → avoids prompt-cache invalidation | none noticeable |
| `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` | no prompt-suggestion calls | no suggestions |
| `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0` | no away-summary calls | no away summaries |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` | fewer background model calls | fewer niceties (haiku flavor text etc.) |

`copilot-here off` removes these keys regardless of the current
`COPILOT_PROXY_QUIET` value.

## Gotchas (these cost real debugging time)

### `settings.local.json` env beats shell env (docs say otherwise)

Verified empirically (2026-07): current Claude Code lets the `env` block of
`./.claude/settings.local.json` **override inherited shell env vars** — the
opposite of what the official settings docs imply. Consequences:

- `claude-copilot` / `copilot-run` **cannot** redirect a project where
  `copilot-here on` is active (harmless when both point at the same proxy,
  silently wrong when they don't).
- Trialing another proxy/port via the wrapper requires `copilot-here off`
  first.

### The fork has no rate limiter

The fork's `start` dropped `--rate-limit`/`--wait`. Its README's mitigation is
reducing Claude Code's chatter instead — that's exactly what
`COPILOT_PROXY_QUIET=1` injects (off by default here; we prioritize UX over
Copilot quota). If you really want request throttling, fall back to the
original: `COPILOT_API_PKG=copilot-api@0.7.0`.

### Fork wart: `context_management` can 400

Newer Claude Code context-editing may inject `context_management`, which
Copilot's native `/v1/messages` endpoint rejects with a 400
([caozhiyuan#305](https://github.com/caozhiyuan/copilot-api/issues/305),
version-dependent). Real Claude Code runs didn't trigger it in testing, but if
you see unexplained 400s on long sessions, check that issue first.

### Do not use Claude Code's `/model` picker

It sends Anthropic's *official* dated ids (e.g. `claude-opus-4-8-YYYYMMDD`),
which the Copilot backend rejects:

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

Pin the model with `copilot-model` instead — undated hyphenated ids
(`claude-opus-4-8`) work; only the picker's dated ids fail.

### Dotted ids cause the "[Opus 4] retired" warning and a >100% context HUD

Historic gotcha, fixed by the hyphenated defaults. With a **dotted** id
(`claude-opus-4.8`, the only shape the original proxy accepted), Claude Code
fails to match its built-in model table, so it:

- displays `[Opus 4]` and warns *"Claude Opus 4 was retired"* (falls back to
  the nearest known, retired name), and
- assumes a **200k** context window, while Copilot actually serves opus-4-8 /
  sonnet-5 with **1M** (`max_context_window_tokens: 1000000` in `/v1/models`)
  — so HUD/statusline context can read >100% and compaction triggers on the
  wrong budget.

The fix is the id shape the helpers now inject by default:
**`claude-opus-4-8[1m]`** — hyphenated so Claude Code recognizes the family
(correct display name, no retirement warning), plus the `[1m]` suffix so it
sizes context to 1M. Claude Code strips `[1m]` before sending, so the proxy
sees a valid id (a *literal* `...[1m]` in a raw API call is rejected —
`copilot-model` handles the stripping when validating).

### The token gotcha: `gho_` vs `ghu_`

There are two different GitHub tokens, and they are **not** interchangeable:

| Source | Prefix | `copilot_internal/v2/token` exchange |
|---|---|---|
| OpenCode's stored auth | `gho_` | **fails (404)** |
| `copilot-proxy auth` (device login) | `ghu_` | **works** |

OpenCode's `gho_` token (OAuth App) works only when used *directly* as a Bearer
against `api.githubcopilot.com`; it cannot complete copilot-api's classic
token-exchange step. **Let `copilot-proxy auth` mint its own `ghu_` token — do not
reuse OpenCode's.** Token is stored at `~/.local/share/copilot-api/github_token`.

## Available Claude model ids

Verified via `/v1/models` + `/v1/messages` (2026-07): `claude-opus-4-5`,
`claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-sonnet-4-5`,
`claude-sonnet-4-6`, `claude-sonnet-5`, `claude-haiku-4-5`. The fork accepts
both hyphenated and legacy dotted (`claude-opus-4.8`) forms at request time,
but **use hyphenated ids in Claude Code** — dotted ids break its model
detection (see Gotchas). Context windows from `/v1/models` capabilities:
opus-4-8 and sonnet-5 are **1M** (`max_prompt_tokens: 936000`), haiku-4-5 is
200k — append `[1m]` to the 1M models so Claude Code knows. Non-Claude models
(gpt-5.5, gemini-3.1-pro-preview, …) are also served — see `copilot-model -l`
or `GET /v1/models`.

## Useful commands

```sh
claude-copilot                       # one-off proxy session (specstory-wrapped)
copilot-here status                  # is this project pinned to the proxy?
copilot-model -c                     # current model + which layer it came from
copilot-proxy status                 # up? which Claude models?
copilot-proxy whoami                 # validate token → account / plan / quota
copilot-proxy logs 60                # tail the proxy log
# usage dashboard (bundled locally by the fork):
#   http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage
```

## See also

- [caozhiyuan/copilot-api](https://github.com/caozhiyuan/copilot-api) — the
  maintained fork this setup runs (npm `@jeffreycao/copilot-api`)
- [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api) — the
  unmaintained original ([#233](https://github.com/ericc-ch/copilot-api/issues/233));
  still usable via `COPILOT_API_PKG=copilot-api@0.7.0`
- [`bunx` CLI aliases](../shells/aliases.md#copilot--claude-code-proxy)
- [Claude Code settings precedence](https://code.claude.com/docs/en/settings) — why
  `settings.local.json` / env vars are the right injection layers
- [Agent overlays](agent-overlays.md) — the chezmoi-managed `~/.claude/settings.json`
  this design deliberately stays out of
- OpenCode's native GitHub Copilot provider (no proxy needed for OpenCode itself)
