#!/usr/bin/env bash
# Regenerate shell completion files for upstream CLIs.
#
# Usage:
#   scripts/generate_completions.sh [--force] [--quiet] [--help]
#
# Modes:
#   default   Skip tools whose completion file is already newer than its
#             freshness source (normally the binary; repo CLIs may use a Git
#             revision stamp such as .git/index).
#   --force   Regenerate every tool's completion regardless of mtime.
#   --quiet   Suppress per-tool progress; still print final summary.
#
# Output paths (lazy-autoload conventions):
#   zsh:  ~/.zfunc/_<tool>                                              (in fpath via dot_zshrc.tmpl:68)
#   bash: ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/<tool>
#         (auto-loaded on first TAB by bash-completion v2)
#
# Tools NOT handled here (covered elsewhere — don't double-up):
#   sesh, tv, worktrunk        → shell-startup mtime check (dot_config/zsh/tools/{22_sesh,12_television,37_worktrunk}.zsh)
#   bw                         → cached eval at startup    (dot_config/zsh/tools/95_bitwarden.zsh)
#   marimo, thefuck, try-cli   → cached eval at startup    (dot_config/shell/{29_marimo,27_thefuck}.sh + dot_config/zsh/tools/32_try.zsh)
#   mi-router                  → tyro self-gen at startup  (dot_config/shell/47_mi_router.sh)
#   fleet, mlf, pqsum, x       → hand-written eager-load   (dot_config/{zsh/tools,bash}/45-49_*_completion.*)
#
# Invoked from:
#   - .chezmoiscripts/global/run_after_50_generate_completions.sh.tmpl   (every chezmoi apply, no --force)
#   - `just completions-refresh`                                          (manual, --force)
#
# Skip from chezmoi apply: export CHEZMOI_SKIP_COMPLETION_GEN=1
# Full design: docs/zsh/zsh-completions.md "How autocomplete works" + Section A.

set -euo pipefail

force=0
quiet=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --quiet) quiet=1 ;;
    -h | --help)
      sed -n '2,30p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "generate_completions: unknown arg: $a" >&2
      exit 2
      ;;
  esac
done

ZFUNC="${HOME}/.zfunc"
BASHDIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"

mkdir -p "$ZFUNC" "$BASHDIR"

n_z_regen=0
n_b_regen=0
n_z_skip=0
n_b_skip=0
n_missing=0

# regen <tool> <zsh-args> <bash-args> [runner-path] [freshness-path]
# Uses word-splitting on $zargs / $bargs deliberately (the upstream completion
# subcommands are 1-3 words, no quoting needed). runner-path pins a canonical
# executable instead of PATH resolution; freshness-path handles repo-backed
# launchers whose wrapper mtime does not change when their source revision does.
regen() {
  local tool="$1" zargs="$2" bargs="$3"
  local runner_path="${4:-}" freshness_path="${5:-}"
  local bin runner freshness
  if [ -n "$runner_path" ]; then
    if [ ! -x "$runner_path" ]; then
      n_missing=$((n_missing + 1))
      return 0
    fi
    bin="$runner_path"
    runner="$runner_path"
  elif ! bin="$(command -v "$tool" 2>/dev/null)"; then
    # Fresh `chezmoi init --apply` may install a user-level binary before the
    # parent process has reloaded ~/.local/bin into PATH. Resolve that canonical
    # install location explicitly so first-apply completion generation works.
    if [ -x "$HOME/.local/bin/$tool" ]; then
      bin="$HOME/.local/bin/$tool"
      runner="$bin"
    else
      n_missing=$((n_missing + 1))
      return 0
    fi
  else
    # Preserve the short argv[0] for generators that bake it into output.
    runner="$tool"
  fi
  freshness="${freshness_path:-$bin}"
  [ -e "$freshness" ] || freshness="$bin"
  local zfile="${ZFUNC}/_${tool}"
  local bfile="${BASHDIR}/${tool}"

  # zsh
  if [ "$force" = 1 ] || [ ! -f "$zfile" ] || [ "$freshness" -nt "$zfile" ]; then
    # shellcheck disable=SC2086  # word-split intentional
    if "$runner" $zargs >"$zfile.tmp" 2>/dev/null && [ -s "$zfile.tmp" ]; then
      mv "$zfile.tmp" "$zfile"
      n_z_regen=$((n_z_regen + 1))
      [ "$quiet" = 0 ] && printf '  zsh   %-10s → %s\n' "$tool" "$zfile"
    else
      rm -f "$zfile.tmp"
    fi
  else
    n_z_skip=$((n_z_skip + 1))
  fi

  # bash
  if [ "$force" = 1 ] || [ ! -f "$bfile" ] || [ "$freshness" -nt "$bfile" ]; then
    # shellcheck disable=SC2086
    if "$runner" $bargs >"$bfile.tmp" 2>/dev/null && [ -s "$bfile.tmp" ]; then
      mv "$bfile.tmp" "$bfile"
      n_b_regen=$((n_b_regen + 1))
      [ "$quiet" = 0 ] && printf '  bash  %-10s → %s\n' "$tool" "$bfile"
    else
      rm -f "$bfile.tmp"
    fi
  else
    n_b_skip=$((n_b_skip + 1))
  fi

  # `set -e` + `[ test ] && cmd` at function tail is a bash footgun: when
  # `--quiet` makes the test fail, the &&-short-circuit returns 1, the inner
  # `if`-`then` body returns 1, regen() returns 1, and set -e aborts.
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Inventory: tool, zsh-args (after `<tool>`), bash-args (after `<tool>`)
# Add a new row when you add a new upstream CLI to the ansible / brew install
# set AND it self-generates completion (most modern CLIs do — check `<tool>
# completion --help` or `<tool> --help | grep -i complet`).
# ──────────────────────────────────────────────────────────────────────────────
regen chezmoi "completion zsh" "completion bash"
regen mise "completion zsh" "completion bash"
regen uv "generate-shell-completion zsh" "generate-shell-completion bash"
regen just "--completions zsh" "--completions bash"
regen starship "completions zsh" "completions bash"
regen gh "completion -s zsh" "completion -s bash"
regen docker "completion zsh" "completion bash"
regen rg "--generate complete-zsh" "--generate complete-bash"
regen fd "--gen-completions zsh" "--gen-completions bash"
regen bat "--completion zsh" "--completion bash"
regen delta "--generate-completion zsh" "--generate-completion bash"
regen zellij "setup --generate-completion zsh" "setup --generate-completion bash"
regen pueue "completions zsh" "completions bash"
regen opencode "completion zsh" "completion bash"
regen omp "completions zsh" "completions bash"
regen pia "completion zsh" "completion bash" "$HOME/.local/share/pi-agents/bin/pia" "$HOME/.local/share/pi-agents/.git/index"
regen translate "completion zsh" "completion bash"
regen dev "completion zsh" "completion bash"
regen summarize "completion zsh" "completion bash"

if [ "$n_z_regen" -gt 0 ] || [ "$n_b_regen" -gt 0 ] || [ "$quiet" = 0 ]; then
  printf 'completions: regenerated %d zsh + %d bash | skipped %d zsh + %d bash | %d not installed\n' \
    "$n_z_regen" "$n_b_regen" "$n_z_skip" "$n_b_skip" "$n_missing"
fi
