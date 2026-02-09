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
2. `Status Breakdown`
   - Aligned table: status, count, progress
3. `Group Summary`
   - Aligned table with: group, daemon, parallel, total, done, progress, bar, avg_done, statuses

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

Status Breakdown
  status  count  progress
  Done    9      100.0%

Group Summary
  group      daemon   parallel  total  done  progress  bar           avg_done  statuses
  default    Running  1         9      9     100.0%    [============] 1m 18s   Done=9
```

## Notes

- `pqsum` forwards all arguments to `pueue status --json`.
- If `pueue` or `jq` is missing, `pqsum` exits with non-zero and prints an error.
- Average duration only includes tasks whose `Done.start` and `Done.end` are both present.
- `-g/--group` controls which group rows are shown in the summary output.
- Color is enabled only on TTY output and disabled when `NO_COLOR` is set.
- If `column` is not found, `pqsum` falls back to a plain spacing renderer (still readable).

## Related

- [Pueue Advanced usage](https://github.com/Nukesor/pueue/wiki/Advanced-usage)
- [Pueue Configuration](https://github.com/Nukesor/pueue/wiki/Configuration)
