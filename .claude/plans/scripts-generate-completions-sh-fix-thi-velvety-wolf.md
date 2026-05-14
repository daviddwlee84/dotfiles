# Fix `chezmoi: 50_generate_completions.sh: exit status 1`

## Context

`chezmoi apply` reports `exit status 1` for the `run_after_50_generate_completions.sh.tmpl` hook. The hook calls `bash scripts/generate_completions.sh --quiet`, which is a best-effort completion-refresh script that should never abort the apply.

The script is fine on a fully-cached run (everything skipped). The bug only fires **when `--quiet` is set AND at least one tool needs to regen its bash-block completion** (i.e. the common case right after any tool upgrade — which is exactly what `run_after_*` is for).

## Root cause

`scripts/generate_completions.sh` runs with `set -euo pipefail`. Inside `regen()` (lines 65–102), the `bash` block is the *last* block of the function:

```bash
if [ "$force" = 1 ] || [ ! -f "$bfile" ] || [ "$bin" -nt "$bfile" ]; then
  if "$tool" $bargs >"$bfile.tmp" 2>/dev/null && [ -s "$bfile.tmp" ]; then
    mv "$bfile.tmp" "$bfile"
    n_b_regen=$((n_b_regen + 1))
    [ "$quiet" = 0 ] && printf '  bash  %-10s → %s\n' "$tool" "$bfile"   # ← line 95
  else
    rm -f "$bfile.tmp"
  fi
else
  n_b_skip=$((n_b_skip + 1))
fi
```

When `--quiet` is passed, `quiet=1`, so `[ "$quiet" = 0 ]` returns 1 and `&&` short-circuits. That `&&` compound is the **last command** of the inner `if`-`then` body, which becomes the last command of the outer `if`-`then` body, which is the last command of `regen()`. The function returns 1, `regen` is called as a top-level command, and `set -e` aborts the script with exit 1.

Reproducer (verified):

```bash
touch -t 199001010000 ~/.zfunc/_chezmoi ~/.local/share/bash-completion/completions/chezmoi
bash scripts/generate_completions.sh --quiet; echo $?   # → 1
```

The corresponding minimal bash test that isolates the footgun:

```bash
bash -c 'set -e; f() { if true; then [ 1 = 0 ] && echo hi; fi; }; f; echo after'
# → no "after", exit 1
```

This is a known bash `set -e` × `&&`-short-circuit-at-tail-of-function interaction. Bash's "ignore -e in `&&` LHS" rule does NOT cleanly propagate when the failed-but-ignored command happens to be the last statement of a function called as a top-level command.

The zsh block has the same shape on line 81, but it isn't the last block in the function, so on its own it can't trip `set -e` (its non-zero status gets overwritten by the subsequent bash block). The bug only manifests via the bash block — but the same hazard exists in both, and either block can become "last" if the function is edited.

## Fix

Append `return 0` to the end of `regen()` in `scripts/generate_completions.sh`. One line, no semantic change for the success path, and documents the function's "best-effort, never fail" contract.

### File / line

`scripts/generate_completions.sh` — add a line at the end of the `regen()` function body (currently closing brace at line 102):

```bash
  else
    n_b_skip=$((n_b_skip + 1))
  fi

  return 0          # ← add this
}
```

### Why not other options

- **Replace `[ "$quiet" = 0 ] && printf …` with `if [ "$quiet" = 0 ]; then printf …; fi`** — works, but duplicates the bug fix in two places (lines 81 + 95) and leaves the next maintainer to re-discover the footgun if they add a third such line.
- **Append `|| :` to each `&&` line** — works, but cryptic; the intent ("don't let this fail the function") is hidden in the punctuation.
- **Drop `--quiet` from the wrapper** — masks the bug rather than fixing it; loses the desired chezmoi-apply terseness.
- **Make the wrapper `bash "$generator" --quiet || true`** — silences all failures including legitimate ones (mkdir denied, generator script syntax-broken, etc.); only do this if we want this hook to be unconditionally non-fatal, which is a policy change separate from the bug.

## Verification

1. **Reproduce pre-fix** (already done):
   ```bash
   touch -t 199001010000 ~/.zfunc/_chezmoi ~/.local/share/bash-completion/completions/chezmoi
   bash scripts/generate_completions.sh --quiet; echo "EXIT=$?"
   # → EXIT=1
   ```

2. **Confirm post-fix** with the same stale-mtime trick:
   ```bash
   touch -t 199001010000 ~/.zfunc/_chezmoi ~/.local/share/bash-completion/completions/chezmoi
   bash scripts/generate_completions.sh --quiet; echo "EXIT=$?"
   # → EXIT=0, and both _chezmoi / chezmoi files have fresh mtimes
   ```

3. **Run via the chezmoi wrapper** (matches production path):
   ```bash
   touch -t 199001010000 ~/.zfunc/_just ~/.local/share/bash-completion/completions/just
   chezmoi execute-template < .chezmoiscripts/global/run_after_50_generate_completions.sh.tmpl | bash
   echo "EXIT=$?"   # → 0
   ```

4. **Full apply smoke**:
   ```bash
   chezmoi apply --verbose 2>&1 | grep -i complet
   ```
   Should print `completions: regenerated N zsh + N bash | …` and `chezmoi apply` itself should exit 0.

5. **Idempotency** — second run with everything fresh should be a no-op:
   ```bash
   bash scripts/generate_completions.sh --quiet; echo $?   # → 0, no output (all cached)
   ```

## Out of scope

- The `mise: mise` `command -v` quirk visible in the trace (mise is a shell function in interactive shells; under `bash <script>` the function is NOT inherited, so `command -v mise` resolves to the binary). Not related to this bug.
- Hardening the wrapper into a fully non-fatal hook (`|| true` in `run_after_50_generate_completions.sh.tmpl`). Separate policy decision; revisit only if other best-effort failure modes show up.
