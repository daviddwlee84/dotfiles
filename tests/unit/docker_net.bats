#!/usr/bin/env bats
# Unit tests for dot_config/shell/51_docker_net.sh.
#
# Strategy mirrors zsh_proxy.bats: every test sources the file fresh inside an
# explicit `zsh -f -c` / `bash --norc -c`, so no cache or global leaks between
# tests, and `docker` / `curl` are stubbed via $BATS_STUB_DIR so nothing touches
# a daemon or the network.
#
# Several tests deliberately run in BOTH shells. This file is sourced by zsh and
# bash alike, and the two disagree about word splitting: zsh does not split
# unquoted parameter expansions, so a `set -- $raw` parser that works in bash
# silently collapses to one field in zsh. Testing one shell would not catch it.

load "../test_helper.bash"

DNET_FILE="$REPO_ROOT/dot_config/shell/51_docker_net.sh"

# Run a snippet with 51_docker_net.sh sourced, in the named shell.
_dnet_run() {
  local shell="$1" snippet="$2"
  case "$shell" in
    zsh) zsh -f -c "source '$DNET_FILE'; $snippet" ;;
    bash) bash --norc -c "source '$DNET_FILE'; $snippet" ;;
  esac
}

# A `docker` stub whose `info --format` prints one canned pipe-delimited record.
_make_docker_info_stub() {
  local dir="$1" record="$2"
  cat > "$dir/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "info" ]; then printf '%s' '$record'; exit 0; fi
exit 0
STUB
  chmod +x "$dir/docker"
}

# --- image reference parsing -------------------------------------------------

@test "ref_split: bare name is Docker Hub" {
  result="$(_dnet_run bash '_dnet_ref_split nginx')"
  [ "$result" = "|nginx" ]
}

@test "ref_split: user/repo is Docker Hub, not a registry" {
  # `bitnami` has no dot/colon, so it is a namespace — not a registry host.
  result="$(_dnet_run bash '_dnet_ref_split bitnami/redis:7')"
  [ "$result" = "|bitnami/redis:7" ]
}

@test "ref_split: a first component with a dot is a registry" {
  result="$(_dnet_run bash '_dnet_ref_split ghcr.io/foo/bar:v1')"
  [ "$result" = "ghcr.io|foo/bar:v1" ]
}

@test "ref_split: localhost and host:port count as registries" {
  result="$(_dnet_run bash '_dnet_ref_split localhost/foo:1')"
  [ "$result" = "localhost|foo:1" ]
  result="$(_dnet_run bash '_dnet_ref_split myhost:5000/foo:1')"
  [ "$result" = "myhost:5000|foo:1" ]
}

@test "hub_path: single-segment names get the implicit library/ made explicit" {
  # Without this a mirror 404s on official images.
  result="$(_dnet_run bash '_dnet_hub_path nginx:1.2')"
  [ "$result" = "library/nginx:1.2" ]
  result="$(_dnet_run bash '_dnet_hub_path bitnami/redis:7')"
  [ "$result" = "bitnami/redis:7" ]
}

@test "host_of: strips scheme and path" {
  result="$(_dnet_run bash '_dnet_host_of https://docker.m.daocloud.io/')"
  [ "$result" = "docker.m.daocloud.io" ]
}

# --- proxy resolution --------------------------------------------------------

@test "resolve_proxy: an explicit URL is used verbatim" {
  result="$(_dnet_run bash '_dnet_resolve_proxy http://sentinel:9999')"
  [ "$result" = "http://sentinel:9999" ]
}

@test "resolve_proxy: never/off opts out with empty output" {
  result="$(_dnet_run bash '_dnet_resolve_proxy never')"
  [ -z "$result" ]
  result="$(_dnet_run bash '_dnet_resolve_proxy off')"
  [ -z "$result" ]
}

@test "resolve_proxy: socks:// is rejected, socks5:// is accepted" {
  # `socks://` is not a scheme Go's proxy parser or curl understands. A daemon
  # configured with it looks configured and connects to nothing.
  run bash --norc -c "source '$DNET_FILE'; _dnet_resolve_proxy socks://127.0.0.1:7890"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid proxy scheme"* ]]

  result="$(_dnet_run bash '_dnet_resolve_proxy socks5://127.0.0.1:7891')"
  [ "$result" = "socks5://127.0.0.1:7891" ]
}

@test "resolve_proxy: an unknown mode fails loudly rather than silently going direct" {
  run bash --norc -c "source '$DNET_FILE'; _dnet_resolve_proxy wat"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown proxy mode"* ]]
}

@test "resolve_proxy: DOCKER_NET_PROXY env is honoured when no argument is given" {
  result="$(DOCKER_NET_PROXY=http://from-env:1 _dnet_run bash '_dnet_resolve_proxy')"
  [ "$result" = "http://from-env:1" ]
}

# --- probe result classification ---------------------------------------------

@test "classify: 200/401 are healthy, 401 is not a failure" {
  # An unauthenticated 401 from /v2/ means the registry answered.
  result="$(_dnet_run bash '_dnet_classify 401 ""')"
  [ "${result%%|*}" = "ok" ]
  result="$(_dnet_run bash '_dnet_classify 200 ""')"
  [ "${result%%|*}" = "ok" ]
}

@test "classify: 403 is a warning (reachable), 5xx is a failure" {
  result="$(_dnet_run bash '_dnet_classify 403 ""')"
  [ "${result%%|*}" = "warn" ]
  result="$(_dnet_run bash '_dnet_classify 502 ""')"
  [ "${result%%|*}" = "bad" ]
}

@test "classify: connect failures are told apart by their curl message" {
  # These three all surface as HTTP 000 but mean very different things, and the
  # whole point of the mirrors section is telling them apart.
  result="$(_dnet_run bash '_dnet_classify 000 "curl: (6) Could not resolve host: x"')"
  [[ "$result" == "bad|domain has no DNS record" ]]

  result="$(_dnet_run bash '_dnet_classify 000 "curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to x:443"')"
  [[ "$result" == *"TLS reset"* ]]

  result="$(_dnet_run bash '_dnet_classify 000 "curl: (28) Operation timed out"')"
  [[ "$result" == *"blackholed"* ]]
}

# --- docker info parsing (the zsh/bash word-splitting regression) ------------

@test "info_load: parses all six fields in zsh" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|http://p:1|https://p:2|localhost|name=rootless,|https://m1/,https://m2/,|Ubuntu 24.04.3 LTS'
  result="$(_dnet_run zsh '_dnet_info_load; printf "%s^%s^%s^%s" "$_DNET_SRV" "$_DNET_HTTPS" "$_DNET_SECOPTS" "$_DNET_MIRRORS_RAW"')"
  [ "$result" = '29.6.2^https://p:2^name=rootless,^https://m1/,https://m2/,' ]
}

@test "info_load: parses all six fields in bash" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|http://p:1|https://p:2|localhost|name=rootless,|https://m1/,https://m2/,|Ubuntu 24.04.3 LTS'
  result="$(_dnet_run bash '_dnet_info_load; printf "%s^%s^%s^%s" "$_DNET_SRV" "$_DNET_HTTPS" "$_DNET_SECOPTS" "$_DNET_MIRRORS_RAW"')"
  [ "$result" = '29.6.2^https://p:2^name=rootless,^https://m1/,https://m2/,' ]
}

@test "info_load: an empty proxy field stays empty without eating the next field" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||name=rootless,|https://m1/,|Ubuntu 24.04.3 LTS'
  result="$(_dnet_run zsh '_dnet_info_load; printf "[%s][%s][%s]" "$_DNET_SRV" "$_DNET_HTTPS" "$_DNET_MIRRORS_RAW"')"
  [ "$result" = '[29.6.2][][https://m1/,]' ]
}

@test "shape: SecurityOptions containing name=rootless wins" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||name=seccomp,name=rootless,||Ubuntu 24.04.3 LTS'
  result="$(_dnet_run bash '_dnet_info_load; _dnet_shape')"
  [ "$result" = "rootless" ]
}

# --- mirrors -----------------------------------------------------------------

@test "mirrors: splits on comma and strips the trailing slash" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|||||https://a.example/,https://b.example/,|Ubuntu 24.04.3 LTS'
  result="$(_dnet_run zsh '_dnet_info_load; _dnet_mirrors | tr "\n" " "')"
  [ "$result" = "https://a.example https://b.example " ]
}

@test "mirrors: DOCKER_NET_MIRRORS overrides the live daemon" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|||||https://ignored/,|Ubuntu 24.04.3 LTS'
  result="$(DOCKER_NET_MIRRORS='https://x.example,https://y.example/' _dnet_run bash '_dnet_info_load; _dnet_mirrors | tr "\n" " "')"
  # Trailing space proves the last entry is newline-TERMINATED, not merely
  # separated — a `while read` consumer drops an unterminated final line.
  # The trailing slash on y.example proves the override branch normalises too.
  [ "$result" = "https://x.example https://y.example " ]
}

@test "no_proxy: every configured mirror host is exempted from the proxy" {
  # A CN mirror routed back out through the proxy is slower and often broken.
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|||||https://docker.m.daocloud.io/,|Ubuntu 24.04.3 LTS'
  result="$(_dnet_run zsh '_dnet_info_load; _dnet_no_proxy_value')"
  [[ "$result" == *"docker.m.daocloud.io"* ]]
  [[ "$result" == *"127.0.0.1"* ]]
  [[ "$result" == *"192.168.0.0/16"* ]]
}

@test "no_proxy: DOCKER_NET_NO_PROXY entries are appended" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2|||||||Ubuntu 24.04.3 LTS'
  result="$(DOCKER_NET_NO_PROXY='corp.internal' _dnet_run bash '_dnet_info_load; _dnet_no_proxy_value')"
  [[ "$result" == *"corp.internal"* ]]
}

# --- pull ladder -------------------------------------------------------------

@test "pull: rung 2 is skipped for non-Hub refs, with the reason stated" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then printf '%s' '29.6.2|||||https://docker.m.daocloud.io/,'; exit 0; fi
if [ "$1" = "pull" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$BATS_STUB_DIR/docker"

  run bash --norc -c "source '$DNET_FILE'; _dnet_pull ghcr.io/foo/bar:v1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rung 1"* ]]
  [[ "$output" == *"registry-mirrors only covers Docker Hub, not ghcr.io"* ]]
  [[ "$output" == *"rung 3: skipped — skopeo not installed"* ]]
}

@test "pull: rung 2 addresses the mirror explicitly with library/ inserted" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then printf '%s' '29.6.2|||||https://docker.m.daocloud.io/,'; exit 0; fi
if [ "$1" = "pull" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$BATS_STUB_DIR/docker"

  run bash --norc -c "source '$DNET_FILE'; _dnet_pull nginx:1.2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rung 2: docker pull docker.m.daocloud.io/library/nginx:1.2"* ]]
}

@test "pull: with no ref it explains itself instead of pulling something" {
  run bash --norc -c "source '$DNET_FILE'; _dnet_pull"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: docker-net pull"* ]]
}

# --- dispatcher --------------------------------------------------------------

@test "docker-net: an unknown action exits 2 and prints usage" {
  run bash --norc -c "source '$DNET_FILE'; docker-net bogus"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown action bogus"* ]]
  [[ "$output" == *"Usage: docker-net"* ]]
}

@test "docker-net: help lists every verb the completions offer" {
  # Keep in sync with dot_config/{zsh/tools,bash}/58_docker_net_completion.*
  run bash --norc -c "source '$DNET_FILE'; docker-net --help"
  [ "$status" -eq 0 ]
  for verb in status doctor on off mirrors pull; do
    [[ "$output" == *"$verb"* ]]
  done
}

# --- macOS / VM-backed installs ----------------------------------------------
# No macOS host is available to run these against, so they pin the LOGIC that
# decides what happens there: shape detection from OperatingSystem, the VM
# locality verdict, and the early refusal in `on`.

@test "shape: OperatingSystem OrbStack wins over a leftover rootless hint" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||name=rootless,||OrbStack'
  result="$(_dnet_run bash '_dnet_info_load; _dnet_shape')"
  [ "$result" = "orbstack" ]
}

@test "shape: OperatingSystem Docker Desktop is told apart from OrbStack" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||||Docker Desktop'
  result="$(_dnet_run bash '_dnet_info_load; _dnet_shape')"
  [ "$result" = "desktop" ]
}

@test "locality: a VM-backed daemon is 'vm', not silently skipped" {
  # On macOS there is no /proc, so a netns-only check would say nothing at all —
  # and 127.0.0.1 would look fine right up until the daemon connects to nothing.
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||||OrbStack'
  result="$(_dnet_run bash '_dnet_info_load; _dnet_daemon_locality')"
  [ "$result" = "vm" ]
}

@test "locality: every verdict has a human explanation" {
  for kind in host netns vm unknown; do
    result="$(_dnet_run bash "_dnet_locality_detail $kind")"
    [ -n "$result" ]
  done
  # The two failing verdicts must both say 127.0.0.1 is the wrong address.
  result="$(_dnet_run bash '_dnet_locality_detail vm')"
  [[ "$result" == *"127.0.0.1"* ]]
  result="$(_dnet_run bash '_dnet_locality_detail netns')"
  [[ "$result" == *"127.0.0.1"* ]]
}

@test "on: refuses a VM-backed daemon before touching anything" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||||OrbStack'
  run bash --norc -c "source '$DNET_FILE'; _dnet_on http://127.0.0.1:7890"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs the daemon inside a VM"* ]]
  [[ "$output" == *"Settings > Network > Proxy"* ]]
  # It must NOT have got as far as the container confirmation.
  [[ "$output" != *"will be killed"* ]]
}

@test "on: Docker Desktop gets its own UI path in the refusal" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '29.6.2||||||Docker Desktop'
  run bash --norc -c "source '$DNET_FILE'; _dnet_on http://127.0.0.1:7890"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Settings > Resources > Proxies"* ]]
}

@test "portability: no bash-4-only builtins in the shared shell file" {
  # dot_config/shell/*.sh is sourced by macOS /bin/bash 3.2 as well as zsh.
  ! grep -qE '\bmapfile\b|\breadarray\b|\$\{[A-Za-z_]+\^\^\}|\bdeclare -A\b' "$DNET_FILE"
}

@test "portability: mktemp is called with a template (BSD requires one)" {
  grep -q 'mktemp "\${TMPDIR:-/tmp}/docker-net' "$DNET_FILE"
  ! grep -qE 'mktemp( 2>|\)|$)' "$DNET_FILE"
}

# --- dead-daemon handling (found on a real macOS host) -----------------------

@test "info_load: an all-empty record is a DEAD daemon, not a reachable one" {
  # Measured on macOS with Docker Desktop installed but stopped: `docker info`
  # prints a well-formed "||||||" and does not exit non-zero, so a non-empty
  # $raw proves nothing. ServerVersion is what only a live daemon can fill in.
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '||||||'
  run bash --norc -c "source '$DNET_FILE'; _dnet_info_load"
  [ "$status" -ne 0 ]
}

@test "status: a dead daemon says so instead of printing an empty report" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '||||||'
  run bash --norc -c "source '$DNET_FILE'; _dnet_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no reachable Docker daemon"* ]]
}

@test "timeout: a wedged docker info is abandoned, not waited on forever" {
  # `docker info` does not give up on its own when the daemon is unreachable.
  setup_path_stub
  cat > "$BATS_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
sleep 60
STUB
  chmod +x "$BATS_STUB_DIR/docker"
  start=$SECONDS
  run bash --norc -c "source '$DNET_FILE'; _dnet_info_load"
  elapsed=$(( SECONDS - start ))
  [ "$status" -ne 0 ]
  [ "$elapsed" -lt 20 ]
}

@test "timeout: the fallback path works without coreutils timeout" {
  # Stock macOS has neither `timeout` nor `gtimeout`; the polling fallback is
  # what runs there, so it needs its own coverage.
  setup_path_stub
  for t in timeout gtimeout; do
    printf '#!/usr/bin/env bash\nexit 127\n' > "$BATS_STUB_DIR/$t"
    chmod +x "$BATS_STUB_DIR/$t"
  done
  # Hide them from `command -v` by making _dnet_have fail: easiest is to shadow
  # with a directory entry that is not executable.
  rm -f "$BATS_STUB_DIR/timeout" "$BATS_STUB_DIR/gtimeout"
  result="$(bash --norc -c "
    source '$DNET_FILE'
    _dnet_have() { case \"\$1\" in timeout|gtimeout) return 1 ;; *) command -v \"\$1\" >/dev/null 2>&1 ;; esac; }
    _dnet_timeout 5 printf 'hello'
  ")"
  [ "$result" = "hello" ]
}

@test "timeout: the fallback path kills an overrunning command" {
  start=$SECONDS
  run bash --norc -c "
    source '$DNET_FILE'
    _dnet_have() { case \"\$1\" in timeout|gtimeout) return 1 ;; *) command -v \"\$1\" >/dev/null 2>&1 ;; esac; }
    _dnet_timeout 2 sleep 30
  "
  elapsed=$(( SECONDS - start ))
  [ "$status" -eq 124 ]
  [ "$elapsed" -lt 10 ]
}

# --- zsh-specific breakage (found on a real macOS host, reproduces on Linux) --

@test "on: refuses a VM-backed daemon under ZSH too, not just bash" {
  # Regression guard for `local path`: zsh ties the `path` array to `PATH`, so a
  # `local path` inside a function BLANKS PATH — every external command then
  # fails and `_dnet_have docker` returns false, which made `_dnet_shape` report
  # `none` and this very guard stop firing. bash treats `path` as an ordinary
  # variable, so the bash-only version of this test passed throughout.
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '28.5.1||||||Docker Desktop'
  run zsh -f -c "source '$DNET_FILE'; _dnet_on http://127.0.0.1:7890"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs the daemon inside a VM"* ]]
  [[ "$output" != *"command not found"* ]]
}

@test "no zsh-special name is used as a local anywhere in the file" {
  # path/fpath/cdpath/manpath are tied to their scalar twins; status/argv/
  # options/signals are reserved. Declaring any of them `local` has effects far
  # away from the declaration.
  # Parse the DECLARED NAMES only — `local action="${1:-status}"` mentions
  # `status` in its default value and must not trip this.
  names="$(grep -hoE '^[[:space:]]*local[[:space:]]+[^;#]*' "$DNET_FILE" \
             | sed -E 's/^[[:space:]]*local[[:space:]]+//' \
             | tr ' ' '\n' | sed -E 's/=.*//' | grep -v '^-' | grep -v '^$')"
  bad="$(printf '%s\n' "$names" | grep -xE 'path|fpath|cdpath|manpath|status|argv|options|signals|psvar|mailpath' || true)"
  [ -z "$bad" ]
}

@test "on/off keep PATH intact under zsh" {
  setup_path_stub
  _make_docker_info_stub "$BATS_STUB_DIR" '28.5.1||||||Docker Desktop'
  # PATH must survive the call — print it from inside the dispatcher's frame.
  result="$(zsh -f -c "
    source '$DNET_FILE'
    _dnet_probe_path() { local proxy shape target noproxy; printf '%s' \"\$PATH\"; }
    _dnet_probe_path
  ")"
  [ -n "$result" ]
}

@test "daemon probe: a silent failure is reported, not printed as a blank line" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then printf '%s' '29.6.2||||||Ubuntu'; exit 0; fi
exit 1
STUB
  chmod +x "$BATS_STUB_DIR/docker"
  run bash --norc -c "source '$DNET_FILE'; _dnet_report_init; _dnet_daemon_probe docker.io foo:bar"
  [[ "$output" == *"no output"* ]]
}
