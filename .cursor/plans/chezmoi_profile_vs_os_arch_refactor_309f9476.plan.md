---
name: chezmoi profile vs os/arch refactor
overview: Collapse the redundant `macos_intel` profile into `.chezmoi.arch`, rewrite all OS-based `.profile` conditionals to use `.chezmoi.os`, keep `.profile` only where it encodes a genuine user role (ubuntu_server vs ubuntu_desktop). Ship a new `docs/tools/chezmoi-templating.md` and update AGENTS.md / CLAUDE.md with the "profile vs built-ins" rule.
todos:
  - id: prompt
    content: "Rewrite .chezmoi.toml.tmpl profile prompt: promptChoiceOnce, drop macos_intel, auto-default via .chezmoi.os, switch installAiDesktopApps gate to .chezmoi.os"
    status: completed
  - id: os_sites
    content: Replace 'or (eq .profile macos) (eq .profile macos_intel)' with 'eq .chezmoi.os "darwin"' across the 5 bootstrap/onchange scripts and Brewfile.tmpl
    status: completed
  - id: zsh_exports
    content: Collapse nested 'ne .profile' snap-path guard in dot_config/zsh/00_exports.zsh.tmpl to 'eq .chezmoi.os linux'; unify brew eval with dot_zshrc.tmpl
    status: completed
  - id: ansible_roles
    content: "In run_onchange_after_20_ansible_roles.sh.tmpl: keep ubuntu_desktop/ubuntu_server branch, collapse macos/macos_intel, switch Bitwarden desktop gate to '(eq .chezmoi.os darwin) OR (eq .profile ubuntu_desktop)'"
    status: completed
  - id: arch_sites
    content: Switch Brewfile.darwin.tmpl 'ne .profile macos_intel' (3 sites) to 'eq .chezmoi.arch arm64'; rewrite run_once_before_02_fix_intel_homebrew.sh.tmpl guard and dot_zshrc.tmpl:42 to combined os+arch check
    status: completed
  - id: new_doc
    content: Create docs/tools/chezmoi-templating.md with decision table, before/after examples, migration note for macos_intel users
    status: completed
  - id: agent_docs
    content: Add 'Chezmoi Templating Conventions' section to AGENTS.md and CLAUDE.md; update Profiles tables (drop macos_intel row)
    status: completed
  - id: verify
    content: "Verify: 'rg macos_intel' excluding .specstory and *.md returns nothing; chezmoi apply --dry-run on all supported platforms; just docker-test passes"
    status: completed
  - id: todo-1776758918832-yyz30d3ho
    content: git commit changes (with specstory chat history)
    status: completed
isProject: false
---

# Chezmoi profile vs `.chezmoi.os`/`.chezmoi.arch` refactor

## Rule we're encoding

- OS fact (darwin/linux) → `.chezmoi.os`
- CPU arch fact (amd64/arm64) → `.chezmoi.arch`
- User role choice that can't be auto-detected (desktop vs server) → `.profile`

One small breaking change: collapse `macos_intel` (user confirmed). Existing Intel macOS installs will need to either run `chezmoi init --force` or flip `profile = "macos_intel"` → `profile = "macos"` in `~/.config/chezmoi/chezmoi.toml` once. Documented in the new templating doc and in the migration note below.

## 1. `.chezmoi.toml.tmpl` — profile prompt

At [`.chezmoi.toml.tmpl:6`](.chezmoi.toml.tmpl):

- Replace `promptStringOnce` with `promptChoiceOnce` (validates input).
- Drop `macos_intel` from options: `macos | ubuntu_desktop | ubuntu_server`.
- Auto-default via `.chezmoi.os` (`darwin` → `macos`, else → `ubuntu_server`) so `chezmoi init` just works.
- Gate `installAiDesktopApps` at [`.chezmoi.toml.tmpl:25`](.chezmoi.toml.tmpl) on `eq .chezmoi.os "darwin"` (the `or (eq $profile "macos") (eq $profile "macos_intel")` pattern).

```go-template
{{- $defaultProfile := "ubuntu_server" -}}
{{- if eq .chezmoi.os "darwin" -}}{{- $defaultProfile = "macos" -}}{{- end -}}
{{- $profile := promptChoiceOnce . "profile" "Which profile?" (list
    (dict "value" "macos"          "prompt" "macOS (Apple Silicon or Intel - auto-detected)")
    (dict "value" "ubuntu_desktop" "prompt" "Ubuntu Desktop (full GUI)")
    (dict "value" "ubuntu_server"  "prompt" "Ubuntu Server (headless)")
) $defaultProfile }}
```

(Exact API per [chezmoi init functions → promptChoiceOnce](https://www.chezmoi.io/reference/templates/init-functions/promptChoiceOnce/).)

## 2. Site-by-site rewrites (OS)

For every `or (eq .profile "macos") (eq .profile "macos_intel")` → `eq .chezmoi.os "darwin"`:

- [`run_once_before_00_bootstrap.sh.tmpl:43,66`](run_once_before_00_bootstrap.sh.tmpl)
- [`run_onchange_after_20_ansible_roles.sh.tmpl:49,85,152`](run_onchange_after_20_ansible_roles.sh.tmpl)
- [`run_onchange_after_25_bat_theme.sh.tmpl:8`](run_onchange_after_25_bat_theme.sh.tmpl)
- [`run_onchange_after_30_brew_bundle.sh.tmpl`](run_onchange_after_30_brew_bundle.sh.tmpl) — 6 sites (lines 14, 39, 56, 75, 119 + the negated form `(and (ne .profile "macos") (ne .profile "macos_intel"))` at line 8 → `(ne .chezmoi.os "darwin")`)
- [`dot_config/homebrew/Brewfile.tmpl:19`](dot_config/homebrew/Brewfile.tmpl)

For [`dot_config/zsh/00_exports.zsh.tmpl`](dot_config/zsh/00_exports.zsh.tmpl):

- Lines 24–30 (nested `ne` guards for snap path) → single `{{ if eq .chezmoi.os "linux" -}}`
- Line 35 (macOS brew eval) → `eq .chezmoi.os "darwin"`
  (consistent with the already-correct [`dot_zshrc.tmpl:62`](dot_zshrc.tmpl) block)

For [`run_onchange_after_20_ansible_roles.sh.tmpl:89-96`](run_onchange_after_20_ansible_roles.sh.tmpl):

- **Keep** the `ubuntu_desktop` vs `ubuntu_server` branch — that's the one place profile carries real semantic weight (tag set differs: desktop has `nerdfonts`, `alacritty`).
- Only the `eq .profile "macos"` branch becomes `eq .chezmoi.os "darwin"`, collapsed with the old `macos_intel` branch.

For [`run_onchange_after_20_ansible_roles.sh.tmpl:136`](run_onchange_after_20_ansible_roles.sh.tmpl) (Bitwarden Desktop gate, "is this a desktop?"):

```go-template
{{ if and $installBitwarden (or (eq .chezmoi.os "darwin") (eq .profile "ubuntu_desktop")) -}}
```

## 3. Site-by-site rewrites (arch — Apple Silicon vs Intel)

For [`dot_config/homebrew/Brewfile.darwin.tmpl:22,27,123`](dot_config/homebrew/Brewfile.darwin.tmpl) (casks that ship arm64-only: `chatgpt`, `codex-app`, `superset`), replace `ne .profile "macos_intel"` with:

```go-template
{{ if eq .chezmoi.arch "arm64" -}}
```

(The file is only consumed by `brew bundle` on macOS, so we don't need a redundant OS check here.)

For [`run_once_before_02_fix_intel_homebrew.sh.tmpl:6`](run_once_before_02_fix_intel_homebrew.sh.tmpl) (inverted guard — exits early on non-Intel-Mac):

```go-template
{{ if or (ne .chezmoi.os "darwin") (ne .chezmoi.arch "amd64") -}}
# Not Intel macOS — nothing to do
exit 0
{{ else -}}
```

For [`dot_zshrc.tmpl:42`](dot_zshrc.tmpl) (Intel-only compinit comment):

```go-template
{{ if and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64") -}}
```

## 4. New doc: `docs/tools/chezmoi-templating.md`

Sibling to [`docs/tools/chezmoi-prefixes.md`](docs/tools/chezmoi-prefixes.md). Content:

- **Decision table** for picking the right conditional knob:
  - `.profile` — user role, can't be auto-detected (server vs desktop)
  - `.chezmoi.os` — OS family ("darwin", "linux", "windows")
  - `.chezmoi.arch` — CPU arch ("arm64", "amd64", "arm")
  - `.chezmoi.hostname` — per-machine overrides
  - `env "WORK_MACHINE"` — per-session override (already used in Brewfile.darwin)
- **Anti-pattern**: introducing a new profile value for an OS/arch distinction (the reason `macos_intel` existed and was removed).
- **Before/after examples** drawn from this refactor (darwin check, arm64-only cask, Intel-Mac-only script).
- **Migration note** for existing Intel installs: `sed -i '' 's/"macos_intel"/"macos"/' ~/.config/chezmoi/chezmoi.toml && chezmoi apply`, or `chezmoi init --force`.
- Cross-link to upstream [Manage machine-to-machine differences](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/) and [Template variables](https://www.chezmoi.io/reference/templates/variables/).

## 5. Agent guidance updates

Add a "Chezmoi Templating Conventions" section to both [`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md), 4–6 lines, stating the rule and linking the new doc:

> Before adding a `{{ if eq .profile ... }}` branch, ask: is the predicate an OS/arch fact? If yes, use `.chezmoi.os` / `.chezmoi.arch`. `.profile` exists for user-role choices that can't be auto-detected (desktop vs server). See [docs/tools/chezmoi-templating.md](docs/tools/chezmoi-templating.md).

Also update the **Profiles** tables in both files (drop the `macos_intel` row; `macos` row covers both Apple Silicon and Intel).

## 6. README updates

- Profile table in [`README.md`](README.md) (if it lists `macos_intel`, drop it — grep shows none currently, just in `.specstory/` history).
- Add a short "Upgrading from `macos_intel`" callout under the existing Intel Mac section, if any.

## 7. Out of scope (do not change)

- Ansible role YAML — `.profile` isn't exposed there; ansible uses `ansible_os_family` / `ansible_architecture` already.
- `docker-compose.yml` / `Dockerfile` — already use only `ubuntu_server` / `ubuntu_desktop`; no `macos_intel` references.
- `.specstory/` history files — auto-generated transcripts, leave alone.

## Verification steps after applying

- `chezmoi execute-template '{{ .chezmoi.os }} {{ .chezmoi.arch }}'` — sanity check.
- `chezmoi apply --dry-run` on macOS (both AS and Intel if available) and in the Docker Ubuntu smoke container.
- Grep for any remaining `macos_intel` references outside `.specstory/` and history files: `rg 'macos_intel' -g '!.specstory' -g '!*.md'` must return zero.
- `just docker-test` to confirm the smoke test still passes.
