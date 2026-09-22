#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_path_stub
  export LAZYCLASH_PROXY_SHELL=1 LOCAL_PROXY_AUTO_ACTIVATE=0
  export CONSUMER_LOG="$BATS_TEST_TMPDIR/consumer.log"
  export CONSUMER_SIDE_EFFECT="$BATS_TEST_TMPDIR/side-effect"
  unset LAZYCLASH_PROXY_ORIGIN LAZYCLASH_PROXY_SESSION
  cat > "$BATS_STUB_DIR/lazyclash" <<'STUB'
#!/bin/sh
case "$1 $2" in
  'proxy shell-init') printf '%s\n' ':'; exit 0 ;;
  'proxy _resolve-shell')
    case "$*" in *--help*) [ "${CONSUMER_OLD:-0}" != 1 ] || exit 2; printf '%s\n' '--consumer string'; exit 0 ;; esac
    printf '%s\n' "$*" >> "$CONSUMER_LOG"
    if [ "${CONSUMER_BAD_SETTINGS:-0}" = 1 ]; then
      case "$*" in *'--config /dev/null'*) ;; *) printf 'incompatible target settings\n' >&2; exit 2 ;; esac
    fi
    endpoint='http://stable:7890'
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --endpoint ]; then endpoint="$2"; shift 2; else shift; fi
    done
    case "$endpoint" in *:43210*) printf 'temporary proxy endpoint rejected\n' >&2; exit 1 ;; esac
    [ "${CONSUMER_RC:-0}" = 0 ] || { printf 'fixture resolver error\n' >&2; exit "$CONSUMER_RC"; }
    printf "_NET_PROXY_CACHE='%s'\n_NET_PROXY_SOCKS_CACHE='%s'\n_NET_PROXY_SOURCE_CACHE='fixture'\n" "$endpoint" "$endpoint"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$BATS_STUB_DIR/lazyclash"
}

run_consumer() {
  local shell="$1" code="$2"
  run "$shell" -c '. "$REPO_ROOT/dot_config/shell/43_copilot_proxy.sh"; . "$REPO_ROOT/dot_config/shell/50_networking.sh"; . "$REPO_ROOT/dot_config/shell/51_docker_net.sh"; eval "$1"' fixture "$code"
}

@test "consumer bridge rejects copied temporary URL before Copilot start/restart side effects" {
  for shell in bash zsh; do
    run_consumer "$shell" 'bun() { :; }; _copilot_pkg() { printf fixture; }; _copilot_alive() { touch "$CONSUMER_SIDE_EFFECT"; return 1; }; _copilot_ensure_pkg() { touch "$CONSUMER_SIDE_EFFECT"; }; COPILOT_HTTP_PROXY=http://127.0.0.1:43210 copilot-proxy start'
    [ "$status" -eq 1 ]
    [[ "$output" == *'temporary proxy endpoint rejected'* ]]
    [ ! -e "$CONSUMER_SIDE_EFFECT" ]
    run_consumer "$shell" 'bun() { :; }; _copilot_pkg() { printf fixture; }; _copilot_shim_stop() { touch "$CONSUMER_SIDE_EFFECT"; }; COPILOT_HTTP_PROXY=http://127.0.0.1:43210 copilot-proxy restart'
    [ "$status" -eq 1 ]
    [ ! -e "$CONSUMER_SIDE_EFFECT" ]
  done
  grep -q -- '--consumer service --endpoint http://127.0.0.1:43210' "$CONSUMER_LOG"
}

@test "consumer bridge rejects Docker URL before daemon inspection or edits" {
  for shell in bash zsh; do
    run_consumer "$shell" '_dnet_info_load() { touch "$CONSUMER_SIDE_EFFECT"; }; _dnet_edit_daemon_json() { touch "$CONSUMER_SIDE_EFFECT"; }; docker-net on http://127.0.0.1:43210 -y'
    [ "$status" -eq 1 ]
    [[ "$output" == *'temporary proxy endpoint rejected'* ]]
    [ ! -e "$CONSUMER_SIDE_EFFECT" ]
  done
}

@test "Copilot auto permits only typed no-proxy; always and resolver failures fail" {
  for shell in bash zsh; do
    export CONSUMER_RC=4
    run_consumer "$shell" 'value=$(_copilot_resolve_http_proxy service); rc=$?; printf "value=<%s> rc=%s\n" "$value" "$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'value=<> rc=0'* ]]
    run_consumer "$shell" 'COPILOT_HTTP_PROXY=always _copilot_resolve_http_proxy service'
    [ "$status" -eq 4 ]
    export CONSUMER_RC=1
    run_consumer "$shell" '_copilot_system_proxy() { touch "$CONSUMER_SIDE_EFFECT"; printf guessed:7890; }; _copilot_resolve_http_proxy service'
    [ "$status" -eq 1 ]
    [ ! -e "$CONSUMER_SIDE_EFFECT" ]
  done
}

@test "never opts out while an explicit stable override is checked and accepted" {
  for shell in bash zsh; do
    run_consumer "$shell" 'LAZYCLASH_PROXY_ORIGIN=fixture COPILOT_HTTP_PROXY=never _copilot_resolve_http_proxy service'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run_consumer "$shell" 'LAZYCLASH_PROXY_ORIGIN=fixture COPILOT_HTTP_PROXY=http://stable:7890 _copilot_resolve_http_proxy service'
    [ "$status" -eq 0 ]
    [ "$output" = http://stable:7890 ]
  done
}

@test "standalone service modules guard explicit copied endpoints without shared adapter" {
  for shell in bash zsh; do
    run "$shell" -c '. "$REPO_ROOT/dot_config/shell/43_copilot_proxy.sh"; COPILOT_HTTP_PROXY=http://127.0.0.1:43210 _copilot_resolve_http_proxy service'
    [ "$status" -eq 1 ]
    run "$shell" -c '. "$REPO_ROOT/dot_config/shell/51_docker_net.sh"; _dnet_resolve_proxy http://127.0.0.1:43210 service'
    [ "$status" -eq 1 ]
  done
}

@test "explicit Copilot endpoint ignores incompatible target settings but retains lifetime guard" {
  export CONSUMER_BAD_SETTINGS=1
  for shell in bash zsh; do
    run_consumer "$shell" 'COPILOT_HTTP_PROXY=http://stable:7890 _copilot_resolve_http_proxy service'
    [ "$status" -eq 0 ]
    [ "$output" = http://stable:7890 ]
    run_consumer "$shell" 'COPILOT_HTTP_PROXY=http://127.0.0.1:43210 _copilot_resolve_http_proxy service'
    [ "$status" -eq 1 ]
    [[ "$output" == *'temporary proxy endpoint rejected'* ]]
    run "$shell" -c '. "$REPO_ROOT/dot_config/shell/43_copilot_proxy.sh"; COPILOT_HTTP_PROXY=http://stable:7890 _copilot_resolve_http_proxy service'
    [ "$status" -eq 0 ]
    [ "$output" = http://stable:7890 ]
    run_consumer "$shell" 'COPILOT_HTTP_PROXY=auto _copilot_resolve_http_proxy service'
    [ "$status" -eq 2 ]
    [[ "$output" == *'incompatible target settings'* ]]
  done
}

@test "old CLI compatibility keeps stable endpoints without bypassing origin metadata" {
  export CONSUMER_OLD=1
  for shell in bash zsh; do
    run_consumer "$shell" 'COPILOT_HTTP_PROXY=http://stable:7890 _copilot_resolve_http_proxy service'
    [ "$status" -eq 0 ]
    [ "$output" = http://stable:7890 ]
    run_consumer "$shell" 'LAZYCLASH_PROXY_ORIGIN=fixture COPILOT_HTTP_PROXY=http://stable:7890 _copilot_resolve_http_proxy service'
    [ "$status" -eq 1 ]
  done
}

@test "native process resolver failure does not fall through to macOS system proxy" {
  export CONSUMER_RC=1
  run_consumer bash '_copilot_system_proxy() { touch "$CONSUMER_SIDE_EFFECT"; printf guessed:7890; }; _copilot_resolve_http_proxy'
  [ "$status" -eq 1 ]
  [ ! -e "$CONSUMER_SIDE_EFFECT" ]
}

@test "Copilot original and fork backends receive one stable proxy or a clean direct environment" {
  local fixture_home="$BATS_TEST_TMPDIR/child-home"
  mkdir -p "$fixture_home/.local/share/copilot-api"
  printf fixture-token > "$fixture_home/.local/share/copilot-api/github_token"
  cat > "$BATS_STUB_DIR/fixture-backend" <<'STUB'
#!/bin/sh
printf '%s\n' "${http_proxy-unset}" "${https_proxy-unset}" "${HTTP_PROXY-unset}" "${HTTPS_PROXY-unset}" "${all_proxy-unset}" "${ALL_PROXY-unset}" "${LAZYCLASH_PROXY_ORIGIN-unset}" "${LAZYCLASH_PROXY_SESSION-unset}" > "$CONSUMER_CAPTURE"
: > "$CONSUMER_CAPTURE.ready"
STUB
  chmod +x "$BATS_STUB_DIR/fixture-backend"
  for shell in bash zsh; do
    for flavor in original fork; do
      for mode in http://stable:7890 never; do
        export CONSUMER_CAPTURE="$BATS_TEST_TMPDIR/capture-$shell-$flavor-${mode##*/}"
        run env HOME="$fixture_home" FIXTURE_FLAVOR="$flavor" COPILOT_HTTP_PROXY="$mode" \
          http_proxy=http://temporary:43210 https_proxy=http://temporary:43210 \
          HTTP_PROXY=http://temporary:43210 HTTPS_PROXY=http://temporary:43210 \
          all_proxy=socks5h://temporary:43211 ALL_PROXY=socks5h://temporary:43211 \
          LAZYCLASH_PROXY_ORIGIN=temporary-marker LAZYCLASH_PROXY_SESSION=temporary-session \
          "$shell" -c '
            . "$REPO_ROOT/dot_config/shell/43_copilot_proxy.sh"
            . "$REPO_ROOT/dot_config/shell/50_networking.sh"
            bun() { :; }
            _copilot_pkg() { printf fixture; }
            _copilot_pkg_flavor() { printf "%s" "$FIXTURE_FLAVOR"; }
            _copilot_pkg_bin() { printf "%s/fixture-backend" "$BATS_STUB_DIR"; }
            _copilot_ensure_pkg() { :; }
            _copilot_alive() { [ -f "$CONSUMER_CAPTURE.ready" ]; }
            _copilot_shim_enabled() { return 1; }
            _copilot_logfile() { printf "%s.log" "$CONSUMER_CAPTURE"; }
            _copilot_pidfile() { printf "%s.pid" "$CONSUMER_CAPTURE"; }
            copilot-proxy start
          '
        [ "$status" -eq 0 ]
        local expected=unset
        [ "$mode" = never ] || expected=http://stable:7890
        [ "$(sed -n '1,6p' "$CONSUMER_CAPTURE" | sort -u)" = "$expected" ]
        [ "$(sed -n '7,8p' "$CONSUMER_CAPTURE" | sort -u)" = unset ]
      done
    done
  done
}
