# pqsum

`pqsum` is a Zsh helper that summarizes `pueue status --json` output into readable queue metrics.

- **Function file**: `~/.config/zsh/tools/36_pueue.zsh`
- **Dependencies**: `pueue`, `jq`
- **Optional enhancement**: `column` (for aligned table rendering)
- **Version expectation**: `pueue >= 4.0.0`

## What It Shows

`pqsum` prints three sections:

1. `Overall`
   - Total task count
   - Done progress (`done/total`, ASCII progress bar, and `%`)
   - Average duration of finished tasks (`Done` only)
   - Estimated remaining time (ETA)
2. `Status Breakdown`
   - Aligned table: status, count, progress
3. `Group Summary`
   - Aligned table with: group, daemon, parallel, total, done, progress, bar, total_spent, avg_done, eta, statuses

## Usage

```bash
# Full summary
pqsum

# Single group summary (only that group is displayed)
pqsum -g default
pqsum --group synthesis

# Pass any pueue status query/filter through
pqsum status=running
pqsum "status=done order_by end desc first 20"
```

Example output shape:

```text
Pueue Summary
Overall
  Total tasks: 9
  Done progress: 9/9  [============]  100.0%
  Avg done duration: 1m 18s
  Est. remaining (ETA): 0s

Status Breakdown
  status  count  progress
  Done    9      100.0%

Group Summary
  group      daemon   parallel  total  done  progress  bar           total_spent  avg_done  eta  statuses
  default    Running  1         9      9     100.0%    [============] 4h 12m 8s    1m 18s   0s   Done=9
```

## Notes

- `pqsum` forwards all arguments to `pueue status --json`.
- If `pueue` or `jq` is missing, `pqsum` exits with non-zero and prints an error.
- Average duration only includes tasks whose `Done.start` and `Done.end` are both present.
- `total_spent` is the time span between the earliest and latest timestamps observed in that group (from task `created_at` and status timestamps such as `enqueued_at/start/end`).
- ETA is a coarse estimate based on `remaining * avg_done / max(parallel, 1)`.
- `-g/--group` controls which group rows are shown in the summary output.
- Color is enabled only on TTY output and disabled when `NO_COLOR` is set.
- If `column` is not found, `pqsum` falls back to a plain spacing renderer (still readable).

## Related

- [Pueue Advanced usage](https://github.com/Nukesor/pueue/wiki/Advanced-usage)
- [Pueue Configuration](https://github.com/Nukesor/pueue/wiki/Configuration)
