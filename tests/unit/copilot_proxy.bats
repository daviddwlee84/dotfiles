#!/usr/bin/env bats
# Unit tests for the pure helpers behind `copilot-proxy doctor`
#   dot_config/shell/43_copilot_proxy.sh
#
# Only the OFFLINE, deterministic helpers are covered here. The doctor's
# network checks (_copilot_probe, _copilot_upstream_models) need GitHub and a
# running proxy, so they're exercised by hand, not in CI.
#
# The contract we care about (silent-regression risk):
#   1. _copilot_norm_models must fold the THREE id spellings that the same
#      model has across sources into one key, or the stale-cache diff reports
#      false positives on every run:
#        upstream GitHub : claude-opus-4.8       (dotted)
#        proxy .id       : claude-opus-4-8       (hyphenated)
#        proxy alias     : claude-opus-4-8[1m]   (Claude Code-only suffix)
#   2. _copilot_effective_model must honour the same precedence copilot-model
#      writes with (project pin > $COPILOT_CLAUDE_MODEL > state file > default),
#      or doctor validates a model the client never sends.

load "../test_helper.bash"

SOURCE_DIR="$REPO_ROOT"

setup() {
  SHELL_LIB="$SOURCE_DIR/dot_config/shell/43_copilot_proxy.sh"
  [ -f "$SHELL_LIB" ] || skip "43_copilot_proxy.sh not found"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/copilot-proxy.XXXXXX")"
}

# `skip` in setup() aborts before TMP exists, so guard — an unguarded
# `[ -n .. ] && rm` would exit non-zero and fail the test it just skipped.
teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
  return 0
}

write_fake_codex() {
  mkdir -p "$TMP/bin" "$TMP/proj"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "key=<%s>\n" "$GITHUB_COPILOT_API_KEY"' \
    'i=0' \
    'for arg do printf "arg[%s]=<%s>\n" "$i" "$arg"; i=$((i + 1)); done' \
    > "$TMP/bin/codex"
  chmod +x "$TMP/bin/codex"
}

write_update_fakes() {
  mkdir -p "$TMP/bin"
  printf '%s' 'copilot-api update fixture' > "$TMP/package.tgz"
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then out="$2"; shift 2; else shift; fi
done
cp "$FAKE_TARBALL" "$out"
SH
  cat > "$TMP/bin/bun" <<'SH'
#!/bin/sh
version="${2##*@}"
mkdir -p node_modules/.bin node_modules/@jeffreycao/copilot-api
printf '%s\n' '#!/bin/sh' 'exit 0' > node_modules/.bin/copilot-api
chmod +x node_modules/.bin/copilot-api
printf '{"version":"%s"}\n' "$version" > node_modules/@jeffreycao/copilot-api/package.json
SH
  chmod +x "$TMP/bin/curl" "$TMP/bin/bun"
}

# --- _copilot_norm_models -------------------------------------------------------

@test "probe failure kind: curl timeout is distinct from TLS and network" {
  run bash -c "source '$SHELL_LIB'; printf '%s|%s|%s' \
    \"\$(_copilot_probe_failure_kind 28 'operation timed out')\" \
    \"\$(_copilot_probe_failure_kind 60 'SSL certificate problem')\" \
    \"\$(_copilot_probe_failure_kind 7 'failed to connect')\""
  [ "$status" -eq 0 ]
  [ "$output" = "timeout|tls|network" ]
}

@test "optional HTTP probe: any non-000 HTTP response counts as reachable" {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
printf '\n403|0.125'
SH
  chmod +x "$TMP/bin/curl"
  run bash -c "PATH='$TMP/bin:/usr/bin:/bin'; source '$SHELL_LIB'; _copilot_optional_http_probe https://example.invalid"
  [ "$status" -eq 0 ]
  [ "$output" = "reached|403|0.125|" ]
}

@test "optional HTTP probe: certificate failures stay distinguishable" {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' 'curl: (60) SSL certificate problem: unable to get local issuer certificate' '000|0.250'
exit 60
SH
  chmod +x "$TMP/bin/curl"
  run bash -c "PATH='$TMP/bin:/usr/bin:/bin'; source '$SHELL_LIB'; _copilot_optional_http_probe https://example.invalid"
  [ "$status" -eq 0 ]
  [[ "$output" == "failed|tls|0.250|"* ]]
}

@test "norm_models: dotted, hyphenated and [1m] spellings fold to one key" {
  run bash -c "printf '%s\n' 'claude-opus-4.8' 'claude-opus-4-8' 'claude-opus-4-8[1m]' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-8" ]
}

@test "norm_models: lowercases and de-duplicates" {
  run bash -c "printf '%s\n' 'CLAUDE-Sonnet-5' 'claude-sonnet-5' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-5" ]
}

@test "norm_models: strips [1m] only as a suffix, not mid-string" {
  run bash -c "printf '%s\n' 'gpt-5.5[1m]' 'weird[1m]name' \
    | { source '$SHELL_LIB'; _copilot_norm_models; }"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'gpt-5-5'
  printf '%s\n' "$output" | grep -qx 'weird\[1m\]name'
}

@test "norm_models: a missing upstream id survives the set-difference" {
  # The diff doctor performs: upstream MINUS served, restricted to claude ids.
  local served upstream missing
  served="$(printf '%s\n' 'gpt-5.5' 'gemini-2.5-pro' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  upstream="$(printf '%s\n' 'claude-opus-4.8' 'gpt-5.5' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  missing="$(printf '%s\n' "$upstream" | grep -i '^claude' | while IFS= read -r m; do
    printf '%s\n' "$served" | grep -qxF "$m" || printf '%s\n' "$m"
  done)"
  [ "$missing" = "claude-opus-4-8" ]
}

@test "norm_models: identical lists yield an empty difference" {
  local served upstream missing
  served="$(printf '%s\n' 'claude-opus-4-8' 'claude-opus-4-8[1m]' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  upstream="$(printf '%s\n' 'claude-opus-4.8' | { source "$SHELL_LIB"; _copilot_norm_models; })"
  missing="$(printf '%s\n' "$upstream" | grep -i '^claude' | while IFS= read -r m; do
    printf '%s\n' "$served" | grep -qxF "$m" || printf '%s\n' "$m"
  done)"
  [ -z "$missing" ]
}

# --- _copilot_effective_model ---------------------------------------------------

@test "effective_model: falls back to the built-in default" {
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "gpt-5.6-sol[1m]|built-in default" ]]
}

@test "effective_model: \$COPILOT_CLAUDE_MODEL outranks the state file" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state' COPILOT_CLAUDE_MODEL='claude-haiku-4-5'
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-haiku-4-5|\$COPILOT_CLAUDE_MODEL" ]]
}

@test "effective_model: state file outranks the built-in default" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == claude-sonnet-5\|state\ file:* ]]
}

@test "effective_model: a copilot-here project pin outranks everything" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/proj/.claude" "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  cat > "$TMP/proj/.claude/settings.local.json" <<'JSON'
{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4141","ANTHROPIC_MODEL":"claude-opus-4-6[1m]"}}
JSON
  run bash -c "cd '$TMP/proj'; export XDG_STATE_HOME='$TMP/state' COPILOT_CLAUDE_MODEL='claude-haiku-4-5'
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == "claude-opus-4-6[1m]|project pin: .claude/settings.local.json" ]]
}

# --- _copilot_pkg_name / _copilot_pkg_ready -------------------------------------
#
# pkg_name feeds the pkill pattern that reaps a stalled `bun add`. The naive
# "${spec%@*}" returns EMPTY for a scoped spec with no version, which would turn
# the reap into `pkill -f 'bun add.*'` — a pattern that matches every bun install
# on the box. Hence the scope-stripped test inside the helper, and these cases.

@test "pkg_name: strips the version but keeps the @scope" {
  run bash -c "COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$status" -eq 0 ]
  [ "$output" = "@jeffreycao/copilot-api" ]
}

@test "pkg_name: a scoped spec with NO version survives intact (not emptied)" {
  run bash -c "COPILOT_API_PKG='@jeffreycao/copilot-api' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" = "@jeffreycao/copilot-api" ]
}

@test "pkg_name: unscoped spec, with and without a version" {
  run bash -c "COPILOT_API_PKG='copilot-api@0.7.0' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$output" = "copilot-api" ]
  run bash -c "COPILOT_API_PKG='copilot-api' \
    bash -c \"source '$SHELL_LIB'; _copilot_pkg_name\""
  [ "$output" = "copilot-api" ]
}

@test "pkg_ready: false when the stamp names a DIFFERENT spec than the pin" {
  # A version bump must re-install, not silently run the old binary.
  local prefix="$TMP/data/copilot-api/pkg"
  mkdir -p "$prefix/node_modules/.bin"
  printf '#!/bin/sh\n' > "$prefix/node_modules/.bin/copilot-api"
  chmod +x "$prefix/node_modules/.bin/copilot-api"
  printf '@jeffreycao/copilot-api@2.1.0\n' > "$prefix/.installed-spec"

  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@9.9.9'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -ne 0 ]

  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -eq 0 ]
}

@test "pkg_ready: false when the stamp exists but the binary does not" {
  local prefix="$TMP/data/copilot-api/pkg"
  mkdir -p "$prefix"
  printf '@jeffreycao/copilot-api@2.1.0\n' > "$prefix/.installed-spec"
  run bash -c "export XDG_DATA_HOME='$TMP/data' COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0'
    source '$SHELL_LIB'; _copilot_pkg_ready"
  [ "$status" -ne 0 ]
}

@test "package selection precedence is env then persisted state then built-in" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/state/copilot-proxy"
  run bash -c "export XDG_STATE_HOME='$TMP/state'; unset COPILOT_API_PKG; source '$SHELL_LIB'; _copilot_pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "@jeffreycao/copilot-api@2.3.4" ]
  run bash -c "source '$SHELL_LIB'; _copilot_builtin_integrity"
  [ "$status" -eq 0 ]
  [ "$output" = "sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==" ]
  printf '%s\n' '{"spec":"@jeffreycao/copilot-api@2.2.0","integrity":"sha512-test"}' > "$TMP/state/copilot-proxy/package.json"
  run bash -c "export XDG_STATE_HOME='$TMP/state'; unset COPILOT_API_PKG; source '$SHELL_LIB'; _copilot_pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "@jeffreycao/copilot-api@2.2.0" ]
  run bash -c "export XDG_STATE_HOME='$TMP/state' COPILOT_API_PKG='copilot-api@0.7.0'; source '$SHELL_LIB'; _copilot_pkg"
  [ "$status" -eq 0 ]
  [ "$output" = "copilot-api@0.7.0" ]
}

@test "exact update refuses to mutate state while env override is active" {
  run bash -c "export COPILOT_API_PKG='@jeffreycao/copilot-api@2.1.0'; source '$SHELL_LIB'; _copilot_update_exact 2.3.4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to mutate persisted selection"* ]]
}

@test "exact update rejects a tarball integrity mismatch before install" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  write_update_fakes
  run env FAKE_TARBALL="$TMP/package.tgz" bash -c "
    export PATH='$TMP/bin':\"\$PATH\" XDG_DATA_HOME='$TMP/data' XDG_STATE_HOME='$TMP/state';
    source '$SHELL_LIB';
    _copilot_registry_metadata() { printf '%s' '{\"dist\":{\"integrity\":\"sha512-wrong\",\"tarball\":\"https://fake/package.tgz\"}}'; }
    _copilot_update_exact 2.3.4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"integrity mismatch"* ]]
  [ ! -e "$TMP/data/copilot-api/pkg" ]
}

@test "failed post-update startup rolls package and selection back" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  write_update_fakes
  local digest
  digest="$(openssl dgst -sha512 -binary "$TMP/package.tgz" | openssl base64 -A)"
  mkdir -p "$TMP/data/copilot-api/pkg/node_modules/.bin" "$TMP/state/copilot-proxy"
  printf old > "$TMP/data/copilot-api/pkg/old-marker"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP/data/copilot-api/pkg/node_modules/.bin/copilot-api"
  chmod +x "$TMP/data/copilot-api/pkg/node_modules/.bin/copilot-api"
  printf '%s\n' '@jeffreycao/copilot-api@2.1.0' > "$TMP/data/copilot-api/pkg/.installed-spec"
  printf '%s\n' '{"spec":"@jeffreycao/copilot-api@2.1.0","integrity":"sha512-old"}' > "$TMP/state/copilot-proxy/package.json"
  run env FAKE_TARBALL="$TMP/package.tgz" META_INTEGRITY="sha512-$digest" bash -c "
    export PATH='$TMP/bin':\"\$PATH\" XDG_DATA_HOME='$TMP/data' XDG_STATE_HOME='$TMP/state';
    source '$SHELL_LIB';
    _copilot_registry_metadata() { printf '{\"dist\":{\"integrity\":\"%s\",\"tarball\":\"https://fake/package.tgz\"}}' \"\$META_INTEGRITY\"; }
    _copilot_alive() { return 0; }
    copilot-proxy() {
      case \"\$1\" in
        stop) return 0 ;;
        start) n=0; [ -f '$TMP/start-count' ] && n=\"\$(cat '$TMP/start-count')\"; n=\$((n+1)); printf '%s' \"\$n\" >'$TMP/start-count'; [ \"\$n\" -gt 1 ] ;;
      esac
    }
    _copilot_update_exact 2.3.4"
  [ "$status" -ne 0 ]
  [ -f "$TMP/data/copilot-api/pkg/old-marker" ]
  [ "$(jq -r '.spec' "$TMP/state/copilot-proxy/package.json")" = "@jeffreycao/copilot-api@2.1.0" ]
  [ "$(cat "$TMP/start-count")" = "2" ]
}

@test "pkg install: npm CA-stack fallback rescues two failed Bun attempts" {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/bun" <<'SH'
#!/bin/sh
exit 1
SH
  cat > "$TMP/bin/npm" <<'SH'
#!/bin/sh
mkdir -p node_modules/.bin
printf '#!/bin/sh\n' > node_modules/.bin/copilot-api
chmod +x node_modules/.bin/copilot-api
printf '%s\n' npm > npm-fallback-used
SH
  chmod +x "$TMP/bin/bun" "$TMP/bin/npm"

  run bash -c "export PATH='$TMP/bin:/usr/bin:/bin' XDG_DATA_HOME='$TMP/data'
    source '$SHELL_LIB'; _copilot_ensure_pkg >/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$TMP/data/copilot-api/pkg/npm-fallback-used" ]
  [ "$(cat "$TMP/data/copilot-api/pkg/.installed-spec")" = "@jeffreycao/copilot-api@2.3.4" ]
}

# --- integrity guard: the lock is evidence only about ITS OWN version ----------
#
# `bun add` writes bun.lock and never touches package-lock.json, so one npm
# CA-stack fallback leaves a package-lock.json pinned to that version forever.
# Reading it unconditionally compared 2.1.0's real hash to the 2.3.4 pin and
# wedged every start. pitfalls/copilot-proxy-stale-package-lock-integrity.md

# Installs the pinned version into the prefix and writes a package-lock.json
# claiming $1 (version) / $2 (integrity) — the mixed-manager prefix shape.
write_stale_lock_fixture() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/bun" <<SH
#!/bin/sh
mkdir -p node_modules/.bin node_modules/@jeffreycao/copilot-api
printf '#!/bin/sh\n' > node_modules/.bin/copilot-api
chmod +x node_modules/.bin/copilot-api
printf '{"version":"2.3.4"}\n' > node_modules/@jeffreycao/copilot-api/package.json
SH
  chmod +x "$TMP/bin/bun"
  mkdir -p "$TMP/data/copilot-api/pkg"
  printf '{"packages":{"node_modules/@jeffreycao/copilot-api":{"version":"%s","integrity":"%s"}}}\n' \
    "$1" "$2" > "$TMP/data/copilot-api/pkg/package-lock.json"
}

@test "integrity guard: a stale npm lock for ANOTHER version does not block install" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # 2.1.0's genuine hash, left by a months-old npm fallback; pin is 2.3.4.
  write_stale_lock_fixture 2.1.0 \
    'sha512-9/Ro1UzrYT/erB7eR/rf61XHFyc5TOwQ94B6ij/Wu91TD1hnmbuqYu/PavKGUQ7YDBVCXFENRRvQSpTkS0X3eA=='
  run bash -c "export PATH='$TMP/bin':\"\$PATH\" XDG_DATA_HOME='$TMP/data' XDG_STATE_HOME='$TMP/state'
    source '$SHELL_LIB'
    _copilot_registry_metadata() { printf '%s' '{\"dist\":{\"integrity\":\"'\"\$(_copilot_builtin_integrity)\"'\"}}'; }
    _copilot_ensure_pkg >/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" != *"does not match the trusted pin"* ]]
  [ "$(cat "$TMP/data/copilot-api/pkg/.installed-spec")" = "@jeffreycao/copilot-api@2.3.4" ]
}

@test "integrity guard: a lock for the INSTALLED version with a bad hash still refuses" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  write_stale_lock_fixture 2.3.4 'sha512-tampered'
  run bash -c "export PATH='$TMP/bin':\"\$PATH\" XDG_DATA_HOME='$TMP/data' XDG_STATE_HOME='$TMP/state'
    source '$SHELL_LIB'; _copilot_ensure_pkg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the trusted pin"* ]]
  # The message must name both sides, or the next occurrence needs a bisect.
  [[ "$output" == *"@2.3.4"* ]]
  [ ! -e "$TMP/data/copilot-api/pkg/.installed-spec" ]
}

# --- shim start: port state must be read from the PORT, not from health -------
#
# An older shim build proxies /_shim/health upstream (4141 answers 404), so the
# liveness probe says "dead" while the OS says "occupied" — and the spawn dies
# with EADDRINUSE forever. pitfalls/copilot-proxy-shim-eaddrinuse-stale-build.md

# Fakes lsof + ps so the port looks occupied by PID 4242 running $1. lsof reports
# the PID only on its FIRST call, so the reclaim branch's release-wait converges
# instead of spinning its full 5s budget.
write_shim_port_fixture() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/lsof" <<SH
#!/bin/sh
[ -f "$TMP/lsof-called" ] && exit 1
: > "$TMP/lsof-called"
echo 4242
SH
  cat > "$TMP/bin/ps" <<SH
#!/bin/sh
printf '%s\n' "$1"
SH
  cat > "$TMP/bin/bun" <<'SH'
#!/bin/sh
printf '%s
' "$@" > "$SHIM_SPAWN_LOG"
SH
  chmod +x "$TMP/bin/lsof" "$TMP/bin/ps" "$TMP/bin/bun"
}

# `kill` is a bash BUILTIN, so a $PATH fake is never consulted — the only way to
# observe the reclaim is a shell function of the same name, declared after the
# library is sourced.
@test "shim start: reclaims the port from a stale copilot-throttle-shim build" {
  write_shim_port_fixture "bun /home/u/.config/shell/copilot-throttle-shim.js"
  run env SHIM_SPAWN_LOG="$TMP/spawned" bash -c "
    export PATH='$TMP/bin':\"\$PATH\"
    source '$SHELL_LIB'
    kill() { printf 'killed %s\n' \"\$@\" >> '$TMP/killed'; }
    _copilot_shim_script() { printf '%s' '$SHELL_LIB'; }
    _copilot_shim_logfile() { printf '%s' '$TMP/shim.log'; }
    _copilot_shim_pidfile() { printf '%s' '$TMP/shim.pid'; }
    _copilot_shim_alive() { [ -f '$TMP/spawned' ]; }
    _copilot_shim_start"
  [ "$status" -eq 0 ]
  [ -f "$TMP/killed" ]
  [[ "$(cat "$TMP/killed")" == *4242* ]]
  [[ "$(cat "$TMP/spawned")" == *"$SHELL_LIB"* ]]
  [[ "$output" != *"held by another process"* ]]
}

@test "shim start: names a foreign squatter instead of killing it" {
  write_shim_port_fixture "/usr/bin/python3 -m http.server"
  run env SHIM_SPAWN_LOG="$TMP/spawned" bash -c "
    export PATH='$TMP/bin':\"\$PATH\"
    source '$SHELL_LIB'
    kill() { printf 'killed %s\n' \"\$@\" >> '$TMP/killed'; }
    _copilot_shim_script() { printf '%s' '$SHELL_LIB'; }
    _copilot_shim_alive() { return 1; }
    _copilot_shim_start"
  [ "$status" -ne 0 ]
  [[ "$output" == *"held by another process"* ]]
  [[ "$output" == *4242* ]]
  [ ! -f "$TMP/killed" ]
  [ ! -f "$TMP/spawned" ]
}

@test "effective_model: a settings.local.json WITHOUT our base_url is not a pin" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/proj/.claude" "$TMP/state/copilot-proxy"
  printf 'claude-sonnet-5\n' > "$TMP/state/copilot-proxy/model"
  # plansDirectory-only local settings: copilot-here is OFF here
  printf '%s\n' '{"plansDirectory":".claude/plans"}' > "$TMP/proj/.claude/settings.local.json"
  run bash -c "cd '$TMP/proj'; export XDG_STATE_HOME='$TMP/state'; unset COPILOT_CLAUDE_MODEL
    source '$SHELL_LIB'; _copilot_effective_model"
  [ "$status" -eq 0 ]
  [[ "$output" == claude-sonnet-5\|state\ file:* ]]
}

# --- model ranking / Claude Code role profiles ---------------------------------

@test "pick_best_model: Claude Fable outranks Opus and OpenAI" {
  run bash -c "printf '%s\n' gpt-5.6-sol claude-opus-5 claude-fable-5 \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-fable-5" ]
}

@test "codex picker: OpenAI Sol outranks Claude and Gemini" {
  run bash -c "printf '%s\n' claude-fable-5 gemini-3.1-pro-preview gpt-5.6-terra gpt-5.6-sol \
    | { source '$SHELL_LIB'; _copilot_codex_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "codex picker: Claude is the fallback before Gemini" {
  run bash -c "printf '%s\n' gemini-3.1-pro-preview claude-sonnet-5 claude-opus-5 \
    | { source '$SHELL_LIB'; _copilot_codex_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]
}

@test "codex picker: non-flash Gemini beats flash when no OpenAI or Claude" {
  run bash -c "printf '%s\n' gemini-3.6-flash gemini-3.1-pro-preview \
    | { source '$SHELL_LIB'; _copilot_codex_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini-3.1-pro-preview" ]
}

@test "specstory codex command: project config preserves configured flags" {
  mkdir -p "$TMP/proj/.specstory/cli" "$TMP/home/.specstory/cli"
  printf '%s\n' "codex_cmd = 'codex --sandbox danger-full-access -c model_reasoning_effort=\"high\"'" \
    > "$TMP/home/.specstory/cli/config.toml"
  printf '%s\n' 'codex_cmd = "codex --ask-for-approval never"' \
    > "$TMP/proj/.specstory/cli/config.toml"
  run bash -c "cd '$TMP/proj'; export HOME='$TMP/home'; source '$SHELL_LIB'; _copilot_specstory_codex_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "codex --ask-for-approval never" ]
}

@test "codex catalog: caches the bundled catalog by Codex version" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/codex" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) printf '%s\n' 'codex-cli 9.9.9' ;;
  debug)
    printf '%s\n' '{"models":[{"slug":"gpt-test"}]}'
    printf '%s\n' generated >> "$TEST_GENERATIONS"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/codex"

  run env TEST_GENERATIONS="$TMP/generations" bash -c "
    export PATH='$TMP/bin':\"\$PATH\" XDG_CACHE_HOME='$TMP/cache'
    source '$SHELL_LIB'
    first=\"\$(_copilot_codex_catalog_file)\" || exit
    second=\"\$(_copilot_codex_catalog_file)\" || exit
    printf '%s|%s|%s' \"\$first\" \"\$second\" \"\$(wc -l < '$TMP/generations' | tr -d ' ')\""
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/cache/copilot-proxy/codex-models/codex-cli_9.9.9.json|$TMP/cache/copilot-proxy/codex-models/codex-cli_9.9.9.json|1" ]
}

@test "codex launcher: auto selects Sol, injects live limits, and writes no config" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  write_fake_codex
  printf '%s\n' '{"models":[{"slug":"gpt-5.6-sol"}]}' > "$TMP/bundled-models.json"
  local catalog='{"data":[{"id":"claude-opus-5"},{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":920000}}}]}'
  run env TEST_CATALOG="$catalog" bash -c "
    cd '$TMP/proj'; PATH='$TMP/bin':\"\$PATH\"; source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_shim_alive() { return 0; }
    _copilot_shim_base() { printf '%s' 'http://localhost:4242'; }
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    _copilot_codex_catalog_file() { printf '%s' '$TMP/bundled-models.json'; }
    codex-copilot --no-specstory exec --skip-git-repo-check 'two words'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex-copilot: --auto -> gpt-5.6-sol"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '=<\-m>$')" -eq 1 ]
  [[ "$output" == *"=<gpt-5.6-sol>"* ]]
  [[ "$output" == *"=<model_context_window=1050000>"* ]]
  [[ "$output" == *"=<model_auto_compact_token_limit=920000>"* ]]
  [[ "$output" == *"=<model_catalog_json=\"$TMP/bundled-models.json\">"* ]]
  [[ "$output" == *"=<model_providers.copilot_api.base_url=\"http://localhost:4242\">"* ]]
  [[ "$output" == *"=<features.remote_compaction_v2=true>"* ]]
  [[ "$output" == *"=<two words>"* ]]
  [ ! -e "$TMP/proj/.codex" ]
}

@test "codex launcher: explicit model is preserved without an auto override" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  write_fake_codex
  printf '%s\n' '{"models":[{"slug":"gpt-5.6-sol"}]}' > "$TMP/bundled-models.json"
  local catalog='{"data":[{"id":"gpt-5.6-sol"},{"id":"claude-opus-5"}]}'
  run env TEST_CATALOG="$catalog" bash -c "
    cd '$TMP/proj'; PATH='$TMP/bin':\"\$PATH\"; source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_shim_alive() { return 0; }
    _copilot_shim_base() { printf '%s' 'http://localhost:4242'; }
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    _copilot_codex_catalog_file() { printf '%s' '$TMP/bundled-models.json'; }
    codex-copilot --no-specstory -m claude-opus-5 exec 'two words'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--auto ->"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '=<\-m>$')" -eq 1 ]
  [[ "$output" == *"=<claude-opus-5>"* ]]
  [[ "$output" == *"=<model_catalog_json=\"$TMP/bundled-models.json\">"* ]]
  [[ "$output" == *"=<two words>"* ]]
}

@test "Codex launcher starts the metrics shim by default" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  write_fake_codex
  printf '%s\n' '{"models":[{"slug":"gpt-5.6-sol"}]}' > "$TMP/bundled-models.json"
  local catalog='{"data":[{"id":"gpt-5.6-sol"}]}'
  run env TEST_CATALOG="$catalog" bash -c "
    cd '$TMP/proj'; PATH='$TMP/bin':\"\$PATH\"; source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_shim_alive() { return 1; }
    _copilot_shim_start() { printf '%s\n' started-shim; return 0; }
    _copilot_shim_base() { printf '%s' 'http://localhost:4242'; }
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    _copilot_codex_catalog_file() { printf '%s' '$TMP/bundled-models.json'; }
    codex-copilot --no-specstory exec 'two words'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"started-shim"* ]]
  [[ "$output" == *"=<model_providers.copilot_api.base_url=\"http://localhost:4242\">"* ]]
}

# --- copilot-run injects the SAME block copilot-here writes ---------------------
#
# copilot-run used to hand-maintain a second copy of the key list, so it could
# inject different env than `copilot-here on` on the same machine — and only the
# copilot-here copy was covered by the drift check.

@test "copilot-run injects exactly the copilot-here env block, nothing else" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local catalog='{"data":[{"id":"gpt-5.6-sol"}]}'
  run env TEST_CATALOG="$catalog" bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    _copilot_client_base() { printf '%s' 'http://localhost:4242'; }
    _copilot_pinned_base() { printf '%s' 'http://pinned.invalid'; }
    want=\"\$(_copilot_env_json_for_model --live \"\$(_copilot_default_model)\" \"\$TEST_CATALOG\" | jq -r 'keys[]' | sort)\"
    got=\"\$(copilot-run env | grep -Ff <(printf '%s\n' \"\$want\") | cut -d= -f1 | sort -u)\"
    [ \"\$want\" = \"\$got\" ] || { printf 'want:\n%s\ngot:\n%s\n' \"\$want\" \"\$got\"; exit 1; }
    copilot-run env | grep '^ANTHROPIC_BASE_URL='"
  [ "$status" -eq 0 ]
  # --live must win over the pinned base copilot-here would write to disk.
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://localhost:4242"* ]]
  [[ "$output" != *"pinned.invalid"* ]]
}

@test "copilot-run passes multi-word argv through untouched" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # A fake binary rather than a nested `sh -c`: the point is that prepending the
  # env block to "$@" must not re-split the caller's own arguments.
  mkdir -p "$TMP/bin"
  printf '%s\n' '#!/bin/sh' 'for a do printf "<%s>\n" "$a"; done' > "$TMP/bin/argecho"
  chmod +x "$TMP/bin/argecho"
  run bash -c "
    export PATH='$TMP/bin':\"\$PATH\"
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_model_catalog() { printf '%s' '{\"data\":[{\"id\":\"gpt-5.6-sol\"}]}'; }
    copilot-run argecho 'two words' 'a|b' ''"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<two words>"* ]]
  [[ "$output" == *"<a|b>"* ]]
  [[ "$output" == *"<>"* ]]
}

@test "copilot-run adds the four quota savers only under COPILOT_PROXY_QUIET=1" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local body="
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_model_catalog() { printf '%s' '{\"data\":[{\"id\":\"gpt-5.6-sol\"}]}'; }
    copilot-run env | grep -cE '^(CLAUDE_CODE_ATTRIBUTION_HEADER|CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION|CLAUDE_CODE_ENABLE_AWAY_SUMMARY|DISABLE_NON_ESSENTIAL_MODEL_CALLS)=' || true"
  run bash -c "$body"
  [ "$output" = "0" ]
  run env COPILOT_PROXY_QUIET=1 bash -c "$body"
  [ "$output" = "4" ]
}

@test "explicit shim off is a direct-mode break-glass route" {
  run bash -c "export XDG_STATE_HOME='$TMP/state'; mkdir -p '$TMP/state/copilot-proxy'; printf 'off\n' >'$TMP/state/copilot-proxy/shim'; source '$SHELL_LIB';
    _copilot_shim_alive() { return 1; }
    _copilot_shim_start() { printf should-not-start; return 1; }
    printf '%s' \"\$(_copilot_client_base)\""
  [ "$status" -eq 0 ]
  [ "$output" = "http://localhost:4141" ]
}

@test "Responses shim fills only blank MCP tool descriptions" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "import { normalizeResponsesToolDescriptions as n } from '$shim';
    const p={tools:[{type:'web_search'},{type:'function',name:'top',description:''}],input:[{type:'mcp_list_tools',tools:[{name:'alpha',description:''},{name:'beta',description:null},{name:'gamma',description:'kept'}]},{type:'message',tools:[{name:'prompt-data',description:''}]}]};
    const r=n(p); console.log(JSON.stringify({r,p}));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.r.changed')" = "4" ]
  [ "$(printf '%s' "$output" | jq -r '.p.input[0].tools[0].description')" = "Tool alpha." ]
  [ "$(printf '%s' "$output" | jq -r '.p.input[0].tools[2].description')" = "kept" ]
  [ "$(printf '%s' "$output" | jq -r '.p.input[1].tools[0].description')" = "Tool prompt-data." ]
  [ "$(printf '%s' "$output" | jq -r '.p.tools[0] | has("description")')" = "false" ]
}

@test "Responses shim decodes zstd before normalization" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "import { normalizeRequestBody as n } from '$shim';
    const source=JSON.stringify({input:[{tools:[{name:'compressed',description:''}]}]});
    const compressed=Bun.zstdCompressSync(new TextEncoder().encode(source));
    const r=n('/responses',compressed,'zstd');
    console.log(JSON.stringify({changed:r.changed,decoded:r.decoded,p:JSON.parse(r.body)}));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.decoded')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.p.input[0].tools[0].description')" = "Tool compressed." ]
}

@test "unchanged zstd Responses body remains inspectable for stream metrics" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "import { normalizeRequestBody as n, wantsStream as w } from '$shim';
    const compressed=Bun.zstdCompressSync(new TextEncoder().encode(JSON.stringify({model:'m',stream:true})));
    const r=n('/v1/responses',compressed,'zstd');
    console.log(JSON.stringify({changed:r.changed,decoded:r.decoded,stream:w(r.inspectBody),forwardedCompressed:r.body===compressed.buffer}));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changed')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.stream')" = "true" ]
}

@test "wantsStream only classifies an explicit stream:true body" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "import { wantsStream as w } from '$shim';
    const enc=(o)=>new TextEncoder().encode(JSON.stringify(o)).buffer;
    console.log(JSON.stringify({
      yes:      w(enc({model:'m',stream:true})),
      str:      w(JSON.stringify({model:'m',stream:true})),
      no:       w(enc({model:'m',stream:false})),
      missing:  w(enc({model:'m'})),
      truthy:   w(enc({model:'m',stream:'true'})),
      garbage:  w(new TextEncoder().encode('not json').buffer),
    }));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.yes')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.str')" = "true" ]
  # Anything that is not literally `true` must fall back to the pre-keepalive
  # path — a non-streaming caller would choke on injected comment frames.
  [ "$(printf '%s' "$output" | jq -r '.no')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.missing')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.truthy')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.garbage')" = "false" ]
}

# End-to-end against a mock upstream that withholds its response headers the way
# copilot-api does while a reasoning model thinks. Guards the four-way split the
# keepalive introduced; see pitfalls/copilot-proxy-openai-model-silent-stall.md.
@test "shim keepalive fires only on slow streams, leaving fast + non-stream untouched" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  cat >"$TMP/keepalive.js" <<'JS'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const up = Bun.serve({ port: 0, idleTimeout: 60, async fetch(req) {
  const u = new URL(req.url);
  await sleep(Number(u.searchParams.get("delay") ?? 0));
  if (u.searchParams.get("mode") === "status")
    return new Response('{"error":"nope"}', { status: 400, headers: { "content-type": "application/json" } });
  return new Response("event: message_start\ndata: {}\n\nevent: message_stop\ndata: {}\n\n",
    { headers: { "content-type": "text/event-stream" } });
} });
process.env.COPILOT_SHIM_PORT = "0";
process.env.COPILOT_SHIM_UPSTREAM = `http://localhost:${up.port}`;
process.env.COPILOT_SHIM_PING_MS = "150";
process.env.COPILOT_SHIM_PING_AFTER_MS = "100";
process.env.COPILOT_SHIM_STALL_MS = "5000";
process.env.COPILOT_SHIM_METRICS_DB = process.argv[3];
const { startServer } = await import(process.argv[2]);
const shim = startServer();
const call = async (q, stream = true) => {
  const r = await fetch(`http://localhost:${shim.port}/v1/messages${q}`, { method: "POST",
    headers: { "content-type": "application/json" }, body: JSON.stringify({ model: "m", stream }) });
  const body = await r.text();
  return { status: r.status, ct: r.headers.get("content-type"),
    trace: r.headers.get("x-trace-id"),
    pings: (body.match(/^: /gm) ?? []).length,
    events: (body.match(/^event: (\S+)/gm) ?? []).map((s) => s.slice(7)) };
};
const out = {
  slow:    await call("?delay=800"),
  fast:    await call("?delay=0"),
  plain:   await call("?delay=800&mode=status", false),
  lateErr: await call("?delay=800&mode=status"),
};
out.metrics = await (await fetch(`http://localhost:${shim.port}/_shim/events?period=day&scope=all&limit=20`)).json();
console.log(JSON.stringify(out));
shim.stop(true); up.stop(true);
JS
  run bash -c "bun '$TMP/keepalive.js' '$shim' '$TMP/keepalive-metrics.sqlite' 2>&1 | tail -n 1"
  [ "$status" -eq 0 ]
  local j="$output"
  # Slow stream: comment frames while the upstream is silent, real events after.
  [ "$(printf '%s' "$j" | jq -r '.slow.pings > 0')" = "true" ]
  [ "$(printf '%s' "$j" | jq -r '.slow.events | join(",")')" = "message_start,message_stop" ]
  [ "$(printf '%s' "$j" | jq -r '.slow.trace | length > 0')" = "true" ]
  # Fast stream: inside the grace window, so nothing is injected at all.
  [ "$(printf '%s' "$j" | jq -r '.fast.pings')" = "0" ]
  # Non-streaming request: never eligible — real 400 and the JSON body verbatim.
  [ "$(printf '%s' "$j" | jq -r '.plain.status')" = "400" ]
  [ "$(printf '%s' "$j" | jq -r '.plain.ct')" = "application/json" ]
  [ "$(printf '%s' "$j" | jq -r '.plain.pings')" = "0" ]
  # A non-2xx that arrives AFTER the early commit can only be an SSE error event.
  [ "$(printf '%s' "$j" | jq -r '.lateErr.status')" = "200" ]
  [ "$(printf '%s' "$j" | jq -r '.lateErr.events | join(",")')" = "error" ]
  [ "$(printf '%s' "$j" | jq -r '.metrics | length')" = "4" ]
}

@test "shim retries delayed 500s and bounds cancellation/error paths" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  local fixture="$SOURCE_DIR/tests/fixtures/copilot-shim-hardening.mjs"
  run bash -c "bun '$fixture' '$shim' '$TMP/hardening-metrics.sqlite' 2>&1 | tail -n 1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.retryReplay.attempts')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.retryReplay.sameBody')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.retryReplay.sameTrace')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.retry.events | join(",")')" = "message_start,message_stop" ]
  [ "$(printf '%s' "$output" | jq -r '.cancelBarrier.waited')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cancelBarrier.settled')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.exhausted.events | last')" = "response.failed" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status400')" = "invalid_prompt" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status401')" = "invalid_prompt" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status402')" = "insufficient_quota" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status429')" = "rate_limit_exceeded" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status500')" = "server_error" ]
  [ "$(printf '%s' "$output" | jq -r '.counts["/v1/responses:status429"]')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.nonSse.events | last')" = "error" ]
  [ "$(printf '%s' "$output" | jq -r '.fastNonSse.status')" = "502" ]
  [ "$(printf '%s' "$output" | jq -r '.mixedSse.events | join(",")')" = "message_start,message_stop" ]
  [ "$(printf '%s' "$output" | jq -r '.billing.status')" = "402" ]
  [ "$(printf '%s' "$output" | jq -r '.stalled.elapsed_ms < 4000')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.activeAbortResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.deadResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.backoffResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.backoffReleaseMs < 1000')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.counts["/v1/messages:backoff"]')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "retry500" and .attempts == 2 and .retries == 1 and .error_kind == null)] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "nonsse" and .error_kind == "upstream_protocol")] | length')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "activeabort" and .attempts == 1 and .status == 499 and .error_kind == "client_cancel")] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "dead" and .attempts == 0 and .error_kind == "client_cancel")] | length')" = "1" ]
}

@test "shim metrics join one-to-many token events and compute throughput" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run env METRICS="$TMP/metrics.sqlite" TOKENS="$TMP/tokens.sqlite" bun -e "
    process.env.COPILOT_SHIM_METRICS_DB=process.env.METRICS;
    process.env.COPILOT_API_SQLITE_DB_PATH=process.env.TOKENS;
    const {Database}=await import('bun:sqlite');
    const m=await import('$shim');
    const tdb=new Database(process.env.TOKENS,{create:true});
    tdb.exec('CREATE TABLE token_usage_events(trace_id TEXT,model TEXT,input_tokens INTEGER,output_tokens INTEGER,total_tokens INTEGER,total_nano_aiu INTEGER)');
    tdb.query('INSERT INTO token_usage_events VALUES (?,?,?,?,?,?)').run('trace-1','model-a',10,40,50,1000000000);
    tdb.query('INSERT INTO token_usage_events VALUES (?,?,?,?,?,?)').run('trace-1','model-a',5,60,65,2000000000);
    tdb.close();
    const db=m.openMetricsDb(process.env.METRICS); let times=[0,5,25,35,1035];
    db.query(\"INSERT INTO request_metrics(trace_id,created_at_ms,endpoint,scope) VALUES (?,?,?,?)\").run('old-trace',Date.now()-91*86400*1000,'/old','normal');
    m.pruneMetrics(db);
    const tracker=m.createMetricTracker({traceId:'trace-1',endpoint:'/v1/responses',model:'model-a',scope:'normal',streaming:true},db,()=>times.shift());
    tracker.acquired(); tracker.headers(); tracker.firstByte(); tracker.attempt(); tracker.finalize(200); db.close();
    console.log(JSON.stringify(m.queryStats({period:'day',scope:'normal',model:'model-a'})));
  "
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requests')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.output_tokens')" = "100" ]
  [ "$(printf '%s' "$output" | jq -r '.total_aiu')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.timing.output_tps.p50')" = "100" ]
}

@test "metrics CLI validates benchmark safety limits without network traffic" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run env COPILOT_SHIM_METRICS_DB="$TMP/metrics.sqlite" bun "$shim" bench --model model-a --runs 11 --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"--runs must be 1..10"* ]]
}

@test "copilot-proxy stats and events work offline in JSON and human modes" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bash -c "export COPILOT_SHIM_METRICS_DB='$TMP/offline.sqlite'; source '$SHELL_LIB';
    _copilot_shim_script() { printf '%s' '$shim'; }
    copilot-proxy stats day --json; copilot-proxy events day"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n1 | jq -r '.requests')" = "0" ]
  [[ "$output" == *"no matching requests"* ]]
}

@test "copilot-here on reports the shim URL it actually writes" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/proj"
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    _copilot_env_json() { printf '%s' '{\"ANTHROPIC_BASE_URL\":\"http://localhost:4142\",\"ANTHROPIC_MODEL\":\"gpt-test\"}'; }
    _copilot_alive() { return 0; }
    copilot-here on"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pins Claude Code to http://localhost:4142"* ]]
  [ "$(jq -r '.env.ANTHROPIC_BASE_URL' "$TMP/proj/.claude/settings.local.json")" = "http://localhost:4142" ]
}

@test "pick_best_model: Sol is the strongest OpenAI fallback" {
  run bash -c "printf '%s\n' gpt-5.3-codex gpt-5.6-luna gpt-5.5 gpt-5.6-terra gpt-5.6-sol \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "pick_best_model: old flagships outrank lightweight Luna" {
  run bash -c "printf '%s\n' gpt-5.6-luna gpt-5.4-mini gpt-5.3-codex gpt-5.4 gpt-5.5 \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]
}

@test "model_for_claude: context metadata controls the [1m] hint" {
  local catalog='{"data":[{"id":"gpt-large","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-small","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    printf '%s|%s' \"\$(_copilot_model_for_claude gpt-large \"\$CATALOG\")\" \
      \"\$(_copilot_model_for_claude gpt-small \"\$CATALOG\")\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-large[1m]|gpt-small" ]
}

@test "model profile: OpenAI maps quality balanced and fast roles" {
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json gpt-5.6-sol \"\$CATALOG\" | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"main":"gpt-5.6-sol[1m]","fable":"gpt-5.6-sol[1m]","opus":"gpt-5.6-sol[1m]","sonnet":"gpt-5.6-terra[1m]","haiku":"gpt-5.6-luna"}' ]
}

@test "model profile: missing OpenAI role tiers fall back to the selected main" {
  local catalog='{"data":[{"id":"gpt-5.5","capabilities":{"limits":{"max_context_window_tokens":1050000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json gpt-5.5 \"\$CATALOG\" | jq -r '[.main,.fable,.opus,.sonnet,.haiku] | unique | join(\"|\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5[1m]" ]
}

@test "model profile: native Claude roles use their strongest served families" {
  local catalog='{"data":[{"id":"claude-fable-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-opus-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-sonnet-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-haiku-4-5","capabilities":{"limits":{"max_context_window_tokens":200000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json claude-fable-5 \"\$CATALOG\" | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"main":"claude-fable-5[1m]","fable":"claude-fable-5[1m]","opus":"claude-opus-5[1m]","sonnet":"claude-sonnet-5[1m]","haiku":"claude-haiku-4-5"}' ]
}

@test "env profile: Fable is managed and legacy small-fast follows Haiku" {
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_env_json_for_model gpt-5.6-sol \"\$CATALOG\" \
      | jq -r '[.ANTHROPIC_DEFAULT_FABLE_MODEL,.ANTHROPIC_DEFAULT_OPUS_MODEL,.ANTHROPIC_DEFAULT_SONNET_MODEL,.ANTHROPIC_DEFAULT_HAIKU_MODEL,.ANTHROPIC_SMALL_FAST_MODEL] | join(\"|\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna" ]
}

@test "copilot-model --auto: refuses an offline static fallback" {
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; source '$SHELL_LIB'
    _copilot_model_catalog() { return 1; }
    copilot-model --auto"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a reachable proxy and live /v1/models catalog"* ]]
  [ ! -f "$TMP/state/copilot-proxy/model" ]
}

@test "copilot-model --auto: refreshes every role in an active local pin" {
  mkdir -p "$TMP/proj/.claude"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4141","ANTHROPIC_MODEL":"stale","ANTHROPIC_DEFAULT_SONNET_MODEL":"stale"},"permissions":{"defaultMode":"auto"}}' \
    > "$TMP/proj/.claude/settings.local.json"
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    _copilot_model_catalog() { printf '%s' \"\$CATALOG\"; }
    copilot-model --auto >/dev/null 2>&1
    jq -r '[.env.ANTHROPIC_MODEL,.env.ANTHROPIC_DEFAULT_FABLE_MODEL,.env.ANTHROPIC_DEFAULT_OPUS_MODEL,.env.ANTHROPIC_DEFAULT_SONNET_MODEL,.env.ANTHROPIC_DEFAULT_HAIKU_MODEL,.env.ANTHROPIC_SMALL_FAST_MODEL,.permissions.defaultMode] | join(\"|\")' .claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna|auto" ]
}
