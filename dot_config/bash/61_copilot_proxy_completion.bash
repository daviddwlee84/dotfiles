# 61_copilot_proxy_completion.bash - completion for the copilot-proxy function.
# Keep in sync with dot_config/zsh/tools/61_copilot_proxy_completion.zsh.

type copilot-proxy >/dev/null 2>&1 || return 0

# Bash 3 compatibility: mapfile is unavailable on stock macOS Bash.
# shellcheck disable=SC2207
_copilot_proxy_completion() {
  local cur prev words cword
  _init_completion || return
  local actions='start stop restart status doctor test logs auth reinstall shim limiter whoami usage quota stats events bench update help'
  if [ "$cword" -eq 1 ]; then COMPREPLY=( $(compgen -W "$actions" -- "$cur") ); return; fi
  case "${words[1]}" in
    stats|events)
      case "$prev" in
        --scope) COMPREPLY=( $(compgen -W 'normal benchmark all' -- "$cur") ) ;;
        *)
          if [ "${words[1]}" = events ]; then
            COMPREPLY=( $(compgen -W 'day week month --model --scope --limit --json' -- "$cur") )
          else
            COMPREPLY=( $(compgen -W 'day week month --model --scope --json' -- "$cur") )
          fi ;;
      esac ;;
    bench) COMPREPLY=( $(compgen -W '--model --runs --max-output --concurrency --json' -- "$cur") ) ;;
    quota|whoami|usage) COMPREPLY=( $(compgen -W '--json' -- "$cur") ) ;;
    update) COMPREPLY=( $(compgen -W '--check' -- "$cur") ) ;;
    shim) COMPREPLY=( $(compgen -W 'on off status' -- "$cur") ) ;;
    limiter)
      if [ "$cword" -eq 2 ]; then
        COMPREPLY=( $(compgen -W 'status set reset' -- "$cur") )
      elif [ "${words[2]}" = set ]; then
        COMPREPLY=( $(compgen -W '--min --max --limit' -- "$cur") )
      fi ;;
    doctor|test) COMPREPLY=( $(compgen -W '--live' -- "$cur") ) ;;
    logs) COMPREPLY=( $(compgen -W 'shim -f --follow 20 40 60 100' -- "$cur") ) ;;
  esac
}

complete -F _copilot_proxy_completion copilot-proxy
