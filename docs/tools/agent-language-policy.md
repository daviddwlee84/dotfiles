# Agent language policy (`agentLanguagePolicy`)

Which language a coding agent writes in, decided by **who reads the output and
how long it lives**: chat in Traditional Chinese, plan files in Traditional
Chinese with English technical terms, long-lived artifacts in whatever the repo
already uses (English by default).

> **TL;DR** — set `agentLanguagePolicy = "zh-TW"` (the `personal-mac` /
> `work-mac` bundles already do). `chezmoi apply` then deploys
> `~/.claude/rules/language-policy.md`. Your own `~/.claude/CLAUDE.md`, if any,
> is never touched.

## What the rule says

| Output | Language |
|---|---|
| Conversation: replies, questions (incl. multiple-choice options), progress updates | 繁體中文 (Taiwan usage) |
| Plan-mode plan files | 繁體中文 prose; headings may be bilingual |
| README, `docs/`, ADRs, docstrings, code comments, commit messages, PRs | The repo's convention (its CLAUDE.md / AGENTS.md wins); English if none |
| Internal reasoning / thinking | Unconstrained — whatever is most effective (usually English) |

Inside Chinese text, technical terms whose translation could be ambiguous,
identifiers (paths, functions, CLI flags, config keys, error messages) and
product names stay in English. A gloss on first use is fine:
`race condition（競態條件）`.

The source of truth is
[`.chezmoitemplates/agent-language-policy.md`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/agent-language-policy.md).
It is byte-identical to the copy in the Windows repo. Edit the template, never
the deployed file.

## How it is wired

- **Prompt**: `agentLanguagePolicy` (`none` | `zh-TW`, default `none`). It only
  has an effect when `installCodingAgents` is also true.
- **Target**: `~/.claude/rules/language-policy.md`. Claude Code loads every
  file in `~/.claude/rules/` as a user-level rule in every project, next to
  `~/.claude/CLAUDE.md`, so no `@import` or CLAUDE.md edit is needed.
- **Gate**: `dot_claude/rules/language-policy.md.tmpl` renders empty unless the
  gate is on. chezmoi removes a target whose source renders empty, so switching
  back to `none` deletes the rule on the next apply. Only this one filename is
  managed; other files in `~/.claude/rules/` are yours.

To change your answer:

```bash
chezmoi init --prompt   # or edit agentLanguagePolicy in ~/.config/chezmoi/chezmoi.toml
chezmoi apply
```

Verify in a new Claude Code session with `/memory`. The user rule should be
listed there.

## Design choices

- **Why not `settings.json` `language`?** Claude Code passes that value
  verbatim as "always respond in X". That would pull commit messages and docs
  into Chinese too, and it also changes the voice-dictation and session-title
  language. A context-dependent policy needs written rules.
- **Why not write into `~/.claude/CLAUDE.md`?** It is a file you author by
  hand. A rules file avoids migration and merge logic entirely. If your own
  CLAUDE.md also states a language rule, both load. When they conflict, Claude
  may follow either one, so delete one side.
- **Why are plan files called out separately?** Plans are markdown documents.
  Without an explicit line, "docs in English" would capture them.
- **Why leave thinking alone?** Studies on multilingual reasoning models
  (e.g. Qi et al. 2025, *When Models Reason in Your Language*) report lower
  accuracy when the thinking trace is forced into the user's language. The
  policy only governs output a human reads.
- **Scope**: Claude Code only. Codex's `~/.codex/AGENTS.md` is user-owned and
  has no rules directory. See `TODO.md`.

Cross-platform decision record:
[dotfiles-all `docs/agent-language-policy.md`](https://github.com/daviddwlee84/dotfiles-all/blob/main/docs/agent-language-policy.md).
