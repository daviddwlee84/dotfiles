#!/usr/bin/env bats
load "../test_helper.bash"

setup() {
  setup_path_stub
  export LAZYCLASH_PROXY_SHELL=1
  export ADAPTER_LOG="$BATS_TEST_TMPDIR/adapter.log"
  cat > "$BATS_STUB_DIR/lazyclash" <<'STUB'
#!/bin/sh
case "$1 $2" in
  'proxy shell-init')
    [ "${ADAPTER_OLD:-0}" != 1 ] || exit 2
    printf '%s\n' 'proxy-on() { printf "native-on\n"; }' 'withproxy() { "$@"; }'
    ;;
  'proxy _resolve-shell')
    printf 'resolve\n' >> "$ADAPTER_LOG"
    [ "${ADAPTER_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' "_NET_PROXY_CACHE='http://native:7897'" "_NET_PROXY_SOCKS_CACHE='socks5h://native:7897'" "_NET_PROXY_SOURCE_CACHE='lazyclash fixture'"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$BATS_STUB_DIR/lazyclash"
}

@test "native adapter preserves private detector contract without exporting env" {
  for shell in bash zsh; do
    run "$shell" -c '. "$REPO_ROOT/dot_config/shell/50_networking.sh"; unset http_proxy; __net_detect_proxy; printf "%s|%s|%s|%s\n" "$_NET_PROXY_CACHE" "$(__net_all_proxy_url)" "${http_proxy-unset}" "$(proxy-on)"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'http://native:7897|socks5h://native:7897|unset|native-on'* ]]
  done
}

@test "native resolution failure never falls back to legacy port guesses" {
  run env ADAPTER_FAIL=1 bash -c '. "$REPO_ROOT/dot_config/shell/50_networking.sh"; __net_port_open() { printf unexpected >&2; return 0; }; __net_detect_proxy; result=$?; printf "%s|%s" "$result" "$_NET_PROXY_CACHE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'1|none'* ]]
  [[ "$output" != *unexpected* ]]
}

@test "old CLI retains explicit legacy LOCAL_PROXY_URL behavior" {
  run env ADAPTER_OLD=1 LOCAL_PROXY_URL=http://manual:7890 bash -c '. "$REPO_ROOT/dot_config/shell/50_networking.sh"; __net_detect_proxy; printf "%s" "$_NET_PROXY_CACHE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'http://manual:7890'* ]]
  [ ! -e "$ADAPTER_LOG" ]
}
