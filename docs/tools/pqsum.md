# pqsum

`pqsum` is a Zsh helper that summarizes `pueue status --json` output into readable queue metrics.

- **Function file**: `~/.config/zsh/tools/36_pueue.zsh`
- **Dependencies**: `pueue`, `jq`
- **Version expectation**: `pueue >= 4.0.0`

## What It Shows

`pqsum` prints three sections:

1. `Overall`
   - Total task count
   - Done progress (`done/total` and `%`)
   - Average duration of finished tasks (`Done` only)
2. `Status Breakdown`
   - Count and percentage per task status
3. `Group Summary`
   - Group daemon status
   - Parallel slots
   - Group total/done/progress
   - Group average done duration
   - Per-status counts in that group

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

## Notes

- `pqsum` forwards all arguments to `pueue status --json`.
- If `pueue` or `jq` is missing, `pqsum` exits with non-zero and prints an error.
- Average duration only includes tasks whose `Done.start` and `Done.end` are both present.
- `-g/--group` controls which group rows are shown in the summary output.

## Related

- [Pueue Advanced usage](https://github.com/Nukesor/pueue/wiki/Advanced-usage)
- [Pueue Configuration](https://github.com/Nukesor/pueue/wiki/Configuration)
