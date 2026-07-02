# Copilot → Claude Code proxy

Back [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the
**Claude models from a GitHub Copilot subscription**, via a local
reverse-engineered proxy ([`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api)).

- **Shell helpers**: `~/.config/shell/43_copilot_proxy.sh` (`copilot-proxy`, `claude-copilot`, `copilot-run`, `copilot-here`, `copilot-model`)
- **Runner**: `bunx copilot-api` (pinned; matches the `bunx` convention in `07_bunx_cli.sh`)
- **Not installed by ansible** — pulled on demand via `bunx`, so it stays off the
  provisioning path.

!!! warning "This violates GitHub Copilot's Terms of Service"
    Using a Copilot subscription to power a non-GitHub agent is not permitted, and
    copilot-api is reverse-engineered/unofficial. copilot-api's own README warns it
    can trigger GitHub's **abuse detection** and lead to **temporary suspension of
    Copilot access**. Claude Code is token-hungry (frequent background calls, large
    context) — always run with a rate limit. Use at your own risk; prefer a personal
    account over a corporate seat.

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
                                          │ translates Anthropic <-> Copilot
                                          │ Authorization: Bearer <copilot token>
                                          ▼
                                   api.githubcopilot.com  (your Copilot sub)
```

- Claude Code speaks only the **Anthropic Messages API** (`/v1/messages`).
- Copilot's chat endpoint is **OpenAI-compatible** (`/chat/completions`).
- copilot-api translates between them and injects the Copilot auth.
- Claude Code is pointed at the proxy via `ANTHROPIC_BASE_URL` — injected either
  as per-process env (`claude-copilot`) or via the gitignored
  `./.claude/settings.local.json` (`copilot-here on`). See "Settings-layer design".

## Settings-layer design (which file gets the proxy config, and why)

Claude Code merges settings low → high: `~/.claude/settings.json` (user) →
`./.claude/settings.json` (project, committed) → `./.claude/settings.local.json`
(local, gitignored) → CLI flags — and **shell env vars beat the `env` block of
every settings file** ([docs](https://code.claude.com/docs/en/settings)).

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
~/.claude/settings.json          .claude/settings.json         .claude/settings.local.json      shell env
(chezmoi: hooks/plugins)    <    (git: plansDirectory)     <   (copilot-here on/off)        <   (claude-copilot)
```

## Shell helpers

### `copilot-proxy [start|stop|restart|status|logs [N]|whoami|auth]`

Manages the background proxy on `$COPILOT_PROXY_PORT` (default `4141`).

| Env var | Default | Meaning |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | port the proxy listens on |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` seconds (throttle; be gentle) |
| `COPILOT_API_PKG` | `copilot-api@0.7.0` | `bunx` package spec (pin / upgrade) |

Set these in `~/.shellrc.adhoc` (or the per-shell secrets files). `start` refuses
to run until `copilot-proxy auth` has stored a token, and waits up to ~20s for the
proxy to answer before returning.

`copilot-proxy whoami` is the real login check: it exchanges the stored token
against GitHub and prints your account / plan / quota (fails loudly if the token
is missing or expired). Use it instead of eyeballing the token file — the token
is a plaintext credential and should not be opened in an editor.

### `claude-copilot [--no-specstory] [claude args...]` — one-off session

Layer 1: run a single Claude Code session on the proxy with **zero file
writes**. Auto-starts the proxy if it isn't answering, then launches `claude`
with the `ANTHROPIC_*` env injected per-process (shell env beats every
settings-file `env` block, so this wins even where `copilot-here` is off).

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
  the state file; final fallback is `claude-opus-4.8`.)

Behavior:

- Fuzzy id: `copilot-model opus-4.8` resolves to `claude-opus-4.8`.
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
    "ANTHROPIC_MODEL": "claude-opus-4.8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4.8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4.5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4.5",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` is ignored by the proxy but must be set.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` cuts background chatter (helps with
rate limits). Do **not** paste this into the committed `.claude/settings.json` —
use `copilot-here on` instead.

## Gotchas (these cost real debugging time)

### Do not use Claude Code's `/model` picker

It sends Anthropic's *official* ids (e.g. `claude-opus-4-8-YYYYMMDD`), but the
Copilot backend only knows its own ids (`claude-opus-4.8`). Picking from the menu
produces:

```
API Error: 400 {"error":{"message":"The requested model is not supported.",
"code":"model_not_supported", ...}}
```

Pin the model with `copilot-model` instead.

### The "Opus 4 retired" warning is cosmetic

Claude Code shows `[Opus 4]` and warns *"Claude Opus 4 was retired"* — it fails to
match the Copilot id against its built-in Anthropic table and falls back to the
nearest known (retired) name. Requests are still routed correctly to
`claude-opus-4.8`. There is no clean way to remove the warning; ignore it.

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

Verified via `/v1/models` (2026-07): `claude-opus-4.5`, `claude-opus-4.6`,
`claude-opus-4.7`, `claude-opus-4.8`, `claude-sonnet-4.5`, `claude-sonnet-4.6`,
`claude-sonnet-5`, `claude-haiku-4.5`. Non-Claude models (gpt-5.5,
gemini-3.1-pro-preview, …) are also served — see `copilot-model -l` or
`GET /v1/models`.

## Useful commands

```sh
claude-copilot                       # one-off proxy session (specstory-wrapped)
copilot-here status                  # is this project pinned to the proxy?
copilot-model -c                     # current model + which layer it came from
copilot-proxy status                 # up? which Claude models?
copilot-proxy whoami                 # validate token → account / plan / quota
copilot-proxy logs 60                # tail the proxy log
# usage dashboard:
#   https://ericc-ch.github.io/copilot-api?endpoint=http://localhost:4141/usage
```

## See also

- [copilot-api](https://github.com/ericc-ch/copilot-api) — the proxy
- [`bunx` CLI aliases](../shells/aliases.md#copilot--claude-code-proxy)
- [Claude Code settings precedence](https://code.claude.com/docs/en/settings) — why
  `settings.local.json` / env vars are the right injection layers
- [Agent overlays](agent-overlays.md) — the chezmoi-managed `~/.claude/settings.json`
  this design deliberately stays out of
- OpenCode's native GitHub Copilot provider (no proxy needed for OpenCode itself)
