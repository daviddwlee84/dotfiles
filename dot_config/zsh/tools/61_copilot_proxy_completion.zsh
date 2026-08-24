# 61_copilot_proxy_completion.zsh - completion for the copilot-proxy function.
# Keep in sync with dot_config/bash/61_copilot_proxy_completion.bash.

(( $+functions[copilot-proxy] )) || return 0

_copilot_proxy() {
  local -a actions periods scopes
  actions=(start stop restart status doctor test logs auth reinstall shim whoami usage quota stats events bench update help)
  periods=(day week month)
  scopes=(normal benchmark all)
  if (( CURRENT == 2 )); then
    _describe 'action' actions
    return
  fi
  case "$words[2]" in
    stats|events)
      _arguments '*:option:->metric'
      case "$state" in
        metric)
          if [[ "$words[CURRENT-1]" == --scope ]]; then _describe scope scopes
          elif [[ "$words[CURRENT-1]" == --model ]]; then _message 'model id'
          elif [[ "$words[CURRENT-1]" == --limit ]]; then _message 'event limit (1..500)'
          elif [[ "$words[2]" == events ]]; then _values 'option' $periods --model --scope --limit --json
          else _values 'option' $periods --model --scope --json; fi
          ;;
      esac
      ;;
    bench) _values 'option' --model --runs --max-output --concurrency --json ;;
    quota|whoami|usage) _values 'option' --json ;;
    update) _values 'version or check' --check ;;
    shim) _values 'state' on off status ;;
    doctor|test) _values 'option' --live ;;
    logs) _values 'log' shim 20 40 60 100 ;;
  esac
}

compdef _copilot_proxy copilot-proxy
