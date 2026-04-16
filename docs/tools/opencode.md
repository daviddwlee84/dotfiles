# OpenCode

Notes for the local OpenCode setup on this machine, especially config choices that are intentionally **not** tracked in chezmoi.

## Why the global config stays local-only

`~/.config/opencode/config.json` is currently treated as machine-local state instead of dotfiles source of truth.

Reasons:

- it contains an absolute plugin path under `~/.config/opencode/plugins/`
- the current workaround is tied to a local provider/model combination
- this repo does not yet have a portable OpenCode config layout worth standardizing

If OpenCode config later becomes portable, move it into chezmoi deliberately instead of copying the current file as-is.

## Known issue: session title stuck as `New session - ...`

Observed on this machine with OpenCode `1.4.6`.

Symptom:

- new sessions stay at the fallback title `New session - <timestamp>`
- title generation does not complete automatically

Root cause:

- the hidden `title` agent uses `github-copilot/gpt-5-mini` for a lightweight title request
- OpenCode sends `reasoning_effort = "minimal"`
- `gpt-5-mini` rejects that value because it only accepts `low`, `medium`, or `high`

Upstream tracking:

- [anomalyco/opencode#22796](https://github.com/anomalyco/opencode/issues/22796) - title agent uses unsupported `reasoning_effort: minimal`

## Current workaround

Keep the existing local plugin config, and add this to `~/.config/opencode/config.json`:

```json
{
  "agent": {
    "title": {
      "reasoningEffort": "low"
    }
  }
}
```

This is the smallest local fix that avoids the rejected `minimal` value without pinning a different `small_model`.

## When to remove the workaround

Remove the local `agent.title.reasoningEffort` override after verifying all of the following:

- the upstream regression is fixed
- a new OpenCode version is installed locally
- a fresh session auto-generates a non-fallback title
- the OpenCode log no longer shows `reasoning_effort: "minimal"` for the title request
