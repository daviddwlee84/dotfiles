# `.chezmoiignore` `!` re-include silently no-ops; file stays "not managed" under a `**`-ignored dir

**Symptoms** (grep this section):
- You added a managed source file under a directory that `.chezmoiignore`
  excludes with a recursive `**` (or a bare directory line), plus a `!` negation
  to re-include just that one path — but the file never deploys and:
  ```
  $ chezmoi managed | grep chezmoi-dotfiles
  (nothing)
  $ chezmoi cat ~/.agents/skills/chezmoi-dotfiles/SKILL.md
  chezmoi: /Users/david/.agents/skills/chezmoi-dotfiles/SKILL.md: not managed
  ```
- `chezmoi apply` exits 0 with **no error** — the target is silently skipped.
- The source file clearly exists (`dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`)
  and is well-formed; `chezmoi execute-template` renders it fine.
- Adding `!.agents/skills/chezmoi-dotfiles` and `!.agents/skills/chezmoi-dotfiles/**`
  **after** the ignore lines changes nothing.

**First seen**: 2026-06 while adding the first-party `chezmoi-dotfiles` skill
(chezmoi v2.69.3, macOS)
**Affects**: chezmoi (all versions — it inherits gitignore matching semantics).
Any `.chezmoiignore` that ignores a subtree with `dir/**` (or a bare `dir`
line) and then tries to `!`-re-include a single child.
**Status**: workaround documented and in use — see `.chezmoiignore.tmpl`
(the `.agents/skills/*` + `.agents/skills/*/**` block).

## Symptom

`.chezmoiignore.tmpl` ignored all npx-installed agent skills:

```
.agents/skills
.agents/skills/**
.claude/skills
.claude/skills/**
```

A new first-party skill was added at `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`
(target `~/.agents/skills/chezmoi-dotfiles/SKILL.md`), with negations appended:

```
!.agents/skills/chezmoi-dotfiles
!.agents/skills/chezmoi-dotfiles/**
```

Result: the file was **still** ignored. `chezmoi managed | grep` returned
nothing; `chezmoi cat` said `not managed`; no diagnostic of any kind.

## Root cause

chezmoi's `.chezmoiignore` uses gitignore pattern semantics, including this
limitation (verbatim from `gitignore(5)`):

> It is not possible to re-include a file if a parent directory of that file is
> excluded. Git doesn't list excluded directories for performance reasons, so
> any patterns on contained files have no effect, no matter where they are
> defined.

The parent directory `.agents/skills/chezmoi-dotfiles` (and `.agents/skills`
itself) is excluded — by the bare `.agents/skills` line **and** by the recursive
`.agents/skills/**`. Once the parent dir is excluded, the `!` negation on a child
is unreachable and silently does nothing. Empirically, dropping the bare line and
keeping only `.agents/skills/**` was **not** enough either — the recursive `**`
still excludes the intermediate `chezmoi-dotfiles` directory.

## Workaround

Use **single-`*`** globs instead of `**`. `*` does not match `/`, so it excludes
direct children (the npx skill dirs) and their contents without ever excluding
the parent `.agents/skills` directory itself — leaving the `!` re-include
reachable:

```
.agents/skills/*
.agents/skills/*/**
.claude/skills/*
.claude/skills/*/**
skills-lock.json

!.agents/skills/chezmoi-dotfiles
!.agents/skills/chezmoi-dotfiles/**
!.claude/skills/chezmoi-dotfiles
```

- `.agents/skills/*` ignores each direct child (e.g. `…/find-skills`).
- `.agents/skills/*/**` ignores those children's contents (keeps full coverage
  parity with the old `**`).
- `.agents/skills` itself is never matched → the negation on one child works.

Verify (must list the file, dir, and symlink):

```
$ chezmoi managed | grep chezmoi-dotfiles
.agents/skills/chezmoi-dotfiles
.agents/skills/chezmoi-dotfiles/SKILL.md
.claude/skills/chezmoi-dotfiles
```

And confirm nothing else leaked back in:

```
$ chezmoi managed | grep -E '\.(agents|claude)/skills/' | grep -v chezmoi-dotfiles
(nothing)
```

## Prevention

When you need "ignore a whole tree EXCEPT one child" in `.chezmoiignore`:
- Never use `dir/**` or a bare `dir` line above the `!` — they exclude the parent
  and the negation becomes a silent no-op.
- Use `dir/*` + `dir/*/**` so the parent stays included, then `!dir/keep` +
  `!dir/keep/**`.
- Always confirm with `chezmoi managed | grep` — there is **no error** when a
  negation is dead.

## Related

- `docs/tools/agent-skills.md` → "First-party templated skill (`chezmoi-dotfiles`)"
  (the feature that hit this; the `.chezmoiignore` block is annotated there too).
- `docs/tools/chezmoi-prefixes.md` — other chezmoi prefix / matching gotchas.
- `.chezmoiignore.tmpl` — the load-bearing comment lives next to the patterns.
