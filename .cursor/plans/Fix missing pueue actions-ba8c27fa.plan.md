<!-- ba8c27fa-cf2e-4152-92a1-9d350276bcf0 -->
---
todos:
  - id: "fix-missing-actions"
    content: "Append 6 missing action definitions (pause/resume/kill/restart/remove/clean) to pueue.toml, validate TOML, deploy via chezmoi"
    status: pending
isProject: false
---
# Fix Missing Pueue Channel Actions

## Bug

The `StrReplace` that added new actions (edit, copy_command, copy_pueue_add, filter_group) replaced the old keybindings+actions block but failed to re-include the 6 original action definitions. The keybindings on lines 66-71 reference `actions:pause`, `actions:resume`, `actions:kill`, `actions:restart`, `actions:remove`, and `actions:clean`, but none of these `[actions.*]` sections exist in the file.

## Fix

Append the 6 missing action sections after `[actions.filter_group]` (line 96) in `dot_config/television/cable/pueue.toml`:

```toml
[actions.pause]
description = "Pause task"
command = "pueue pause '{split:\\t:0}'"
mode = "fork"

[actions.resume]
description = "Resume/start task"
command = "pueue start '{split:\\t:0}'"
mode = "fork"

[actions.kill]
description = "Kill task"
command = "pueue kill '{split:\\t:0}'"
mode = "fork"

[actions.restart]
description = "Restart task (in-place)"
command = "pueue restart --in-place '{split:\\t:0}'"
mode = "fork"

[actions.remove]
description = "Remove task from list"
command = "pueue remove '{split:\\t:0}'"
mode = "fork"

[actions.clean]
description = "Clean all finished tasks"
command = "pueue clean"
mode = "fork"
```

Then validate with `taplo check` and deploy with `chezmoi apply`.
