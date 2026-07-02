# Copilot → Claude Code proxy

Back [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the
**Claude models from a GitHub Copilot subscription**, via a local
reverse-engineered proxy ([`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api)).

- **Shell helpers**: `~/.config/shell/43_copilot_proxy.sh` (`copilot-proxy`, `copilot-model`)
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
copilot-proxy start     # background-start the proxy (default port 4141)

# In your project dir, create .claude/settings.json pointing at the proxy
# (see "Project settings" below), then:
copilot-model -c        # confirm the pinned model
claude                  # run Claude Code — it reads ./.claude/settings.json
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
- `.claude/settings.json` points Claude Code at the proxy via `ANTHROPIC_BASE_URL`.

## Shell helpers

### `copilot-proxy [start|stop|restart|status|logs [N]|auth]`

Manages the background proxy on `$COPILOT_PROXY_PORT` (default `4141`).

| Env var | Default | Meaning |
|---|---|---|
| `COPILOT_PROXY_PORT` | `4141` | port the proxy listens on |
| `COPILOT_PROXY_RATE` | `15` | `--rate-limit` seconds (throttle; be gentle) |
| `COPILOT_API_PKG` | `copilot-api@0.7.0` | `bunx` package spec (pin / upgrade) |

Set these in `~/.shellrc.adhoc` (or the per-shell secrets files). `start` refuses
to run until `copilot-proxy auth` has stored a token, and waits up to ~20s for the
proxy to answer before returning.

### `copilot-model [<id>|-l|-c]`

Switches which Copilot model the **current directory's** `.claude/settings.json`
pins. Requires `jq`.

- Fuzzy id: `copilot-model opus-4.8` resolves to `claude-opus-4.8`.
- Validated against the live proxy `/v1/models` (falls back to a static Claude
  list if the proxy is down); typos and ambiguous prefixes are rejected.
- No argument → `fzf` picker.
- Writes both `ANTHROPIC_MODEL` and `ANTHROPIC_DEFAULT_OPUS_MODEL`, then prints a
  restart reminder — **the change only takes effect on the next `claude` launch**
  (env is read at startup). Switching model does **not** require restarting the proxy.

## Project settings (`.claude/settings.json`)

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
rate limits).

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
copilot-proxy status                 # up? which Claude models?
copilot-proxy logs 60                # tail the proxy log
bunx copilot-api@0.7.0 check-usage   # Copilot quota/usage in terminal
# usage dashboard:
#   https://ericc-ch.github.io/copilot-api?endpoint=http://localhost:4141/usage
```

## See also

- [copilot-api](https://github.com/ericc-ch/copilot-api) — the proxy
- [`bunx` CLI aliases](../shells/aliases.md#copilot--claude-code-proxy)
- OpenCode's native GitHub Copilot provider (no proxy needed for OpenCode itself)
