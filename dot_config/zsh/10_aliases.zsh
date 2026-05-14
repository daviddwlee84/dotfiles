# 10_aliases.zsh - Zsh-only aliases / functions.
#
# POSIX-portable aliases (v=nvim, chezmoi-cd, gcam-amend, gundo, glop,
# load-nvm, bw-update-completion, ghostty-ssh-terminfo, brew-mirror,
# claude-plans-here) live in dot_config/shell/10_aliases.sh and are
# sourced by both ~/.zshrc and ~/.bashrc.
#
# Only zsh-specific helpers stay here. OMZ git-plugin shortcuts (gca,
# gcam, gca!, gcan!) are provided by the `git` plugin loaded in
# dot_zshrc.tmpl.

# Zsh startup profiling — `ZSH_PROF=1 zsh` triggers zprof at the end
# of dot_zshrc.tmpl; the alias just makes the one-shot profile run
# convenient.
alias zsh-profile='ZSH_PROF=1 zsh -i -c exit'

# --- try-cli init regen (zsh-only) -----------------------------------------
# Force-refresh the try-cli init cache used by dot_config/zsh/tools/32_try.zsh.
# The mtime check there (against `command -v ruby`) auto-invalidates after a
# mise version switch; run this manually after a gem-only upgrade
# (`gem update try-cli`) or if the cache file got corrupted. `function name`
# syntax (not POSIX `name()`) avoids alias-collision parse errors on resource —
# see pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md.
function try-update-completion {
    command -v ruby >/dev/null 2>&1 || {
        echo "try-update-completion: ruby not installed" >&2
        return 1
    }
    local _script
    _script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
    [[ -f "$_script" ]] || {
        echo "try-update-completion: try-cli gem not found" >&2
        return 1
    }
    local _cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/try_init.zsh"
    mkdir -p "${_cache:h}"
    ruby "$_script" init >"$_cache" 2>/dev/null &&
        echo "try-cli init cache updated"
}
