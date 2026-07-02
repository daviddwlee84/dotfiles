# lazygit — history-surgery recipes (cheatsheet)

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

## The mental model: two different "fixup"s

The word *fixup* shows up in two unrelated lazygit operations — confusing them is the #1 way to mangle history:

| Goal | lazygit | What it does |
|---|---|---|
| Add **working-tree changes** into an existing commit | **`A`** (Commits panel) = *amend commit with staged changes* | Runs `git commit --fixup` + `git rebase --autosquash` under the hood |
| Merge **two existing commits** into one | **`f`** / **`c`** (Commits panel) = *fixup / squash* | Squashes the **selected** commit **into the one below it** (older) |

So `A` = "put my edits into that old commit"; `f` = "glue these two commits together". Reaching for `f` to add a file will mash neighbouring commits instead.

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
