#!/usr/bin/env bats
# Unit tests for dot_config/zsh/tools/50_networking.zsh proxy helpers.
#
# Strategy: each test runs `zsh -f -c '...'` (no startup files) with the proxy
# file sourced fresh, so cache state ($_ZSH_NET_PROXY_CACHE) can't leak between
# tests. `nc` is stubbed via a temp dir prepended to PATH so probes don't touch
# the network.

load "../test_helper.bash"

PROXY_FILE="$REPO_ROOT/dot_config/zsh/tools/50_networking.zsh"

# Helper: write a fake `nc` that exits 0 only when port matches $EXPECT_PORT
# (set by the calling test via env). All other ncs fail -> simulates closed.
_make_nc_stub() {
  local dir="$1"
  cat > "$dir/nc" <<'STUB'
#!/usr/bin/env bash
# Walks args, takes last as port. matches $EXPECT_PORT.
port=""
while [ $# -gt 0 ]; do port="$1"; shift; done
[ "$port" = "${EXPECT_PORT:-__none__}" ] && exit 0 || exit 1
STUB
  chmod +x "$dir/nc"
}

@test "detect_proxy: \$LOCAL_PROXY_URL is used verbatim, no probe" {
  result="$(LOCAL_PROXY_URL=http://sentinel:9999 zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    print -r -- \"\$_ZSH_NET_PROXY_CACHE\"
  ")"
  [ "$result" = "http://sentinel:9999" ]
}

@test "detect_proxy: probes default ports and picks first responder" {
  setup_path_stub
  _make_nc_stub "$BATS_STUB_DIR"

  # Pick 1087 — third in the probe order (7890, 7891, 1087, 8118, 8080).
  # If probe order regressed or skipped a port, this would return a different URL.
  result="$(EXPECT_PORT=1087 zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    print -r -- \"\$_ZSH_NET_PROXY_CACHE\"
  ")"
  [ "$result" = "http://127.0.0.1:1087" ]
}

@test "detect_proxy: prefers Clash mixed-port over generic probe order" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
port=""
while [ $# -gt 0 ]; do port="$1"; shift; done
case "$port" in
  7890|7891) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.config/clash"
  cat > "$home/.config/clash/config.yaml" <<'EOF'
mixed-port: 7891
EOF

  result="$(HOME="$home" zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    printf 'http=%s\nall=%s\nsource=%s\n' \"\$_ZSH_NET_PROXY_CACHE\" \"\$(__zsh_net_all_proxy_url)\" \"\$_ZSH_NET_PROXY_SOURCE_CACHE\"
  ")"
  [[ "$result" == *"http=http://127.0.0.1:7891"* ]]
  [[ "$result" == *"all=socks5://127.0.0.1:7891"* ]]
  [[ "$result" == *"source=clash config"* ]]
}

@test "detect_proxy: uses Clash split HTTP and SOCKS ports" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
port=""
while [ $# -gt 0 ]; do port="$1"; shift; done
case "$port" in
  7890|7891) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.config/clash"
  cat > "$home/.config/clash/config.yaml" <<'EOF'
port: 7890
socks-port: 7891
EOF

  result="$(HOME="$home" zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    printf 'http=%s\nall=%s\n' \"\$_ZSH_NET_PROXY_CACHE\" \"\$(__zsh_net_all_proxy_url)\"
  ")"
  [[ "$result" == *"http=http://127.0.0.1:7890"* ]]
  [[ "$result" == *"all=socks5://127.0.0.1:7891"* ]]
}

@test "detect_proxy: no responder sets cache=none and returns non-zero" {
  setup_path_stub
  # nc that always fails
  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  run zsh -f -c "
    source '$PROXY_FILE'
    if __zsh_net_detect_proxy; then rc=0; else rc=\$?; fi
    print -r -- \"cache=\$_ZSH_NET_PROXY_CACHE rc=\$rc\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache=none"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "all_proxy_url: prefers LOCAL_PROXY_SOCKS_URL, falls back to cache" {
  # With SOCKS url set → returns SOCKS url.
  result="$(LOCAL_PROXY_URL=http://a:1 LOCAL_PROXY_SOCKS_URL=socks5://b:2 zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    __zsh_net_all_proxy_url
  ")"
  [ "$result" = "socks5://b:2" ]

  # Without SOCKS url → falls back to HTTP cache.
  result="$(LOCAL_PROXY_URL=http://a:1 zsh -f -c "
    source '$PROXY_FILE'
    __zsh_net_detect_proxy
    __zsh_net_all_proxy_url
  ")"
  [ "$result" = "http://a:1" ]
}

@test "proxy-on: exports all six proxy env vars" {
  output="$(LOCAL_PROXY_URL=http://test:1234 zsh -f -c "
    source '$PROXY_FILE'
    proxy-on -q
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
      printf '%s=%s\n' \"\$v\" \"\${(P)v}\"
    done
  ")"
  [[ "$output" == *"http_proxy=http://test:1234"* ]]
  [[ "$output" == *"https_proxy=http://test:1234"* ]]
  [[ "$output" == *"HTTP_PROXY=http://test:1234"* ]]
  [[ "$output" == *"HTTPS_PROXY=http://test:1234"* ]]
  [[ "$output" == *"ALL_PROXY=http://test:1234"* ]]
  [[ "$output" == *"all_proxy=http://test:1234"* ]]
}

@test "proxy-on: split HTTP/SOCKS wires http= and all= independently (fa4c063 guard)" {
  output="$(LOCAL_PROXY_URL=http://h:1 LOCAL_PROXY_SOCKS_URL=socks5://s:2 zsh -f -c "
    source '$PROXY_FILE'
    proxy-on -q
    printf 'http=%s\nhttps=%s\nall=%s\n' \"\$http_proxy\" \"\$https_proxy\" \"\$ALL_PROXY\"
  ")"
  [[ "$output" == *"http=http://h:1"* ]]
  [[ "$output" == *"https=http://h:1"* ]]
  [[ "$output" == *"all=socks5://s:2"* ]]
}

@test "proxy-off: clears proxy env vars and cached detection state" {
  output="$(LOCAL_PROXY_URL=http://x:1 zsh -f -c "
    source '$PROXY_FILE'
    proxy-on -q
    export NO_PROXY=localhost no_proxy=localhost
    proxy-off > /dev/null
    for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy; do
      if [[ -n \"\${(P)v}\" ]]; then printf '%s=still-set\n' \"\$v\"; fi
    done
    if [[ -n \"\$_ZSH_NET_PROXY_CACHE\$_ZSH_NET_PROXY_SOCKS_CACHE\$_ZSH_NET_PROXY_SOURCE_CACHE\" ]]; then
      print cache=still-set
    fi
  ")"
  [ -z "$output" ]
}

@test "proxy-status: returns 1 when unavailable, 0 when available" {
  setup_path_stub
  # nc always fails → no proxy detected
  cat > "$BATS_STUB_DIR/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$BATS_STUB_DIR/nc"

  run zsh -f -c "
    source '$PROXY_FILE'
    proxy-status > /dev/null 2>&1
  "
  [ "$status" -eq 1 ]

  run env LOCAL_PROXY_URL=http://ok:1 zsh -f -c "
    source '$PROXY_FILE'
    proxy-status > /dev/null 2>&1
  "
  [ "$status" -eq 0 ]
}
