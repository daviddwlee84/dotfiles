# 32_try.zsh - try-cli configuration (ephemeral workspace manager)
# https://github.com/tobi/try

# Preserve user overrides, but default the graduate destination to the
# normalized parent of TRY_PATH so Ctrl-G has a predictable target.
# https://github.com/tobi/try/commit/4bb73376044e1ed8149a66513cec42155bb9f0d3
export TRY_PATH="${TRY_PATH:-$HOME/src/tries}"
export TRY_PATH="${TRY_PATH:A}"
export TRY_PROJECTS="${TRY_PROJECTS:-${TRY_PATH:h}}"

# Cached try-cli init: avoids two ruby cold starts (~67ms) on every shell
# startup. Mtime check on the ruby binary auto-invalidates after a `mise
# install ruby@<NEW>`. After a gem-only upgrade (`gem update try-cli`),
# force-refresh with `try-update-completion`. The gem wrapper itself is
# broken due to a __FILE__ == $0 guard, hence the indirect ruby try.rb call.
_try_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/try_init.zsh"
_try_ruby="$(command -v ruby 2>/dev/null)"
if [[ -n "$_try_ruby" ]] && { [[ ! -f "$_try_cache" ]] || [[ "$_try_ruby" -nt "$_try_cache" ]]; }; then
    _try_script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
    if [[ -f "$_try_script" ]]; then
        mkdir -p "${_try_cache:h}"
        ruby "$_try_script" init > "$_try_cache" 2>/dev/null
    fi
    unset _try_script
fi
[[ -s "$_try_cache" ]] || { unset _try_cache _try_ruby; return 0; }
source "$_try_cache"
unset _try_cache _try_ruby

# ── try + sesh integration ───────────────────────────────────────────────────
# Open a try project and immediately start a sesh coding session.
# Usage:
#   try-sesh some-project       # fuzzy-match or create, then sesh connect
#   try-sesh https://github.com/user/repo  # clone, then sesh connect
#
# The session name follows sesh's dir_length=2 convention:
#   e.g. "tries/2026-04-14-some-project"
function try-sesh() {
    if ! command -v sesh &>/dev/null; then
        echo "try-sesh: sesh not found" >&2
        return 1
    fi
    # Run try, which cd's into the project directory
    try "$@" || return $?
    # Now connect sesh to the directory try landed in
    sesh connect "$PWD"
}

alias tsesh='try-sesh'
