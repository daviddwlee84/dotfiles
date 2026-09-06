#!/usr/bin/env bats

load "../test_helper.bash"

BREWFILE="$REPO_ROOT/dot_config/homebrew/Brewfile.tmpl"
BREW_SCRIPT="$REPO_ROOT/.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl"
IGNORE="$REPO_ROOT/.chezmoiignore.tmpl"
WHITELIST="$REPO_ROOT/dot_config/mole/create_whitelist"
PURGE_PATHS="$REPO_ROOT/dot_config/mole/create_purge_paths"
FRAGMENT="$REPO_ROOT/dot_config/shell/33_mole.sh"
COMPLETIONS="$REPO_ROOT/scripts/generate_completions.sh"
PROMPTS="$REPO_ROOT/scripts/init/dotfiles_init.py"

@test "mole is gated on both darwin and installMole" {
  local section
  section="$(sed -n '/^# mole — macOS cleanup/,/^{{ end -}}/p' "$BREWFILE")"

  [[ "$section" == *'hasKey . "installMole"'* ]]
  [[ "$section" == *'{{ if and (eq .chezmoi.os "darwin") $installMole -}}'* ]]
  [[ "$section" == *'brew "mole"'* ]]
}

# Regression lock: the brew-bundle run-script exits 0 early unless something
# that owns Brewfile entries is enabled. Before installMole joined that
# condition, `installMole=true` + `installBrewApps=false` silently never ran
# `brew bundle`, so the formula was declared but never installed.
@test "brew bundle run-script reaches brew when only installMole is on" {
  grep -qF '{{ $installMole := false }}{{ if hasKey . "installMole" }}{{ $installMole = .installMole }}{{ end -}}' "$BREW_SCRIPT"
  grep -qF '# installMole: {{ $installMole }}' "$BREW_SCRIPT"
  grep -qF '(and (not $installAiDesktopApps) (not $installGamingApps) (not $installMole))' "$BREW_SCRIPT"
}

@test "installMole prompt is darwin-gated and carries no equals sign" {
  local section
  section="$(sed -n '/Prompt("installMole"/,/^    Prompt("installBrewApps"/p' "$PROMPTS")"

  [[ "$section" == *'condition=When(os=frozenset({"darwin"})), else_value=False'* ]]

  # `chezmoi init --promptBool "<text>=value"` keys on the prompt text, so an
  # `=` inside it would make the Dockerfile / CI flag unparseable.
  local text
  text="$(grep -o 'prompt_text="[^"]*"' <<< "$section")"
  [[ -n "$text" ]]
  [[ "$text" != *"="*"="* ]]
}

@test "mole config seeds are gated behind darwin + installMole" {
  local section
  section="$(sed -n '/^# mole config seeds/,/{{- end }}/p' "$IGNORE")"

  [[ "$section" == *'hasKey . "installMole"'* ]]
  [[ "$section" == *'{{- if or (ne .chezmoi.os "darwin") (not $installMole) }}'* ]]
  [[ "$section" == *'.config/mole/**'* ]]
}

# Upstream treats an existing whitelist file as the COMPLETE set and drops its
# own DEFAULT_WHITELIST_PATTERNS (lib/core/base.sh:188-192). Seeding the file
# therefore silently removes every default we do not re-list here.
@test "whitelist seed re-lists the upstream defaults it would otherwise drop" {
  grep -qF '$HOME/Library/Caches/ms-playwright*' "$WHITELIST"
  grep -qF '$HOME/.gradle/caches/*' "$WHITELIST"
  grep -qF '$HOME/.gradle/daemon/*' "$WHITELIST"
  grep -qF '$HOME/.ollama/models/*' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/org.R-project.R/R/renv/*' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/JetBrains*' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/com.jetbrains.toolbox*' "$WHITELIST"
  grep -qF '$HOME/Library/Application Support/JetBrains*' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/com.nssurge.surge-mac/*' "$WHITELIST"
  grep -qF '$HOME/Library/Application Support/com.nssurge.surge-mac/*' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/tealdeer/tldr-pages' "$WHITELIST"
  grep -qF '$HOME/Library/Caches/com.apple.finder' "$WHITELIST"
  grep -qF '$HOME/Library/Mobile Documents*' "$WHITELIST"
}

@test "whitelist seed protects this repo's own bootstrap caches" {
  grep -qF '$HOME/.cache/uv/*' "$WHITELIST"
  grep -qF '$HOME/.bun/install/cache/*' "$WHITELIST"
  grep -qF '$HOME/.local/share/mise/*' "$WHITELIST"
}

@test "whitelist entries are absolute and free of traversal" {
  local line
  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    [[ "$line" == '$HOME/'* ]]
    [[ "$line" != *'..'* ]]
    [[ "$line" != *'//'* ]]
  done < "$WHITELIST"
}

# `mo purge` has no path argument; purge_paths is the only way to point it
# somewhere. Auto-discovery globs $HOME/*/ at depth 1 and probes maxdepth 2 for
# project indicators, so ~/Documents/Program is unreachable without this seed.
@test "purge_paths seed covers the checkout and worktree roots" {
  grep -qxF '~/Documents/Program' "$PURGE_PATHS"
  grep -qxF '~/Worktrees' "$PURGE_PATHS"
}

@test "the shell fragment self-gates and does not shadow mole's own mo" {
  head -n 12 "$FRAGMENT" | grep -qF 'command -v mole >/dev/null 2>&1 || return 0'

  # `mo` is upstream's own entrypoint; aliasing over it would break `mo update`
  # and the completion registration (`#compdef mole mo`).
  ! grep -qE '^(alias mo=|mo\(\))' "$FRAGMENT"

  bash -n "$FRAGMENT"
  zsh -n "$FRAGMENT"
}

@test "moclean previews before it deletes" {
  local body
  body="$(sed -n '/^moclean()/,/^}/p' "$FRAGMENT")"

  [[ "$body" == *'read -r reply'* ]]

  # The preview runs unconditionally and forwards the caller's args; the
  # destructive call exists only inside the affirmative branch.
  [[ "$body" == *'mo clean --dry-run "$@" || return $?'* ]]
  [[ "$body" == *'[yY][eE][sS]) mo clean "$@" ;;'* ]]

  # No other invocation may slip in ahead of the preview (the third hit is the
  # banner printf).
  [[ "$(grep -c 'mo clean' <<< "$body")" -eq 3 ]]
}

@test "mole completions are registered for both shells" {
  grep -qF 'regen mole "completion zsh" "completion bash"' "$COMPLETIONS"
}
