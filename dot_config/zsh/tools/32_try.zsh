# 32_try.zsh - try-cli configuration (ephemeral workspace manager)
# https://github.com/tobi/try

# Preserve user overrides, but default the graduate destination to the
# normalized parent of TRY_PATH so Ctrl-G has a predictable target.
# https://github.com/tobi/try/commit/4bb73376044e1ed8149a66513cec42155bb9f0d3
export TRY_PATH="${TRY_PATH:-$HOME/src/tries}"
export TRY_PATH="${TRY_PATH:A}"
export TRY_PROJECTS="${TRY_PROJECTS:-${TRY_PATH:h}}"

# Find try.rb from the gem - the gem wrapper is broken due to __FILE__ == $0 guard
_try_script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
[[ -f "$_try_script" ]] || return 0

eval "$(ruby "$_try_script" init)"
unset _try_script
