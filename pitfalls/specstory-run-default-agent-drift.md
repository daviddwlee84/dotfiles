# Bare `specstory run` launches a different agent after a specstory upgrade

**Symptoms** (grep this section): `scode` / `svibe` / `hcode` / `hvibe` / the
yazi "Claude (specstory)" opener suddenly drop you into **Antigravity CLI**
instead of Claude Code; nothing errors, `specstory check` says
`✅ All systems go!` for every provider; `specstory run --help` now reads
`By default, launches Antigravity CLI.` where it used to say Claude Code;
`~/.specstory/cli/config.toml` is unchanged and still has
`claude_cmd = "claude --dangerously-skip-permissions"`; there is no
`default_provider` / `default_agent` key anywhere in the config to fix it;
`[resume] last_agent = "codex"` looks relevant but is not.
**First seen**: 2026-08 on macOS with SpecStory CLI 2.9.0 (the release that
added the `antigravity` provider) and Antigravity CLI `agy` 1.1.13 installed.
**Affects**: any host where bare `specstory run` (no provider argument) is
invoked — every specstory version bump that registers a new provider whose ID
sorts before the one you expect.
**Status**: fixed on our side — we never emit a bare `specstory run` any more.
No upstream knob exists.

## Symptom

The visible change is only in the help text, which is generated from the
provider registry rather than hand-written:

```
$ specstory run --help

  Launch terminal coding agents in interactive mode with auto-save markdown file generation.

  By default, launches Antigravity CLI. Specify a specific agent ID to use a different agent.

  Available provider IDs: antigravity (Antigravity CLI), claude (Claude Code), codex (Codex CLI),
  copilotide (VS Code Copilot IDE), cursor (Cursor CLI), cursoride (Cursor IDE), deepseek
  (DeepSeek TUI), droid (Factory Droid CLI), gemini (Gemini CLI).
```

Because `agy` was actually installed, the wrong agent **launched
successfully** — no "provider not found" error, no warning. If Antigravity had
*not* been installed the failure would have been loud and this would have been
a 30-second diagnosis; the fact that it works is what makes it a trap.

Reproduce the resolution order without launching anything:

```
$ specstory run --console --debug 2>&1 | grep -i provider
level=INFO  msg="Provider registry initialized" count=9 \
  providers="[antigravity claude codex copilotide cursor cursoride deepseek droid gemini]"
level=DEBUG msg="Retrieved provider" requested_id=antigravity matched_id=antigravity name="Antigravity CLI"
```

That last `Retrieved provider` line — after the nine registration lines — is
the default lookup.

## Root cause

**`specstory run` with no argument resolves to the alphabetically-first entry
of the provider registry, not to a configured or pinned default.** The
registration order in the debug log is insertion order
(`claude cursor codex gemini droid cursoride copilotide deepseek antigravity`),
but the `providers="[...]"` summary — and the default pick — use the sorted
list. `antigravity` < `claude`, so merely *adding* the provider in 2.9.0
displaced Claude Code for every existing user.

The binary still carries a stale log string `Getting default provider (claude)`
and the config template still ships a commented `# last_agent = "claude"`,
which is why grepping for a config fix looks briefly promising. Neither is the
`run` default:

- `[resume] last_agent` (written by specstory itself) only affects
  `specstory resume`.
- `[providers] <id>_cmd` only customises **how** a provider launches, never
  **which** one is picked.

There is no `default_provider` key. `strings $(command -v specstory) | grep -iE
'default.?provider'` finds only the log message.

## Workaround

Name the provider explicitly. Everywhere. That is the entire fix:

```sh
specstory run claude          # not: specstory run
```

In this repo the wrapping happens in one place —
`dot_config/shell/22_sesh.sh` → `_sesh_wrap_agent()`, which `24_herdr.sh`
sources verbatim, so `scode` / `svibe` / `hcode` / `hvibe` are all covered by
the one edit:

```sh
    case "$agent" in
        ""|"specstory")
            # No agent specified → our default is claude, stated explicitly.
            printf '%s\n' "specstory run claude"
            ;;
        antigravity|claude|codex|cursor|deepseek|droid|gemini)
            printf '%s\n' "specstory run $agent"
            ;;
```

Grep for any remaining bare invocations before declaring done — the yazi
opener was a second, easily-missed site:

```sh
grep -rn 'specstory run\( \|$\)' --include='*.sh' --include='*.tmpl' \
  --include='*.toml' --include='*.py' dot_config/ dot_dotfiles/ scripts/ \
  | grep -vE 'specstory run [a-z]'
```

To add flags for a newly-registered provider, use its `<id>_cmd` key in
`private_dot_specstory/private_cli/create_config.toml` (and hand-copy into the
live `~/.specstory/cli/config.toml` — it's a `create_` file, so chezmoi seeds
it once and never touches it again):

```toml
# Antigravity CLI command (binary is `agy`; add `--effort high` if wanted)
antigravity_cmd = "agy --dangerously-skip-permissions"
```

Verify the resolved command without launching the TUI — the `-c` probe fails
on purpose, but only *after* the provider is resolved:

```
$ specstory run antigravity --console --debug 2>&1 | grep 'executing'
level=INFO msg="ExecAgentAndWatch: executing Antigravity CLI" command="agy --dangerously-skip-permissions"
```

(Note `specstory run -c "<cmd>"` with no provider is rejected outright:
`The -c/--command flag requires a provider to be specified.` — another hint
that the no-arg default is not something specstory wants you to rely on.)

## Prevention

Treat any upstream "default is X" that's derived from a registry as unstable.
The general shape: **a CLI whose default is "first of a sorted set" changes
behaviour when the set grows, with no release note and no config migration.**
The tell is help text that enumerates the set in the same order it names the
default.

`_sesh_wrap_agent()` carries a comment saying never to emit a bare
`specstory run`; keep it there. On the next specstory bump, re-check with
`specstory run --help` (one line, cheap) rather than assuming.

Also worth knowing when auditing that `case` list: `specstory run opencode`
is **not** valid — opencode is still not a registered provider, so it fails
with `❌ Provider 'opencode' is not a valid provider implementation` (see
`backlog/specstory-opencode-support.md`).

## Related

- [`specstory-custom-command-drops-configured-flags`](specstory-custom-command-drops-configured-flags.md)
  — the sibling trap in the same config file: `-c` **replaces** `<id>_cmd`
  rather than appending to it.
- [`redact-secrets-loop-with-active-specstory-writer`](redact-secrets-loop-with-active-specstory-writer.md)
  — unrelated failure mode, same tool.
- [`docs/tools/sesh.md`](../docs/tools/sesh.md) § agent wrapping table, and
  [`docs/tools/specstory.md`](../docs/tools/specstory.md) § provider commands.
- [`backlog/specstory-opencode-support.md`](../backlog/specstory-opencode-support.md)
  — upstream tracking for the one agent we still pass through raw.
