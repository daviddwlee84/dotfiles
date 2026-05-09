# Default-activate `self` host in fleet machines.toml seed

## Context

`dot_config/fleet/create_private_machines.toml.tmpl` is the chezmoi `create_`-prefix seed for `~/.config/fleet/machines.toml`. Today it ships with **only commented-out** `[[hosts]]` examples, so a fresh box has zero active hosts and `just fleet-apply` is a no-op until the user hand-edits the file.

User wants the seed to default-activate one `self` (local) host so `just fleet-apply` works out-of-the-box on a fresh machine, with `no_root_machine` inherited from the chezmoi `.noRoot` prompt and password handling handled correctly for the local case.

Key finding from exploring `scripts/fleet_apply.py`:

- For `local = true` hosts, `password_source` is **completely ignored** (gated by `if not h.local …` around line 2996). Local hosts inherit the orchestrator's TTY; chezmoi itself prompts for sudo on the parent terminal when needed.
- Therefore the user's "看看是不是能用 prompt 的方式" question resolves to: **don't write `password_source` at all for the self entry** — it's noise for local hosts.

## Change

Edit one file: `dot_config/fleet/create_private_machines.toml.tmpl`.

Add an active `self` entry after `[defaults]` and before the commented examples. Keep all 5 existing commented examples (#1–#5) unchanged — they remain copy-paste templates for adding remote SSH hosts.

### Diff sketch

After line 18 (`command_timeout = 1800`), insert:

```toml

# ---------------------------------------------------------------------------
# Default: apply to THIS machine (local execution, no SSH).
# Seeded once on `chezmoi apply`; edit freely — chezmoi won't overwrite.
# `no_root_machine` mirrors the chezmoi `.noRoot` prompt from
# .chezmoi.toml.tmpl so this entry stays consistent with how the rest of
# the dotfiles were initialised on this host.
# `password_source` is intentionally omitted: for `local = true` hosts
# fleet_apply.py skips its password gate entirely (scripts/fleet_apply.py
# ~line 2996) and chezmoi prompts for sudo on the parent terminal as usual.
# ---------------------------------------------------------------------------
[[hosts]]
name            = "self"
local           = true
no_root_machine = {{ .noRoot }}
```

Then:

- Update the leading "DELETE these and add your own" comment block (currently lines 21–22) — the new copy says the `self` entry is the live default and the commented blocks below are templates for adding **remote** hosts.
- Remove example #5 (the duplicate `local = true` self example at lines 56–64) since the active entry above now serves as the worked example. Examples #1–#4 (SSH variants) stay.
  - User chose "保留全部" but example #5 is now literally identical to the live entry; keeping it would be confusing. Re-confirm with user before deleting if unsure. **Recommended: drop #5, keep #1–#4.** If the user really wants all 5 retained, leave #5 in place — harmless, just redundant.

### `no_root_machine` polarity check

`.chezmoi.toml.tmpl:83` defines `noRoot = …` with description "No sudo/root access - skip all system package installations". `fleet_apply.py` schema: `no_root_machine = true` means the remote was init'd with `noRoot=true` (no sudo phase). Same direction → `no_root_machine = {{ .noRoot }}` (NOT `{{ not .noRoot }}`).

## Files modified

- `dot_config/fleet/create_private_machines.toml.tmpl` — only file touched.

## Cross-file maintenance check (per CLAUDE.md)

Per CLAUDE.md "fleet-apply" cross-file rule: changes to `dot_config/fleet/create_private_machines.toml.tmpl` schema require updating `docs/this_repo/fleet-apply.md`. This change is **not** a schema change (no new fields, no semantics change) — just flipping a default from "all-commented" to "self active". A one-line note in the docs (under whatever section describes the seed file) would still be courteous; will check if the doc currently asserts "ships with only commented examples" and adjust if so.

## Verification

1. `chezmoi execute-template < dot_config/fleet/create_private_machines.toml.tmpl` — confirm it renders cleanly with current `.noRoot` value.
2. Render with both polarities to sanity-check:
   - `chezmoi execute-template --init --promptBool noRoot=false < … | grep no_root_machine` → `no_root_machine = false`
   - `chezmoi execute-template --init --promptBool noRoot=true  < … | grep no_root_machine` → `no_root_machine = true`
3. On a fresh `~/.config/fleet/machines.toml` (rm + chezmoi apply), confirm: `just fleet-status` lists `self` (no error about empty inventory) and `just fleet-apply-dry-run` resolves to a local chezmoi diff.
4. `python3 -c "import tomllib; tomllib.load(open('/Users/david/.config/fleet/machines.toml','rb'))"` — TOML syntax sanity.

No code changes to `fleet_apply.py` or recipes — pure data default flip.
