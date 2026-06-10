---
name: prompt ssot codegen
overview: Make dotfiles_init.py's PROMPTS the single source of truth for chezmoi prompts, generating the .chezmoi.toml.tmpl prompt block and Dockerfile flags from it (with declarative OS/profile conditions), prefer a non-snap chezmoi in the bootstrap/TUI, and commit the work.
todos:
  - id: commit-bugfix
    content: Commit the already-verified bugfix (installTunnelTools + choice-prompt collection + Dockerfile arg) as a standalone commit
    status: completed
  - id: when-model
    content: Add When dataclass (os/profile/arch) with to_go() + matches(); extend Prompt with condition/else_value/comment; remove darwin_only and discordChannel special-case
    status: completed
  - id: apply-matrix
    content: Set conditions on the 6 gated prompts (3 existing + installInputMethod/installBrewApps desktop-class, noRoot linux-only) and migrate per-prompt template comments into PROMPTS
    status: completed
  - id: generalize-gating
    content: Update ask_features/ask_choices/resolve_*_non_interactive/build_chezmoi_argv to gate via condition.matches(os, profile, arch); unify profile choices (include centos_server)
    status: completed
  - id: generator
    content: "Implement gen [--check]: render .chezmoi.toml.tmpl prompt block + Dockerfile ARG/RUN regions between markers; README coverage check; replace doctor"
    status: completed
  - id: snap-fix
    content: Add _resolve_chezmoi() (prefer ~/.local/bin, warn/offer reinstall on /snap) in the TUI and proactive chezmoi install + PATH ordering in bootstrap.sh
    status: completed
  - id: wiring-docs
    content: Add pre-commit gen --check hook, just gen-prompts recipe, and update scripts/init/README.md + CLAUDE.md prompt-adding instructions
    status: completed
  - id: regen-verify-commit
    content: Run gen to regenerate surfaces, verify gen --check clean + Docker build has no interactive fallback, then commit the refactor
    status: completed
isProject: false
---

# Prompt Single-Source-of-Truth + snap chezmoi fix

## Why
Prompts are duplicated across four hand-maintained surfaces (`.chezmoi.toml.tmpl`, `Dockerfile`, `dotfiles_init.py` `PROMPTS`, README table). `installTunnelTools` drifted out of two of them, so `chezmoi init` fell back to interactive prompts mid-apply. Also the TUI used `/snap/bin/chezmoi`, which has a known stdin/stdout `permission denied` bug and is not equivalent to the `~/.local/bin` install the README documents.

## Anchoring constraint
`bootstrap.sh` fetches `dotfiles_init.py` as a single standalone file (`uv run --script <url>`) on a machine with no repo cloned yet. So the canonical prompt data MUST stay embedded in that one `.py`. Canonical = enriched `PROMPTS`; a `gen` subcommand renders the other surfaces.

## Commit 1 — land the already-verified bugfix
Current uncommitted edits (add `installTunnelTools`, collect choice prompts, Dockerfile arg) are done and pass `doctor` + dry-run. Commit them first as a self-contained fix so the refactor lands separately.

## Conditionality model
Add a small structured `When` (no string DSL) to `[scripts/init/dotfiles_init.py](scripts/init/dotfiles_init.py)`:

```python
@dataclass(frozen=True)
class When:
    os: frozenset[str] = frozenset()       # {"darwin"} / {"linux"}
    profile: frozenset[str] = frozenset()  # {"ubuntu_desktop"} ...
    arch: frozenset[str] = frozenset()
```

- `to_go()` -> Go template expr: `os`->`.chezmoi.os`, `arch`->`.chezmoi.arch`, `profile`->`$profile` (init-time local var); OR within a dim, AND across dims.
- `matches(os, profile, arch)` -> bool, for TUI gating.

Extend `Prompt` with `condition: When | None`, `else_value` (baked when condition is false), `comment` (the bilingual doc block, migrated from the template so it stays single-source). Replace the existing `darwin_only` flag and the `discordChannel` special-case with `condition`.

### Gating matrix (confirmed)
- Formalize existing: `installAiDesktopApps` = `When(os={darwin})` else `false`; `installAuditd` = `When(os={linux})` else `false`; `discordChannel` = `When(profile={ubuntu_desktop})` else `"none"`.
- New gates: `installInputMethod` = `When(profile={macos,ubuntu_desktop})` else `false`; `installBrewApps` = `When(profile={macos,ubuntu_desktop})` else `false`; `noRoot` = `When(os={linux})` else `false`.
- All other prompts stay ungated.

## Generator + drift guard
`dotfiles_init.py gen [--check]` (replaces `doctor`):
- Renders the **feature/preference** prompt block into `[.chezmoi.toml.tmpl](.chezmoi.toml.tmpl)` between `# >>> dotfiles-init:prompts (generated) >>>` / `# <<< ... <<<` markers. The 3 hidden basics (`profile`/`email`/`name`) and the `$profileChoices`/`$profile`/`umask`/`[diff]`/`[status]` sections stay hand-written above the region (profile keeps assigning `$profile`).
- Renders two marked regions in `[Dockerfile](Dockerfile)`: the `ARG CHEZMOI_*` block and the full `chezmoi init` RUN (flags can't be `#`-commented mid-RUN, so the whole RUN is generated; `CHEZMOI_REPO` + prefix stay stable).
- README: wrap the Optional Components table in `<!-- dotfiles-init:prompts -->` markers and run a **coverage check** (every non-hidden prompt key appears) rather than overwriting curated prose/doc-links.
- `--check`: re-render, diff against disk, non-zero on drift.

This makes the original bug class structurally impossible: template prompts, TUI flags, and Dockerfile flags all derive from one `PROMPTS`.

## snap chezmoi (prefer_local)
- `[scripts/init/dotfiles_init.py](scripts/init/dotfiles_init.py)`: add `_resolve_chezmoi()` that prefers `~/.local/bin/chezmoi`; if the only binary is under `/snap`, warn (stdin/stdout bug) and offer to install the canonical binary to `~/.local/bin` (reuse `install_chezmoi_interactive`; auto-install under `--yes`). Surface the chosen path + warning in the preflight table.
- `[bootstrap.sh](bootstrap.sh)`: after ensuring `uv`, ensure `~/.local/bin/chezmoi` exists when no chezmoi is found OR the found one is under `/snap` (install via `get.chezmoi.io/lb`), and keep `~/.local/bin` first on PATH so the TUI resolves the non-snap binary.

## Docs + wiring
- Add a local pre-commit hook in `[.pre-commit-config.yaml](.pre-commit-config.yaml)` running `uv run --script scripts/init/dotfiles_init.py gen --check`.
- Add a `just gen-prompts` recipe in `[justfile](justfile)`.
- Update the "Adding a new chezmoi prompt" instructions in `[scripts/init/README.md](scripts/init/README.md)` and the cross-file rule in `[CLAUDE.md](CLAUDE.md)` to "edit `PROMPTS`, run `just gen-prompts`" (no more manual 3-file edits).
- No general CI exists (only `docs.yml`); pre-commit + the no-TTY Docker build remain the integration guards.

## Commit 2 — the SSOT refactor + snap fix
Regenerate template/Dockerfile via `gen`, verify `gen --check` is clean, `doctor`-equivalent passes, and a Docker build still completes without interactive fallback; commit.
