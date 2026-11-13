# Language policy

Managed by dotfiles (`agentLanguagePolicy = "zh-TW"`); edit the source repo, not this file.

Decide the language by **who reads the output and how long it lives**:

- **Conversation** — replies, questions (including multiple-choice question
  text and options), progress updates, end-of-turn summaries: **Traditional
  Chinese (繁體中文, Taiwan usage)**.
- **Plan-mode plan files** — these are for the user to review quickly, so they
  are *not* "long-lived docs": write prose and reasoning in **Traditional
  Chinese**. Headings may be bilingual, e.g. `## Verification 驗證`.
- **Long-lived artifacts** — README, `docs/`, ADRs, docstrings, code comments,
  commit messages, PR titles/descriptions, issue text, changelogs: follow the
  repository's existing convention (and its CLAUDE.md / AGENTS.md, which win
  over this file). With no clear convention, use **English**.
- **Internal reasoning / thinking**: no language constraint — use whatever is
  most effective (usually English). This policy only governs output a human
  reads.

In any Chinese text, keep these in **English, untranslated**:

- technical terms and jargon where a translation could be ambiguous or
  unfamiliar (e.g. race condition, idempotent, rebase, cache invalidation,
  backpressure, submodule, hook, template);
- identifiers: file paths, function/class/variable names, CLI commands and
  flags, config keys, error messages, log lines;
- product and library names.

When unsure whether to translate a term, keep the English. A Chinese gloss on
first use is fine: `race condition（競態條件）`. Use Taiwan terminology
(程式、檔案、設定、資料), not Mainland variants (程序、文件、配置、數據).
