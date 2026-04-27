# `redact-secrets` keeps "redacting" the same JWT but `gitleaks` still fails

**Symptoms** (grep this section):
- `git commit` of a SpecStory transcript fails repeatedly. Pre-commit
  output says the secret was redacted, but the next hook (gitleaks) still
  finds it:
  ```
  Auto-redact secrets in agent artifacts...................................Failed
  - hook id: redact-agent-secrets
  - files were modified by this hook
  …
  Successfully redacted 1 file(s)

  Detect hardcoded secrets.................................................Failed
  - hook id: gitleaks-system
  Finding:     ...y.com --cloud-token REDACTED --config-dir /var/f...
  Secret:      REDACTED
  RuleID:      jwt
  ```
- Re-running `git add file && git commit` (which usually clears the loop —
  pre-commit's auto-fix flow is "stash unstaged → fix staged → restore
  unstaged → re-stage manually") doesn't help. The redacted version on
  disk reverts to the original after each commit attempt.
- `grep -c "eyJhbGci" file` keeps returning a non-zero count even right
  after `just redact-secrets`. The count tends to *increase* over commit
  attempts, not stay flat.
- `just add-and-redact` reports "Successfully redacted N file(s)" but the
  next `grep` shows the same N back, plus a few new occurrences.
- The leaked secret is something the user *did not type* — typically a JWT
  pulled from `ps -axo args` output of an unrelated background daemon
  (e.g. SpecStory's own `--cloud-token …` flag in its `specstory_darwin_*
  watch` process).

**First seen**: 2026-04 while committing `agent-panes` feature on
`Da-Weis-Mac-mini` (macOS 26.2). Triggered by running `ps -axo pid,comm,args`
in the chat to debug Cursor Agent CLI detection — the `ps` output included
SpecStory's own daemon process line with a JWT in argv.
**Affects**: any session where (a) SpecStory is actively writing the
transcript, AND (b) the chat captures `ps`/`pgrep -fl`/`top -ax`-style
output containing another process's secrets in argv.
**Status**: no permanent fix yet — workaround is the atomic
"redact-without-print → stage → commit" pipeline below. A real fix would
need either a SpecStory pause/resume API or pre-commit running the redact
hook in a transactional way that survives concurrent writes.

## Why it loops

SpecStory's `specstory_darwin_arm64 watch` daemon tails the agent's
input/output and appends to `.specstory/history/<session>.md` continuously.
Pre-commit's auto-fix flow assumes the file is **quiescent during the
commit**:

1. `git commit` invokes pre-commit.
2. Pre-commit stashes unstaged worktree changes.
3. The `redact-agent-secrets` hook (`scripts/redact_secrets.py --fix`)
   scans the *staged* version, finds the JWT, redacts it. Both the index
   and the worktree now hold the redacted version.
4. Some downstream hook (or pre-commit's restore step) puts the unstaged
   stash back on top of the worktree — but that stash captured the
   *original, unredacted* file because the user hadn't `git add`-ed it
   between the redact and the restore. Worktree is back to unredacted.
5. `gitleaks-system` then runs on the *staged* version (which IS redacted)
   and *should* pass — but if any new specstory write happened mid-flight
   that re-introduced the JWT into the staged content (rare), or if the
   user re-runs `git add` between attempts, the loop re-enters.

The kicker: **every diagnostic command makes it worse.** `grep
"cloud-token"` on the file prints the JWT to the chat → SpecStory captures
the chat → the literal JWT lands at a *new* line in the transcript.
`just redact-secrets` then needs to redact two copies; by the time you
re-stage, a third copy has been appended.

## Fix (the atomic pipeline)

Do the redaction without ever printing the matched bytes, then stage and
commit in **one** bash command so SpecStory has no window to write a new
copy:

```bash
FILE=.specstory/history/<active-session>.md

# 1. Redact in place. NEVER use grep/awk/sed in a way that prints the match.
python3 -c "
import re, pathlib
p = pathlib.Path('$FILE')
s = p.read_text()
s2 = re.sub(r'ey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
            '<REDACTED-JWT>', s)
p.write_text(s2)
"

# 2. Stage the redacted snapshot. From this moment, the index is frozen —
# any later specstory write only affects the worktree, not the commit.
git add "$FILE"

# 3. Commit. Pre-commit will stash any post-stage worktree drift, run on
# the staged (redacted) version, find nothing, and commit cleanly.
git commit -m "..."
```

The redaction regex above (`ey[A-Za-z0-9_-]{8,}\.{10,}\.{10,}`) is
JWT-shaped (3 base64url segments separated by dots) and catches the common
case. Adjust per the actual leak class.

## Don't do these (they re-introduce the leak)

- `grep "<secret-substring>" file` — prints the secret to chat, SpecStory
  appends it back into the transcript on the next chat turn.
- `cat file | head -n NNNN | tail -n M` to inspect the secret line — same
  problem.
- `sed -n '<line>p' file` — same.
- `git diff` of the leaked file — same. Use `git diff --stat` to see
  scope without payload.
- `pre-commit run --files <file>` in a fresh terminal expecting it to
  "just work" — it has the same race with SpecStory.
- `git stash` mid-attempt — the stash captures the unredacted worktree;
  popping later restores the leak.

## When the loop does NOT happen (sanity check)

The standard pre-commit auto-fix flow IS supposed to work — the loop
shows up only when *something else is actively writing the file*. If you
hit this with no concurrent agent running, the cause is different (likely
a regex-vs-leak mismatch in `scripts/redact_secrets.py` or `gitleaks.toml`).

Quick diagnostic: `lsof <transcript-file>` — if SpecStory's
`specstory_darwin_*` is in the writers, you're in this trap. Otherwise
look elsewhere.

## Adjacent

- [CLAUDE.md → Agent artifact redaction](../CLAUDE.md) — the four
  auto-scanned prefixes (`.specstory/history/`, `.claude/plans/`,
  `.cursor/plans/`, `.opencode/plans/`) and the gitleaks pipeline.
- [`scripts/redact_secrets.py`](../scripts/redact_secrets.py) — the
  `--fix` implementation. Loop-handling improvements (e.g. an
  `lsof`-aware "wait until quiescent" mode) would land here.
- [`agent-history-hygiene` skill](https://github.com/daviddwlee84/agent-skills)
  — the skill that prescribes the standard `commit chat transcripts
  alongside the feature` workflow assumes no concurrent writers.
