# lazygit — branch insights and history-surgery recipes

[lazygit](https://github.com/jesseduffield/lazygit) is the git TUI used here (installed via the `lazyvim_deps` role; bound to `lg`). The everyday stuff (stage, commit, branch) is obvious — this page is the **rebase/amend "surgery" that's hard to remember**, with the **lazygit keys and the equivalent CLI side by side** so you can do it either way.

> **Golden rule: only rewrite commits that have NOT been pushed.** All recipes below rewrite history (new SHAs). If a commit is already on a shared remote, don't — or you'll need `git push --force-with-lease` and coordination.

## Managed pull behavior

This dotfiles repo sets Git's global baseline to:

```gitconfig
[pull]
    rebase = true
[rebase]
    autoStash = true
```

So LazyGit's normal **`p`** pull runs as a rebase pull, and dirty working-tree changes are stashed before the rebase and re-applied afterwards. If the re-applied stash conflicts, Git keeps the autostash instead of dropping it; inspect `git status` and `git stash list`, resolve any worktree conflicts, then drop the autostash only after confirming your changes are back.

## Branch view and `I` Branch insights

The managed config makes the Local branches panel denser without spending width
on commit hashes:

- Nerd Font v3 icons clarify file and pull-request indicators.
- Branch names are colored by common prefixes (`feat/`, `fix/`, `docs/`,
  maintenance, worktree, and automation branches).
- Branches default to **recency** order.
- A right-aligned `↓N` shows how many commits a branch is behind LazyGit's
  detected base branch.

That `↓N` is useful, but it is **not** a merged marker. A branch can be behind
main and still contain commits that main does not have. Likewise, the normal
upstream `✓` means local and upstream are synchronized; it does not mean the
branch is contained in main.

In the Local branches panel, press **`I`** and choose:

| Key | Report | Network |
|---|---|---|
| `g` | Exact Git containment against local and remote-tracking main | none |
| `p` | The same report plus recent GitHub PR state from one `gh pr list` call | GitHub |

The report is read-only and does not fetch. Press LazyGit's refresh key or wait
for auto-fetch before relying on the `REM` column.

```text
Local base:  main
Remote base: origin/main
Local main vs origin/main: ahead 1, behind 0

SEL LOC REM  BASE-  BASE+ UPSTREAM      WORKTREE     DATE       BRANCH  PR
    Y   Y       12      0 gone          -            2026-08-20 fix/old  MERGED->main#42
>   Y   N        0      1 up1           repo-wt      2026-09-01 feat/new OPEN->main#43
```

- `LOC` / `REM`: the branch tip is an ancestor of local / remote main. `Y` is
  the exact `git merge-base --is-ancestor` definition of history containment.
- `BASE-`: commits only on the comparison base; the branch is behind by this
  amount.
- `BASE+`: commits only on the branch; a non-zero value means it is not fully
  contained in that comparison base.
- `UPSTREAM`: `=`, `upN`, `downN`, `downN/upN`, `gone`, or `-`.
- `WORKTREE`: the leaf directory when another/current worktree has the branch
  checked out.
- `PR`: best-effort GitHub state. `MERGED` is kept separate from `REM` because
  squash and rebase merges create different commit ancestry.

The base is inferred from `origin/HEAD`, then `main`, then `master`. Repositories
with another trunk can opt in locally without changing global dotfiles:

```bash
git config lazygit.branchBase develop
```

This setting may also name a remote-tracking ref such as `upstream/trunk`.

## The mental model: two different "fixup"s

The word *fixup* shows up in two unrelated lazygit operations — confusing them is the #1 way to mangle history:

| Goal | lazygit | What it does |
|---|---|---|
| Add **working-tree changes** into an existing commit | **`A`** (Commits panel) = *amend commit with staged changes* | Runs `git commit --fixup` + `git rebase --autosquash` under the hood |
| Merge **two existing commits** into one | **`f`** / **`c`** (Commits panel) = *fixup / squash* | Squashes the **selected** commit **into the one below it** (older) |

So `A` = "put my edits into that old commit"; `f` = "glue these two commits together". Reaching for `f` to add a file will mash neighbouring commits instead.

## Recipe: see which commits changed a file (file history)

Read-only lookup — no history rewrite, safe even on pushed commits.

**lazygit**
1. **`<ctrl+s>`** (global) → *View options for filtering the commit log* → enter the **path**. The **Commits** panel now lists only commits that touched it; **`<enter>`** on any commit drills into that file's diff. **`<ctrl+s>`** again to clear the filter.

lazygit's filter doesn't follow renames and makes you open commits one at a time — for real file-history browsing a dedicated tool is nicer:

**CLI**
```bash
tig path/to/file                             # best: log scoped to the file, <enter> opens each commit's diff, follows renames
git log --follow -p        -- path/to/file   # follow renames + full diff each time (piped through delta here)
git log --follow --oneline -- path/to/file   # quick "which commits touched it"
```

## Recipe: add an uncommitted file into an OLDER commit

**lazygit**
1. **Files** panel: press **`<space>`** on *only* the file you want. **Do not press `a`** — that's *stage all* and will sweep unrelated edits into the amend.
2. **Commits** panel: select the target commit → **`A`**.

**CLI**
```bash
git add path/to/file
git commit --fixup=<target-sha>
git rebase --autosquash --autostash <target-sha>~1
# non-interactive (skip the editor): prefix with  GIT_SEQUENCE_EDITOR=true
```

## Recipe: pull ONE file OUT of a commit, back to the working tree

The inverse — un-commit a single file from an unpushed commit into "not staged" changes. lazygit's **custom patch** is the native tool.

**lazygit**
1. **Commits** panel: select the commit → **`<enter>`** to view its files.
2. Highlight the file → **`<space>`** (adds the whole file to the custom patch — it gets marked).
3. **`<ctrl+p>`** → *View custom patch options* → **`move patch out into index`**. This rewrites the commit without the file and stages the change.
4. **Files** panel: **`<space>`** on the file to **unstage** it → now it's a *Changes not staged* edit.

> In the patch menu, `move patch out into index` is what you want. `remove patch from original commit` **discards** the change (lost) — don't pick that if you want to keep it.

**CLI**
```bash
git rebase -i <sha>~1                 # mark <sha> as 'edit', save & quit
git reset HEAD^ -- path/to/file       # un-commit just that file -> working-tree change
git commit --amend --no-edit          # re-make the commit without it
git rebase --continue
```

## Recipe: fork working-tree changes into a new file, restore the original

You edited a file but want to keep those edits as a *separate* new file while resetting the original back to `HEAD` (e.g. spin an experiment off into a copy). No single keybinding, but two quick steps: the copy captures the modified content, then discard restores the original.

**lazygit**
1. **`:`** (*Execute shell command*) → `cp path/to/file path/to/file.new` — the copy grabs the **current, modified** content. The `:` shell runs at the repo root.
2. **Files** panel: select the original → **`d`** → *discard* → restored to `HEAD`.
3. Edit `path/to/file.new` from there.

**CLI**
```bash
cp path/to/file path/to/file.new   # modified content -> new file
git restore path/to/file           # original back to HEAD  (git checkout -- <file> on older git)
```

> Want to *re-apply* the change later rather than fork it? `git stash` saves the edit and restores the original in one step — but it lands in the stash list, not a new file.

## Recipe: recover from a botched rebase

**lazygit** — **`z`** undo / **`Z`** redo (works on branch/commit ops; the worktree must be clean). For deeper recovery use the reflog via CLI:

**CLI**
```bash
git reflog                       # find the good SHA from before the mess (e.g. the original HEAD)
git reset --hard <good-sha>      # restore branch + worktree to that point
```

- **Gotcha:** `git reset --hard` **deletes files that were staged as new adds** (e.g. a freshly `git add`ed plan file) — back them up first. It leaves *plain untracked* files alone.
- Re-apply any uncommitted WIP you want to keep afterwards (e.g. `git diff > /tmp/wip.patch` before, `git apply /tmp/wip.patch` after).

## Footguns

- **`a` = stage ALL** in lazygit. It silently sweeps unrelated edits (e.g. a transient config tweak) into whatever amend/fixup you do next. Stage one file with **`<space>`**.
- After any of these, the commit's **SHA changes**. Fine for local commits; push normally (force only if it was already pushed).
- Commit discipline when files are partially staged: `git reset` to clear the index, then `git add` exactly what you mean before `git commit`.

## See also

- [git diff workflow](git_diff_workflow.md)
- Per-tool tips/recipes live under `docs/tools/<tool>.md` — this page is the home for git/lazygit recipes.
