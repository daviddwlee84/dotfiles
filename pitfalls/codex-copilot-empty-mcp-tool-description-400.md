# codex-copilot fails with empty MCP tool description HTTP 400

**Symptoms** (grep this section): `Invalid 'input[0].tools[0].description': empty string. Expected a string with minimum length 1`; `invalid_request_body`; `POST /responses 400`
**First seen**: 2026-08
**Affects**: Codex CLI through `@jeffreycao/copilot-api@2.1.0` and GitHub Copilot Responses
**Status**: fixed in the managed compatibility shim

## Symptom

```text
HTTP error: { error:
   { message:
      "Invalid 'input[0].tools[0].description': empty string. Expected a string with minimum length 1, but got an empty string instead.",
     code: 'invalid_request_body' } }

--> POST /responses 400
```

The model appears in `/v1/models`, `/status` shows the localhost provider, and
the request reaches `api.enterprise.githubcopilot.com`, but inference never
starts.

## Root cause

Codex persists MCP discovery as Responses `mcp_list_tools` input items. An MCP
or plugin tool may legally omit its description, which becomes an empty string
in `input[].tools[].description`. GitHub Copilot's Responses validator requires
that field to contain at least one character and rejects the entire request.
This is a payload-schema mismatch, not a model entitlement or network failure.
Codex 0.147 also sends the request with `Content-Encoding: zstd`; inspecting the
raw body as JSON silently misses the tool list until it is decompressed.

## Workaround

Use the managed launcher after applying the dotfiles:

```sh
chezmoi apply ~/.config/shell/copilot-throttle-shim.js ~/.config/shell/43_copilot_proxy.sh
source ~/.config/shell/43_copilot_proxy.sh
copilot-proxy restart
codex-copilot
```

`codex-copilot` now always starts and targets the shim on port 4142. The shim
fills only blank tool descriptions in top-level function definitions and
`mcp_list_tools` input items before forwarding `/responses`; it does not mutate
user input or JSON Schema descriptions. For a repaired zstd request it forwards
ordinary JSON and removes `content-encoding`.

## Prevention

- Keep the Unix and Windows `copilot-throttle-shim.js` copies byte-identical.
- Do not make `codex-copilot` fall back directly to port 4141; the shim is a
  Responses compatibility boundary even when burst throttling is disabled.
- The shim logs each repaired JSON path without logging request contents.

## Related

- `docs/tools/copilot-claude-proxy.md`
- `dot_config/shell/copilot-throttle-shim.js`
- `dot_config/shell/43_copilot_proxy.sh`
