# 32_try.zsh - try-cli configuration (ephemeral workspace manager)
# https://github.com/tobi/try

# Find try.rb from the gem - the gem wrapper is broken due to __FILE__ == $0 guard
_try_script=$(ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>/dev/null)
[[ -f "$_try_script" ]] || return 0

eval "$(ruby "$_try_script" init)"
unset _try_script
