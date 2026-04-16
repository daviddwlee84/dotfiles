<!-- ba8c27fa-cf2e-4152-92a1-9d350276bcf0 -->
---
todos:
  - id: "create-pueue-channel"
    content: "Create dot_config/television/cable/pueue.toml with source cycling (all/active/failed/groups), preview (log + JSON detail), watch mode, and action keybindings (pause/resume/kill/restart/remove/clean)"
    status: pending
isProject: false
---
# Pueue Television Channel

## Research Summary

- **No existing integration** found online -- this will be a novel channel.
- Television v0.15.6 (installed) supports all needed features: source cycling, watch mode, actions with `reload_source`, display/output templates.
- Pueue provides `--json` output on `status`, `log`, and `group` commands. The JSON structure contains `id`, `status` (object with `Running`/`Done`/`Paused`/`Queued`/`Stashed`), `group`, `original_command`, `path`, `label`, `dependencies`, `priority`.

## Design

### Source Commands (Ctrl+S cycles between these)

1. **All tasks** (newest first) -- default view
2. **Active only** (Running + Queued + Paused) -- operational focus
3. **Failed only** -- troubleshooting focus
4. **Groups overview** -- pueue groups with status and parallelism

Each source uses `pueue status --json | jq` to produce tab-separated rows: `ID \t StatusIcon \t [group] \t command_basename`

### Display & Output

- `display`: `{split:\t:0} {split:\t:1} {split:\t:2} {split:\t:3}` -- shows all fields nicely
- `output`: `{split:\t:0}` -- outputs just the task ID for use in actions
- `watch = 2.0` -- auto-refresh every 2 seconds so running tasks update in real-time

### Preview

- `pueue log <id> --lines 200` -- shows task output (stdout/stderr) for the selected task
- Multiple preview commands cycling with Ctrl+F:
  - `pueue log <id>` -- task output
  - `pueue status --json | jq '.tasks["<id>"]'` -- full task JSON details (deps, timing, etc.)

### Action Keybindings

| Key | Action | Command | Mode |
|-----|--------|---------|------|
| Enter | Follow/view log | `pueue follow <id>` or `pueue log <id>` | execute |
| Ctrl+P | Pause task | `pueue pause <id>` + reload | fork |
| Ctrl+R | Resume/start task | `pueue start <id>` + reload | fork |
| Ctrl+K | Kill task | `pueue kill <id>` + reload | fork |
| Ctrl+T | Restart task | `pueue restart --in-place <id>` + reload | fork |
| Ctrl+X | Remove task | `pueue remove <id>` + reload | fork |
| Ctrl+L | Clean finished tasks | `pueue clean` + reload | fork |

### File Location

`dot_config/television/cable/pueue.toml` -- deploys to `~/.config/television/cable/pueue.toml`

### Key Implementation Details

The jq command for the source needs to handle pueue's nested status object. Status can be:
- Simple string: `"Queued"`, `"Stashed"`
- Object: `{"Running": {...}}`, `{"Done": {"result": "Success"}}`, `{"Done": {"result": {"Failed": 1}}}`, `{"Paused": {...}}`

Example jq filter (will be in a shell script or inline):

```bash
pueue status --json | jq -r '
  .tasks | to_entries | sort_by(.value.id | tonumber) | reverse | .[].value |
  (if .status == "Queued" then "Queued"
   elif .status == "Stashed" then "Stashed"
   elif .status | type == "object" then
     if .status.Running != null then "Running"
     elif .status.Done != null then
       if .status.Done.result == "Success" then "Done:OK"
       else "Done:FAIL" end
     elif .status.Paused != null then "Paused"
     else (.status | keys[0]) end
   else (.status | tostring) end) as $st |
  "\(.id)\t\($st)\t[\(.group)]\t\(.original_command)"
'
```

### Matching Existing Channel Patterns

Follows the same conventions as `kill-process.toml` and `sesh.toml.reference`:
- Actions use `"fork"` mode + `"reload_source"` for operations that modify state
- `Enter` uses `"execute"` mode for following output (replaces tv)
- Tab-delimited fields with `{split:\t:N}` templates

## What to Update

Per the workspace rules:
- No README/CLAUDE.md changes needed (this is a new config file, not a new ansible role or alias)
- The channel is a standalone TOML file; no other files need modification
