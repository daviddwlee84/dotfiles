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

@test "doctor helper detects when the installed fork strips fast service_tier" {
  mkdir -p "$TMP/pkg/node_modules/@jeffreycao/copilot-api/dist"
  printf '%s\n' 'payload.service_tier = void 0;' >"$TMP/pkg/node_modules/@jeffreycao/copilot-api/dist/server-test.js"
  run bash -c "source '$SHELL_LIB';
    _copilot_pkg_flavor() { printf fork; }
    _copilot_pkg_prefix() { printf '%s' '$TMP/pkg'; }
    _copilot_pkg_name() { printf '%s' '@jeffreycao/copilot-api'; }
    _copilot_fast_tier_state"
  [ "$status" -eq 0 ]
  [ "$output" = "stripped" ]
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
    _copilot_model_catalog() { printf '%s' '{\"data\":[{\"id\":\"gpt-5.6-sol\",\"capabilities\":{\"limits\":{\"max_prompt_tokens\":922000}}}]}'; }
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
    _copilot_model_catalog() { printf '%s' '{\"data\":[{\"id\":\"gpt-5.6-sol\",\"capabilities\":{\"limits\":{\"max_prompt_tokens\":922000}}}]}'; }
    copilot-run env | grep -cE '^(CLAUDE_CODE_ATTRIBUTION_HEADER|CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION|CLAUDE_CODE_ENABLE_AWAY_SUMMARY|DISABLE_NON_ESSENTIAL_MODEL_CALLS)=' || true"
  # The suite itself may be running inside claude-copilot; pin the fixture's
  # launch model instead of inheriting the outer session's fast/proxy env.
  run env COPILOT_CLAUDE_MODEL=gpt-5.6-sol COPILOT_PROXY_QUIET=0 bash -c "$body"
  [ "$output" = "0" ]
  run env COPILOT_CLAUDE_MODEL=gpt-5.6-sol COPILOT_PROXY_QUIET=1 bash -c "$body"
  [ "$output" = "4" ]
}

# Claude Code's `/model` picker writes its selection to the user-level
# settings.json even when the proxy itself was injected only for one process.
# The launchers must clean that one key without rolling back unrelated settings.

@test "claude-copilot removes a proxy model persisted by the model picker" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' '{"pluginState":"before"}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test[1m]' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    source '$SHELL_LIB'
    copilot-run() {
      tmp=\"\$(mktemp)\"
      jq '.model = \"gpt-test[1m]\" | .pluginState = \"changed-during-session\"' \
        \"\$HOME/.claude/settings.json\" >\"\$tmp\" && mv \"\$tmp\" \"\$HOME/.claude/settings.json\"
    }
    claude-copilot --no-specstory"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("model")' "$TMP/home/.claude/settings.json")" = "false" ]
  [ "$(jq -r '.pluginState' "$TMP/home/.claude/settings.json")" = "changed-during-session" ]
  [[ "$output" == *"removed stale proxy model"* ]]
}

@test "claude-copilot restores a native default after proxy model persistence and keeps exit status" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' '{"model":"sonnet","other":1}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    source '$SHELL_LIB'
    copilot-run() {
      tmp=\"\$(mktemp)\"
      jq '.model = \"gpt-test\" | .other = 2' \"\$HOME/.claude/settings.json\" \
        >\"\$tmp\" && mv \"\$tmp\" \"\$HOME/.claude/settings.json\"
      return 7
    }
    claude-copilot --no-specstory"
  [ "$status" -eq 7 ]
  [ "$(jq -r '.model' "$TMP/home/.claude/settings.json")" = "sonnet" ]
  [ "$(jq -r '.other' "$TMP/home/.claude/settings.json")" = "2" ]
  [[ "$output" == *"restored native user model"* ]]
}

@test "claude-copilot leaves a native model deliberately selected during the session" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' '{"model":"sonnet","other":1}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    source '$SHELL_LIB'
    copilot-run() {
      tmp=\"\$(mktemp)\"
      jq '.model = \"opus\" | .other = 2' \"\$HOME/.claude/settings.json\" \
        >\"\$tmp\" && mv \"\$tmp\" \"\$HOME/.claude/settings.json\"
    }
    claude-copilot --no-specstory"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.model' "$TMP/home/.claude/settings.json")" = "opus" ]
  [ "$(jq -r '.other' "$TMP/home/.claude/settings.json")" = "2" ]
  [ -z "$output" ]
}

@test "claude-copilot --fast appends the discovered sibling for this session" {
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' 'gpt-test[1m]' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_fast_model_for() { printf '%s-fast\\n' \"\$1\"; }
    copilot-run() { printf 'launch=%s\\n' \"\$COPILOT_CLAUDE_MODEL\"; printf '<%s>\\n' \"\$@\"; }
    claude-copilot --no-specstory --fast --model gpt-explicit 'two words'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-copilot: --fast -> gpt-explicit-fast (session only)"* ]]
  [[ "$output" == *"launch=gpt-explicit-fast"* ]]
  [[ "$output" == *"<--model>"* ]]
  [[ "$output" == *"<gpt-explicit-fast>"* ]]
  [[ "$output" == *"<two words>"* ]]
  [ ! -e "$TMP/home/.claude/settings.json" ]
}

@test "claude-copilot --fast reuses a concrete once resolution" {
  run bash -c "
    source '$SHELL_LIB'
    _copilot_resolved_fast_for_once=gpt-cached-fast
    _copilot_fast_model_for() { printf called >>'$TMP/resolver-calls'; return 1; }
    _copilot_claude_launch_model() { printf '%s' gpt-cached-fast; }
    _copilot_assert_pinned_compact_safe() { return 0; }
    _copilot_model_guard_begin() { return 0; }
    _copilot_model_guard_restore() { return 0; }
    copilot-run() { printf '<%s>' "\$@"; printf '
'; }
    claude-copilot --no-specstory --fast"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--model><gpt-cached-fast>"* ]]
  [ ! -e "$TMP/resolver-calls" ]
}

@test "claude-copilot --fast falls back to the requested standard model" {
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_fast_model_for() { return 1; }
    copilot-run() { printf '<%s>\\n' \"\$@\"; }
    claude-copilot --fast --no-specstory --model gpt-explicit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-copilot: --fast unavailable for gpt-explicit; using the standard model."* ]]
  [ "$(printf '%s\n' "$output" | grep -c '<gpt-explicit>')" -eq 1 ]
}

@test "claude-copilot --fast refuses end-of-options before model injection" {
  run bash -c "source '$SHELL_LIB'; claude-copilot --fast -p -- --model-looking-prompt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--fast cannot be combined with '--'"* ]]

  run bash -c "source '$SHELL_LIB'; claude-copilot --fast --no-specstory --verbose --fast"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must come before other arguments"* ]]
}

@test "claude-copilot-once builds its temporary pin for the explicit launch model" {
  mkdir -p "$TMP/proj"
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_base() { printf '%s' 'http://localhost:4141'; }
    copilot-here() { printf 'pin=%s|%s\n' \"\$1\" \"\$2\"; }
    claude-copilot() { return 0; }
    claude-copilot-once --no-specstory --model gpt-5-mini"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pin=on|gpt-5-mini"* ]]
  [[ "$output" == *"pin=off|"* ]]
}

# --- --fast against an existing pin ---------------------------------------------
#
# `--fast` used to be handled ONLY in the not-yet-pinned branch, so a project
# already pinned to a fast model compared itself against the *global* default and
# always reported bogus drift ("gpt-5.6-sol-fast[1m] -> gpt-5.6-sol[1m]"), with
# `y` actively downgrading the pin off fast. The desired model is now computed
# before the pinned/unpinned split and fed to both.

# Write a pin whose env block is exactly what `copilot-here on $1` would produce.
write_pin() {
  mkdir -p "$TMP/proj/.claude"
  bash -c "source '$SHELL_LIB'
    _copilot_base() { printf '%s' 'http://localhost:4141'; }
    _copilot_fast_model_for() { case \"\$1\" in *-fast*) printf '%s' \"\$1\";; *'[1m]') printf '%s-fast[1m]' \"\${1%%'[1m]'}\";; *) printf '%s-fast' \"\$1\";; esac; }
    _copilot_model_catalog() { printf ''; }
    jq -n --argjson e \"\$(_copilot_env_json_for_model '$1')\" '{env: \$e}'" \
    > "$TMP/proj/.claude/settings.local.json"
}

# The stubs every drift test shares: no network, a deterministic fast sibling,
# and a global default that is deliberately the NON-fast model.
drift_env() {
  cat <<STUBS
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_base() { printf '%s' 'http://localhost:4141'; }
    _copilot_model_catalog() { printf ''; }
    _copilot_fast_model_for() { case "\$1" in *-fast*) printf '%s' "\$1";; *'[1m]') printf '%s-fast[1m]' "\${1%%'[1m]'}";; *) printf '%s-fast' "\$1";; esac; }
    _copilot_default_model() { printf '%s' 'gpt-5.6-sol[1m]'; }
    _copilot_confirm() { printf 'CONFIRM-ASKED\n'; return 1; }
    copilot-here() { printf 'pin=%s|%s\n' "\$1" "\$2"; }
    claude-copilot() { return 0; }
STUBS
}

@test "claude-copilot-once --fast does not report drift against its own fast pin" {
  write_pin 'gpt-5.6-sol-fast[1m]'
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    claude-copilot-once --fast --no-specstory"
  [ "$status" -eq 0 ]
  [[ "$output" != *"looks stale"* ]]
  [[ "$output" != *"CONFIRM-ASKED"* ]]
  [[ "$output" == *"already ON here"* ]]
}

@test "claude-copilot-once --fast offers the honest upgrade against a standard pin" {
  write_pin 'gpt-5.6-sol[1m]'
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    _copilot_confirm() { printf 'CONFIRM-ASKED\n'; return 0; }
    claude-copilot-once --fast --no-specstory"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks stale"* ]]
  [[ "$output" == *"gpt-5.6-sol[1m] -> gpt-5.6-sol-fast[1m]"* ]]
  # accepting must pin the FAST model, not re-pin the plain default
  [[ "$output" == *"pin=on|gpt-5.6-sol-fast[1m]"* ]]
}

@test "claude-copilot-once without --fast still surfaces a stale fast pin" {
  # Crash residue: there is no EXIT trap by design, so a killed session can leave
  # a fast pin behind. Without --fast the sol-fast -> sol diff is TRUE, and
  # accepting it correctly downgrades.
  write_pin 'gpt-5.6-sol-fast[1m]'
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    _copilot_confirm() { printf 'CONFIRM-ASKED\n'; return 0; }
    claude-copilot-once --no-specstory"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks stale"* ]]
  [[ "$output" == *"gpt-5.6-sol-fast[1m] -> gpt-5.6-sol[1m]"* ]]
  [[ "$output" == *"pin=on|"* ]]
}

@test "claude-copilot-once explains what declining a --fast refresh leaves behind" {
  write_pin 'gpt-5.6-sol[1m]'
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    claude-copilot-once --fast --no-specstory"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept the existing pin"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_* role models stay on the non-fast ids"* ]]
}

@test "claude-copilot-once takes --fast only as a leading option" {
  # A literal --fast inside a prompt string must not pin the fast model, and a
  # late --fast is refused instead of silently differing from claude-copilot.
  mkdir -p "$TMP/proj"
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    claude-copilot-once --no-specstory -p 'compare --fast and slow'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pin=on|"* ]]
  [[ "$output" != *"pin=on|gpt-5.6-sol-fast"* ]]
  [[ "$output" != *"must come before"* ]]

  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    claude-copilot-once --no-specstory --resume abc --fast"
  [ "$status" -eq 2 ]
  [[ "$output" == *"'--fast' must come before other arguments"* ]]
  [[ "$output" != *"session ended"* ]]

  # After -- it is prompt/data, not the wrapper option.
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    $(drift_env)
    claude-copilot-once --no-specstory -p -- --fast"
  [ "$status" -eq 0 ]
  [[ "$output" != *"must come before"* ]]
}

# --- permission posture on the raw (--no-specstory) path -------------------------
#
# Bypass used to come only from specstory's `claude_cmd`, so --no-specstory
# silently dropped to ~/.claude/settings.json's defaultMode: same wrapper,
# opposite permission mode, no warning.

perm_run() {
  bash -c '''
    source "$1"; shift
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    copilot-run() { printf "<%s>" "$@"; printf "\n"; }
    claude-copilot "$@"
  ''' _ "$SHELL_LIB" "$@"
}

@test "configured-command bypass scrubber never mutates quoted prompt data" {
  run bash -c '
    source "$1"
    _copilot_claude_drop_bypass_token "$2"
    _copilot_claude_drop_bypass_token "$3"
  ' _ "$SHELL_LIB" \
    'claude --dangerously-skip-permissions' \
    'claude --append-system-prompt "--dangerously-skip-permissions"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude" ]
  [ "${lines[1]}" = 'claude --append-system-prompt "--dangerously-skip-permissions"' ]

  run bash -c 'source "$1"; _copilot_claude_drop_bypass_token "$2"' \
    _ "$SHELL_LIB" \
    'claude --append-system-prompt "explain --dangerously-skip-permissions safely" --dangerously-skip-permissions --verbose'
  [ "$status" -eq 0 ]
  [ "$output" = 'claude --append-system-prompt "explain --dangerously-skip-permissions safely" --dangerously-skip-permissions --verbose' ]
}

@test "claude-copilot SpecStory path lets an explicit permission mode replace seeded bypass" {
  mkdir -p "$TMP/bin" "$TMP/home"
  printf '#!/bin/sh\n' > "$TMP/bin/specstory"
  chmod +x "$TMP/bin/specstory"
  run env HOME="$TMP/home" PATH="$TMP/bin:$PATH" COPILOT_CLAUDE_MODEL=gpt-5.6-sol bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_claude_launch_model() { printf '%s' gpt-5.6-sol; }
    _copilot_assert_pinned_compact_safe() { return 0; }
    _copilot_model_guard_begin() { return 0; }
    _copilot_model_guard_restore() { return 0; }
    _copilot_specstory_claude_cmd() { printf '%s' 'claude --dangerously-skip-permissions'; }
    copilot-run() { printf '<%s>' \"\$@\"; printf '\n'; }
    claude-copilot --permission-mode plan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--permission-mode"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "claude-copilot SpecStory path asserts bypass for a custom command" {
  mkdir -p "$TMP/bin" "$TMP/home"
  printf '#!/bin/sh\n' > "$TMP/bin/specstory"
  chmod +x "$TMP/bin/specstory"
  run env HOME="$TMP/home" PATH="$TMP/bin:$PATH" COPILOT_CLAUDE_MODEL=gpt-5.6-sol bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_claude_launch_model() { printf '%s' gpt-5.6-sol; }
    _copilot_assert_pinned_compact_safe() { return 0; }
    _copilot_model_guard_begin() { return 0; }
    _copilot_model_guard_restore() { return 0; }
    _copilot_specstory_claude_cmd() { printf '%s' 'claude --verbose'; }
    copilot-run() { printf '<%s>' \"\$@\"; printf '\n'; }
    claude-copilot --resume session-id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude --verbose --dangerously-skip-permissions"* ]]
  [[ "$output" == *"--resume"* ]]

  run env HOME="$TMP/home" PATH="$TMP/bin:$PATH" COPILOT_CLAUDE_MODEL=gpt-5.6-sol bash -c "
    source '$SHELL_LIB'
    _copilot_alive() { return 0; }
    _copilot_claude_launch_model() { printf '%s' gpt-5.6-sol; }
    _copilot_assert_pinned_compact_safe() { return 0; }
    _copilot_model_guard_begin() { return 0; }
    _copilot_model_guard_restore() { return 0; }
    _copilot_specstory_claude_cmd() { printf '%s' 'claude --verbose'; }
    copilot-run() { printf '<%s>' \"\$@\"; printf '\n'; }
    claude-copilot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<-c><claude --verbose --dangerously-skip-permissions>"* ]]
}

@test "claude-copilot --no-specstory asserts the same permission posture" {
  run perm_run --no-specstory
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--dangerously-skip-permissions>"* ]]
}

@test "claude-copilot --no-specstory does not duplicate an explicit bypass" {
  run perm_run --no-specstory --dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -o -- '--dangerously-skip-permissions' | wc -l | tr -d ' ')" = "1" ]
}

@test "claude-copilot --no-specstory yields to an explicit --permission-mode" {
  run perm_run --no-specstory --permission-mode plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--permission-mode>"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "claude permission detection never treats prompt data as an option" {
  run perm_run --no-specstory -p -- --permission-mode=plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--dangerously-skip-permissions>"* ]]

  run perm_run --no-specstory -p --permission-mode=plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--permission-mode=plan>"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]

  run perm_run --no-specstory --restricted
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--restricted>"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]

  run perm_run --no-specstory --permission-prompts none
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--permission-prompts><none>"* ]]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]

  run perm_run --no-specstory --allow-dangerously-skip-permissions
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--allow-dangerously-skip-permissions>"* ]]
  # --allow... enables bypass as a possible mode; it does not select a
  # different active posture, so the wrapper's bypass default still applies.
  [[ "$output" == *"<--dangerously-skip-permissions>"* ]]
}

codex_perm_run() {
  bash -c '''
    source "$1"; shift
    _copilot_alive() { return 0; }
    _copilot_require_shim() { return 0; }
    _copilot_model_catalog() { printf ""; }
    codex() { printf "<%s>" "$@"; printf "\n"; }
    command() { if [ "$1" = env ]; then shift 2; codex "$@"; else builtin command "$@"; fi; }
    codex-copilot "$@"
  ''' _ "$SHELL_LIB" "$@"
}

@test "codex-copilot --no-specstory asserts the same approval posture" {
  run codex_perm_run --no-specstory -m gpt-5.6-sol
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--ask-for-approval><never>"* ]]
  [[ "$output" == *"<--sandbox><danger-full-access>"* ]]
}

@test "codex-copilot --no-specstory yields to an explicit approval policy" {
  run codex_perm_run --no-specstory -m gpt-5.6-sol --ask-for-approval untrusted
  [ "$status" -eq 0 ]
  [[ "$output" != *"<never>"* ]]
  [[ "$output" == *"<untrusted>"* ]]
}

@test "codex approval and sandbox defaults are independent axes" {
  run codex_perm_run --no-specstory -m gpt-5.6-sol --sandbox read-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--ask-for-approval><never>"* ]]
  [[ "$output" == *"<--sandbox><read-only>"* ]]
  [[ "$output" != *"<danger-full-access>"* ]]

  run codex_perm_run --no-specstory -m gpt-5.6-sol --ask-for-approval untrusted
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--sandbox><danger-full-access>"* ]]
  [[ "$output" != *"<never>"* ]]

  run codex_perm_run --no-specstory -m gpt-5.6-sol -s read-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"<-s><read-only>"* ]]
  [[ "$output" != *"<danger-full-access>"* ]]

  run codex_perm_run --no-specstory -m gpt-5.6-sol --approve-for-me
  [ "$status" -eq 0 ]
  [[ "$output" == *"<--approve-for-me>"* ]]
  [[ "$output" != *"<never>"* ]]
  [[ "$output" != *"<danger-full-access>"* ]]
}

@test "copilot-here off cleans stale user model even when no local pin exists" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy" "$TMP/proj"
  printf '%s\n' '{"model":"gpt-test","other":1}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    cd '$TMP/proj'
    source '$SHELL_LIB'
    copilot-here off"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("model")' "$TMP/home/.claude/settings.json")" = "false" ]
  [ "$(jq -r '.other' "$TMP/home/.claude/settings.json")" = "1" ]
  [[ "$output" == *"removed stale proxy model"* ]]
  [[ "$output" == *"already off"* ]]
}

@test "copilot-here off preserves an explicit native Claude 1M user model" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy" "$TMP/proj"
  printf '%s\n' '{"model":"claude-opus-5[1m]","other":1}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" bash -c "
    cd '$TMP/proj'
    source '$SHELL_LIB'
    copilot-here off"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.model' "$TMP/home/.claude/settings.json")" = "claude-opus-5[1m]" ]
  [ "$(jq -r '.other' "$TMP/home/.claude/settings.json")" = "1" ]
  [[ "$output" != *"removed stale proxy model"* ]]
}

@test "copilot-here status audits every Claude settings layer and effective launch" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy" "$TMP/proj/.claude"
  printf '%s\n' '{"model":"sonnet"}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' '{"plansDirectory":"./.claude/plans"}' > "$TMP/proj/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
    ANTHROPIC_BASE_URL= ANTHROPIC_AUTH_TOKEN= ANTHROPIC_MODEL= COPILOT_CLAUDE_MODEL= bash -c "
    cd '$TMP/proj'
    source '$SHELL_LIB'
    copilot-here status"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Plain Claude launch audit"* ]]
  [[ "$output" == *"user settings"*"model=sonnet"* ]]
  [[ "$output" == *"project settings"*"model=unset"* ]]
  [[ "$output" == *"local settings"*"model=unset"* ]]
  [[ "$output" == *"effective backend Anthropic"* ]]
  [[ "$output" == *"effective model  sonnet"* ]]
}

@test "Claude launch audit warns on a native backend with proxy-only user model" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  mkdir -p "$TMP/home/.claude" "$TMP/state/copilot-proxy" "$TMP/proj"
  printf '%s\n' '{"model":"gpt-test"}' > "$TMP/home/.claude/settings.json"
  printf '%s\n' 'gpt-test' > "$TMP/state/copilot-proxy/model"

  run env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
    ANTHROPIC_BASE_URL= ANTHROPIC_AUTH_TOKEN= ANTHROPIC_MODEL= COPILOT_CLAUDE_MODEL= bash -c "
    cd '$TMP/proj'
    source '$SHELL_LIB'
    _copilot_claude_launch_report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"effective backend Anthropic"* ]]
  [[ "$output" == *"effective model  gpt-test"* ]]
  [[ "$output" == *"native Anthropic backend with a proxy-only model default"* ]]
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

@test "Responses shim derives fast siblings and translates Codex fast tiers" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "import { buildFastModelMappings as b, normalizeRequestBody as n } from '$shim';
    const catalog={data:[
      {id:'gpt-test',claude_model_id:'gpt-test[1m]',capabilities:{type:'chat',supports:{responses:true}}},
      {id:'gpt-test-fast',claude_model_id:'gpt-test-fast[1m]',capabilities:{type:'chat',supports:{responses:true}}},
      {id:'gpt-hidden-fast',model_picker_enabled:false,capabilities:{type:'chat',supports:{responses:true}}},
      {id:'gpt-hidden',capabilities:{type:'chat',supports:{responses:true}}},
    ]};
    const mappings=b(catalog);
    const enc=(o)=>new TextEncoder().encode(JSON.stringify(o)).buffer;
    const decode=(r)=>typeof r.body==='string'?JSON.parse(r.body):JSON.parse(new TextDecoder().decode(r.body));
    const fast=n('/v1/responses',enc({model:'gpt-test',service_tier:'fast'}),'',mappings);
    const priority=n('/responses',enc({model:'gpt-test[1m]',service_tier:'priority'}),'',mappings);
    const ultra=n('/responses',enc({model:'gpt-test',service_tier:'ultrafast'}),'',mappings);
    const normal=n('/responses',enc({model:'gpt-test'}),'',mappings);
    console.log(JSON.stringify({mappings,fast:{p:decode(fast),r:fast.routing},priority:{p:decode(priority),r:priority.routing},ultra:{p:decode(ultra),r:ultra.routing},normalChanged:normal.changed}));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mappings["gpt-test"]')" = "gpt-test-fast" ]
  [ "$(printf '%s' "$output" | jq -r '.mappings["gpt-test[1m]"]')" = "gpt-test-fast[1m]" ]
  [ "$(printf '%s' "$output" | jq -r '.mappings | has("gpt-hidden")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.fast.p.model')" = "gpt-test-fast" ]
  [ "$(printf '%s' "$output" | jq -r '.fast.p | has("service_tier")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.priority.p.model')" = "gpt-test-fast[1m]" ]
  [ "$(printf '%s' "$output" | jq -r '.ultra.p.model')" = "gpt-test" ]
  [ "$(printf '%s' "$output" | jq -r '.ultra.r.fallback')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.normalChanged')" = "0" ]
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

@test "adaptive limiter ramps under queue pressure, backs off on throttle, and supports live reset" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  run bun -e "
    let now=0; const changes=[];
    const {createAdaptiveLimiter}=await import('$shim');
    const l=createAdaptiveLimiter({min:4,max:6,successThreshold:2,increaseIntervalMs:100,
      throttleCooldownMs:500,clock:()=>now,onChange:(c)=>changes.push(c)});
    l.noteQueued(); now=100; l.observeStatus(200,true); l.observeStatus(200,true);
    const raised=l.snapshot();
    now=150; l.observeStatus(429,true); const throttled=l.snapshot();
    now=700; l.noteQueued(); l.observeStatus(200,true); l.observeStatus(200,true);
    const recovered=l.snapshot();
    const configured=l.configure({min:5,max:7,limit:6});
    const reset=l.reset();
    console.log(JSON.stringify({raised,throttled,recovered,configured,reset,changes}));"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.raised.limit')" = "5" ]
  [ "$(printf '%s' "$output" | jq -r '.throttled.limit')" = "4" ]
  [ "$(printf '%s' "$output" | jq -r '.throttled.last_throttle_status')" = "429" ]
  [ "$(printf '%s' "$output" | jq -r '.recovered.limit')" = "5" ]
  [ "$(printf '%s' "$output" | jq -r '.configured | [.min,.max,.limit] | join(",")')" = "5,7,6" ]
  [ "$(printf '%s' "$output" | jq -r '.reset | [.min,.max,.limit] | join(",")')" = "4,6,4" ]
}

@test "shim limiter config endpoint is readable and loopback-admin writable" {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local shim="$SOURCE_DIR/dot_config/shell/copilot-throttle-shim.js"
  cat >"$TMP/limiter-live.js" <<'JS'
process.env.COPILOT_SHIM_PORT = "0";
process.env.COPILOT_SHIM_MIN = "2";
process.env.COPILOT_SHIM_MAX = "5";
process.env.COPILOT_SHIM_METRICS_DB = process.argv[3];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const upstream = Bun.serve({ port: 0, async fetch() {
  await sleep(250);
  return Response.json({ ok: true });
} });
process.env.COPILOT_SHIM_UPSTREAM = `http://127.0.0.1:${upstream.port}`;
const { startServer } = await import(process.argv[2]);
const shim = startServer();
const base = `http://127.0.0.1:${shim.port}/_shim/config`;
const read = await (await fetch(base)).json();
const denied = await fetch(base, { method: "PATCH", headers: { "content-type": "application/json" }, body: '{"limit":3}' });
const changed = await (await fetch(base, { method: "PATCH", headers: {
  "content-type": "application/json", "x-copilot-shim-admin": "1",
}, body: '{"min":3,"max":6,"limit":5}' })).json();
const calls = Array.from({length:4}, () => fetch(`http://127.0.0.1:${shim.port}/probe`, {
  method: "POST", headers: {"content-type":"application/json"},
  body: '{"model":"m","stream":false}',
}));
await sleep(50);
const lowered = await (await fetch(base, { method: "PATCH", headers: {
  "content-type": "application/json", "x-copilot-shim-admin": "1",
}, body: '{"min":1,"limit":1}' })).json();
const statuses = await Promise.all(calls).then((rows) => rows.map((row) => row.status));
const reset = await (await fetch(base, { method: "PATCH", headers: {
  "content-type": "application/json", "x-copilot-shim-admin": "1",
}, body: '{"reset":true}' })).json();
console.log(JSON.stringify({read,denied:denied.status,changed,lowered,statuses,reset}));
shim.stop(true);
upstream.stop(true);
JS
  run bash -c "bun '$TMP/limiter-live.js' '$shim' '$TMP/limiter-live.sqlite' 2>&1 | tail -n 1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.read | [.min,.max,.limit] | join(",")')" = "2,5,2" ]
  [ "$(printf '%s' "$output" | jq -r '.denied')" = "403" ]
  [ "$(printf '%s' "$output" | jq -r '.changed | [.min,.max,.limit] | join(",")')" = "3,6,5" ]
  [ "$(printf '%s' "$output" | jq -r '.lowered | [.active,.limit] | join(",")')" = "4,1" ]
  [ "$(printf '%s' "$output" | jq -r '.statuses | unique | join(",")')" = "200" ]
  [ "$(printf '%s' "$output" | jq -r '.reset | [.min,.max,.limit] | join(",")')" = "2,5,2" ]
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
  [ "$(printf '%s' "$output" | jq -r '.retry408Replay.attempts')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.retry.events | join(",")')" = "message_start,message_stop" ]
  [ "$(printf '%s' "$output" | jq -r '.cancelBarrier.waited')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cancelBarrier.settled')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.exhausted.events | last')" = "response.failed" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status400')" = "invalid_prompt" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status401')" = "invalid_prompt" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status402')" = "insufficient_quota" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status422')" = "invalid_prompt" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status429')" = "rate_limit_exceeded" ]
  [ "$(printf '%s' "$output" | jq -r '.responseCodes.status500')" = "server_error" ]
  [ "$(printf '%s' "$output" | jq -r '.counts["/v1/responses:status429"]')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.nonSse.events | last')" = "error" ]
  [ "$(printf '%s' "$output" | jq -r '.fastNonSse.status')" = "502" ]
  [ "$(printf '%s' "$output" | jq -r '.mixedSse.events | join(",")')" = "message_start,message_stop" ]
  [ "$(printf '%s' "$output" | jq -r '.truncated.events | join(",")')" = "response.created" ]
  [ "$(printf '%s' "$output" | jq -r '.billing.status')" = "402" ]
  [ "$(printf '%s' "$output" | jq -r '.stalled.elapsed_ms < 4000')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.activeAbortResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.deadResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.backoffResult')" = "AbortError" ]
  [ "$(printf '%s' "$output" | jq -r '.cancellation.backoffReleaseMs < 1000')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cleanupFailures.metricFailureContained')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.fastRoute.forwarded.model')" = "gpt-fixture-fast" ]
  [ "$(printf '%s' "$output" | jq -r '.fastRoute.forwarded | has("service_tier")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.counts["/v1/messages:backoff"]')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "retry500" and .attempts == 2 and .retries == 1 and .error_kind == null)] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "nonsse" and .error_kind == "upstream_protocol")] | length')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "truncated" and .error_kind == "upstream_protocol_eof")] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "activeabort" and .attempts == 1 and .status == 499 and .error_kind == "client_cancel")] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "dead" and .attempts == 0 and .error_kind == "client_cancel")] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.metrics[] | select(.model == "gpt-fixture-fast" and .status == 200)] | length')" = "1" ]
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
  [ "$(printf '%s\n' "$output" | head -n1 | jq -r '.client_cancels')" = "0" ]
  [ "$(printf '%s\n' "$output" | head -n1 | jq -r '.upstream_errors')" = "0" ]
  [[ "$output" == *"no matching requests"* ]]
}

@test "copilot-proxy logs follows current files and preserves rotated-log syntax" {
  mkdir -p "$TMP/bin"
  printf '%s\n' '#!/bin/sh' 'printf "tail"; for arg do printf "|%s" "$arg"; done; printf "\n"' >"$TMP/bin/tail"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$TMP/bin/bun"
  chmod +x "$TMP/bin/tail" "$TMP/bin/bun"
  : >"$TMP/proxy.log"; : >"$TMP/proxy.log.1"; : >"$TMP/shim.log"
  run bash -c "PATH='$TMP/bin:/usr/bin:/bin'; source '$SHELL_LIB';
    _copilot_logfile() { printf '%s' '$TMP/proxy.log'; }
    _copilot_shim_logfile() { printf '%s' '$TMP/shim.log'; }
    copilot-proxy logs -f 60
    copilot-proxy logs shim --follow 20
    copilot-proxy logs 40 1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "tail|-n|60|-F|$TMP/proxy.log" ]
  [ "$(printf '%s\n' "$output" | sed -n '2p')" = "tail|-n|20|-F|$TMP/shim.log" ]
  [ "$(printf '%s\n' "$output" | sed -n '3p')" = "tail|-n|40|$TMP/proxy.log.1" ]

  run bash -c "source '$SHELL_LIB'; _copilot_logfile() { printf '%s' '$TMP/proxy.log'; }; copilot-proxy logs -f 40 1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot follow a rotated generation"* ]]
}

@test "copilot-proxy limiter builds live PATCH payloads without persisting state" {
  run bash -c "source '$SHELL_LIB';
    _copilot_shim_alive() { return 0; }
    _copilot_limiter_request() { printf '{\"limit\":6,\"min\":4,\"max\":8,\"active\":3,\"queued\":1,\"adaptive\":true,\"cooldown_ms_remaining\":0,\"successes_to_increase\":12,\"throttle_events\":0,\"last_throttle_status\":null}'; }
    copilot-proxy limiter set --min 4 --max 8 --limit 6"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed '/^copilot-proxy:/d' | jq -r '.limit')" = "6" ]
  [[ "$output" == *"process only"* ]]
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

@test "pick_best_model: Sol is the strongest OpenAI fallback (offline, no catalog)" {
  run bash -c "printf '%s\n' gpt-5.3-codex gpt-5.6-luna gpt-5.5 gpt-5.6-terra gpt-5.6-sol \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "pick_best_model: old flagships outrank lightweight Luna (offline, no catalog)" {
  run bash -c "printf '%s\n' gpt-5.6-luna gpt-5.4-mini gpt-5.3-codex gpt-5.4 gpt-5.5 \
    | { source '$SHELL_LIB'; _copilot_pick_best_model; }"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]
}

# --- capability-tier ranking ---------------------------------------------------
#
# The catalog's `model_picker_category` is Copilot's own tier taxonomy and lines
# up with OpenAI's DURABLE tiers (Sol/Astra = powerful, Terra = versatile, Luna =
# lightweight). Generation and tier advance independently — gpt-6-astra is the
# gen-6 flagship while Terra and Luna stayed on 5.6 — so ranking on the version
# alone would promote a future gpt-6-luna over gpt-5.6-sol. These tests pin that
# down; `tier_cat` below builds a catalog of `id:category` pairs.

tier_cat() {
  local first=1 pair id cat
  printf '{"data":['
  for pair in "$@"; do
    id="${pair%%:*}"; cat="${pair#*:}"
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"id":"%s","model_picker_category":"%s","capabilities":{"type":"chat"}}' "$id" "$cat"
  done
  printf ']}'
}

# Rank a catalog through the real ranker, feeding it its own selectable ids.
tier_rank() {
  local fn="$1"; shift
  local cat; cat="$(tier_cat "$@")"
  bash -c "source '$SHELL_LIB'
    cat='$cat'
    printf '%s\n' \"\$(printf '%s' \"\$cat\" | _copilot_selectable_ids)\" | $fn \"\$cat\""
}

@test "tier ranking: a newer flagship wins even before it reaches the allowlist" {
  # gpt-7-helios stands in for "the next family we have not curated yet".
  run tier_rank _copilot_pick_best_model \
    gpt-7-helios:powerful gpt-6-astra:powerful gpt-5.6-sol:powerful gpt-5.6-terra:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-7-helios" ]
}

@test "tier ranking: gpt-6-astra is picked over gpt-5.6-sol" {
  run tier_rank _copilot_pick_best_model \
    gpt-6-astra:powerful gpt-5.6-sol:powerful gpt-5.6-terra:versatile gpt-5.6-luna:lightweight
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]
}

@test "tier ranking: a newer LIGHTWEIGHT never displaces a served flagship" {
  # The regression that a version-only pre-pass would cause. gpt-6-luna is
  # newer than gpt-5.6-sol but a whole tier below it.
  run tier_rank _copilot_pick_best_model gpt-6-luna:lightweight gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "tier ranking: a newer VERSATILE never displaces a served flagship" {
  run tier_rank _copilot_pick_best_model gpt-6-terra:versatile gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "tier ranking: an unknown same-generation sibling loses to the curated pick" {
  # gpt-6-nova sorts after gpt-6-astra under `sort -V` purely on its codename,
  # so the pre-pass must compare GENERATIONS, not ids.
  run tier_rank _copilot_pick_best_model \
    gpt-6-nova:powerful gpt-6-astra:powerful gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]
}

@test "tier ranking: a -fast sibling is never selected as the main model" {
  # gpt-5.6-sol-fast is picker-enabled AND inherits `powerful`, so only the
  # explicit -fast exclusion keeps it out. --fast is a separate, session axis.
  run tier_rank _copilot_pick_best_model gpt-5.6-sol-fast:powerful gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "tier ranking: partial category coverage degrades instead of promoting a lower tier" {
  # Sol deliberately lacks category metadata while the hypothetical newer Luna
  # has it. The pre-pass must stand down; partial metadata is not evidence that
  # Luna is the best model in the vendor.
  run tier_rank _copilot_pick_best_model gpt-7-luna:lightweight gpt-5.6-sol:
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "tier ranking: generation comes from the model slot, not any later number" {
  run tier_rank _copilot_pick_best_model gpt-oss-120b:powerful gpt-6-astra:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]
}

@test "tier ranking: generation precedes Claude family spelling inside one tier" {
  run tier_rank _copilot_pick_best_model \
    claude-fable-6:powerful claude-opus-5:powerful claude-fable-5:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "claude-fable-6" ]
}

@test "tier prepass ignores newer known models from a lower tier" {
  cat_json="$(tier_cat gpt-7-helios:powerful gpt-5-legacy:powerful gpt-8-luna:lightweight)"
  run env TEST_CATALOG="$cat_json" bash -c "source '$SHELL_LIB'
    models=\$(printf '%s' \"\$TEST_CATALOG\" | _copilot_selectable_ids)
    rows=\$(printf '%s' \"\$TEST_CATALOG\" | _copilot_tier_rows | _copilot_tier_rows_for_ids \"\$models\")
    _copilot_tier_prepass '^gpt-' \"\$rows\" \"\$models\" gpt-8-luna gpt-5-legacy"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-7-helios" ]
}

@test "tier ranking: a catalog without the category degrades to the allowlist" {
  # An older fork that does not report model_picker_category must leave the
  # historical ranker untouched rather than guessing.
  run tier_rank _copilot_pick_best_model gpt-6-astra: gpt-5.6-sol: gpt-5.6-terra:
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]   # from the allowlist head, not the pre-pass
}

@test "tier ranking: Claude keeps Opus when only a newer lower tier appears" {
  run tier_rank _copilot_pick_best_model \
    claude-haiku-6:lightweight claude-opus-5:powerful claude-sonnet-5:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]
}

@test "tier ranking: Grok fallback prefers a parsed generation over lexical code names" {
  cat_json='{"data":[
    {"id":"grok-code-fast-1","capabilities":{"type":"chat"}},
    {"id":"grok-4.6","capabilities":{"type":"chat"}}]}'
  run env TEST_CATALOG="$cat_json" bash -c "source '$SHELL_LIB'
    printf '%s' \"\$TEST_CATALOG\" | _copilot_selectable_ids \\
      | _copilot_pick_best_model \"\$TEST_CATALOG\""
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6" ]
}

@test "tier ranking: grok is selected with no allowlist, newest version first" {
  run tier_rank _copilot_pick_best_model grok-4.5:versatile grok-4.6:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6" ]
}

@test "Raycast rank keeps lightweight new ids below powerful older ids" {
  raycast_lib="$SOURCE_DIR/dot_config/shell/45_copilot_raycast.sh"
  run bash -c '
    source "$1"
    printf "%s %s %s %s" \
      "$(_copilot_raycast_rank gpt-5.6-sol powerful)" \
      "$(_copilot_raycast_rank gpt-6-luna lightweight)" \
      "$(_copilot_raycast_rank grok-5 powerful)" \
      "$(_copilot_raycast_rank grok-6-lite lightweight)"
  ' _ "$raycast_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "39 34 32 29" ]

  run bash -c 'source "$1"; printf "%s %s" "$(_copilot_raycast_rank claude-fable-5 powerful)" "$(_copilot_raycast_rank claude-haiku-4-5 lightweight)"' _ "$raycast_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "60 57" ]

  run bash -c 'source "$1"; _copilot_raycast_temp o5' _ "$raycast_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "tier ranking: o-series reasoning models stay in the OpenAI arm" {
  run tier_rank _copilot_pick_best_model o4:powerful gemini-10-pro:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "o4" ]

  run tier_rank _copilot_codex_pick_best_model o4:powerful claude-opus-5:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "o4" ]
}

@test "tier ranking: grok outranks Gemini but loses to OpenAI" {
  run tier_rank _copilot_pick_best_model \
    grok-4.6:versatile gemini-3.8-flash:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6" ]

  run tier_rank _copilot_pick_best_model \
    grok-4.6:versatile gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "tier ranking: Gemini and remaining vendors honor catalog tier before version" {
  # A newer lightweight must not beat an older powerful model in the same vendor.
  run tier_rank _copilot_pick_best_model \
    gemini-10-flash:lightweight gemini-9-pro:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gemini-9-pro" ]

  run tier_rank _copilot_pick_best_model \
    mai-code-2.0-flash:lightweight mai-code-1.1:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "mai-code-1.1" ]
}

@test "tier ranking: a sole -fast id is rejected instead of re-entering a lexical fallback" {
  run tier_rank _copilot_pick_best_model gpt-5.6-sol-fast:powerful
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  run tier_rank _copilot_codex_pick_best_model gpt-5.6-sol-fast:powerful
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "tier ranking: the Codex ranker keeps OpenAI first and grok before Gemini" {
  run tier_rank _copilot_codex_pick_best_model \
    claude-opus-5:powerful gpt-5.6-sol:powerful
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]

  run tier_rank _copilot_codex_pick_best_model \
    claude-opus-5:powerful grok-4.6:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]

  run tier_rank _copilot_codex_pick_best_model \
    grok-4.6:versatile gemini-3.8-flash:versatile
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6" ]
}

@test "tier ranking never widens beyond the candidate ids on stdin" {
  cat_json="$(tier_cat gpt-7-helios:powerful gpt-5.6-sol:powerful)"
  run env TEST_CATALOG="$cat_json" bash -c "source '$SHELL_LIB'
    printf '%s\n' gpt-5.6-sol | _copilot_pick_best_model \"\$TEST_CATALOG\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol" ]
}

@test "claude model argument parser ignores only explicit prompt data" {
  run bash -c "source '$SHELL_LIB'
    printf '<%s>\n' \"\$(_copilot_claude_model_arg -p -- --model=gpt-prompt)\"
    printf '<%s>\n' \"\$(_copilot_claude_model_arg -p hello --model gpt-real)\"
    printf '<%s>\n' \"\$(_copilot_claude_model_arg -p --model gpt-option)\""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "<>" ]
  [ "${lines[1]}" = "<gpt-real>" ]
  [ "${lines[2]}" = "<gpt-option>" ]
}

@test "model_version: generation parsing survives every vendor's spelling" {
  run bash -c "source '$SHELL_LIB'
    for m in gpt-6-astra gpt-6-nova gpt-5.6-sol claude-opus-4-8 claude-opus-5 grok-4.6 mai-code-1.1-flash; do
      printf '%s=%s ' \"\$m\" \"\$(_copilot_model_version \"\$m\")\"
    done"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra=6 gpt-6-nova=6 gpt-5.6-sol=5.6 claude-opus-4-8=4.8 claude-opus-5=5 grok-4.6=4.6 mai-code-1.1-flash=1.1 " ]
}

@test "entitlement baseline falls through a base-only partial project pin" {
  mkdir -p "$TMP/proj/.claude" "$TMP/state/copilot-proxy"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4142"}}' \
    > "$TMP/proj/.claude/settings.local.json"
  printf '%s\n' 'gpt-state' > "$TMP/state/copilot-proxy/model"
  run env XDG_STATE_HOME="$TMP/state" COPILOT_CLAUDE_MODEL=gpt-env bash -c "
    cd '$TMP/proj'; source '$SHELL_LIB'; _copilot_entitlement_baseline_model"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-env" ]
}

@test "auto candidates never narrow the persisted model's advertised plan set" {
  catalog='{"data":[
    {"id":"gpt-6-astra","billing":{"restricted_to":["pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-sol","billing":{"restricted_to":["pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-terra","billing":{"restricted_to":["pro","pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-luna","billing":{"restricted_to":["free","edu","pro","pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5-mini","capabilities":{"type":"chat"}}]}'

  run env TEST_CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    printf '%s' \"\$TEST_CATALOG\" | _copilot_auto_candidate_ids gpt-5.6-terra"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gpt-6-astra"* ]]
  [[ "$output" != *"gpt-5.6-sol"* ]]
  [[ "$output" == *"gpt-5.6-terra"* ]]

  run env TEST_CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    ids=\$(printf '%s' \"\$TEST_CATALOG\" | _copilot_auto_candidate_ids gpt-5.6-sol)
    printf '%s\\n' \"\$ids\" | _copilot_pick_best_model \"\$TEST_CATALOG\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]

  run env TEST_CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    ids=\$(printf '%s' \"\$TEST_CATALOG\" | _copilot_auto_candidate_ids '')
    printf '%s\\n' \"\$ids\" | _copilot_pick_best_model \"\$TEST_CATALOG\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-luna" ]
}

@test "auto candidates use a fast sibling as the entitlement baseline" {
  catalog='{"data":[
    {"id":"gpt-6-astra","billing":{"restricted_to":["pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-sol","billing":{"restricted_to":["pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-sol-fast","billing":{"restricted_to":["pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}},
    {"id":"gpt-5.6-luna","billing":{"restricted_to":["free","pro","pro_plus","business","enterprise","max"]},"capabilities":{"type":"chat"}}]}'
  run env TEST_CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    ids=\$(printf '%s' \"\$TEST_CATALOG\" | _copilot_auto_candidate_ids gpt-5.6-sol-fast)
    printf '%s\\n' \"\$ids\" | _copilot_pick_best_model \"\$TEST_CATALOG\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-6-astra" ]
}

@test "selectable_ids drops embeddings, disabled policy and picker-hidden models" {
  cat_json='{"data":[
    {"id":"gpt-5.6-sol","capabilities":{"type":"chat"}},
    {"id":"text-embedding-3-small","capabilities":{"type":"embeddings"}},
    {"id":"gpt-blocked","capabilities":{"type":"chat"},"policy":{"state":"disabled"}},
    {"id":"gpt-hidden","capabilities":{"type":"chat"},"model_picker_enabled":false}]}'
  run bash -c "source '$SHELL_LIB'; printf '%s' '$cat_json' | _copilot_selectable_ids | tr '\n' ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol " ]
}

@test "model profile: grok roles are derived from the tier rows" {
  cat_json="$(tier_cat grok-4.6:versatile grok-3-mini:lightweight)"
  run bash -c "source '$SHELL_LIB'; _copilot_model_profile_json 'grok-4.6' '$cat_json' | jq -r '.sonnet + \" \" + .haiku'"
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6 grok-3-mini" ]
}

@test "model profile: Grok fast sibling does not invalidate complete role tiers" {
  cat_json='{"data":[
    {"id":"grok-4.6","model_picker_category":"versatile","capabilities":{"type":"chat"}},
    {"id":"grok-4.6-fast","model_picker_category":"versatile","capabilities":{"type":"chat"}},
    {"id":"grok-3-mini","model_picker_category":"lightweight","capabilities":{"type":"chat"}}]}'
  run env TEST_CATALOG="$cat_json" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json grok-4.6 \"\$TEST_CATALOG\" | jq -r '.sonnet + \" \" + .haiku'"
  [ "$status" -eq 0 ]
  [ "$output" = "grok-4.6 grok-3-mini" ]
}

@test "model_for_claude: context metadata controls the [1m] hint" {
  local catalog='{"data":[{"id":"gpt-large","capabilities":{"limits":{"max_context_window_tokens":1050000}}},{"id":"gpt-small","capabilities":{"limits":{"max_context_window_tokens":400000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    printf '%s|%s' \"\$(_copilot_model_for_claude gpt-large \"\$CATALOG\")\" \
      \"\$(_copilot_model_for_claude gpt-small \"\$CATALOG\")\""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-large[1m]|gpt-small" ]
}

@test "Claude compact window uses max_prompt_tokens then context minus output" {
  local catalog='{"data":[{"id":"direct","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":922000,"max_output_tokens":128000}}},{"id":"derived","capabilities":{"limits":{"max_context_window_tokens":500000,"max_output_tokens":128000}}},{"id":"huge","capabilities":{"limits":{"max_prompt_tokens":1500000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    printf '%s|%s|%s' \"\$(_copilot_claude_compact_window direct \"\$CATALOG\")\" \
      \"\$(_copilot_claude_compact_window derived \"\$CATALOG\")\" \
      \"\$(_copilot_claude_compact_window huge \"\$CATALOG\")\""
  [ "$status" -eq 0 ]
  [ "$output" = "922000|372000|1000000" ]
}

@test "Claude compact window rejects a known ceiling below Claude's minimum" {
  local catalog='{"data":[{"id":"tiny","capabilities":{"limits":{"max_prompt_tokens":64000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'; _copilot_claude_compact_window tiny \"\$CATALOG\""
  [ "$status" -eq 3 ]
  [ -z "$output" ]
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

@test "model profile: Claude fallback uses version sort for 4-10" {
  cat_json='{"data":[
    {"id":"claude-fable-5","capabilities":{"type":"chat"}},
    {"id":"claude-fable-6","capabilities":{"type":"chat"}},
    {"id":"claude-opus-4-9","capabilities":{"type":"chat"}},
    {"id":"claude-opus-4-10","capabilities":{"type":"chat"}}]}'
  run env TEST_CATALOG="$cat_json" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json claude-fable-6 \"\$TEST_CATALOG\" | jq -r .opus"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-10" ]
}

@test "model profile: native Claude roles use their strongest served families" {
  local catalog='{"data":[{"id":"claude-fable-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-opus-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-sonnet-5","capabilities":{"limits":{"max_context_window_tokens":1000000}}},{"id":"claude-haiku-4-5","capabilities":{"limits":{"max_context_window_tokens":200000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_model_profile_json claude-fable-5 \"\$CATALOG\" | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"main":"claude-fable-5[1m]","fable":"claude-fable-5[1m]","opus":"claude-opus-5[1m]","sonnet":"claude-sonnet-5[1m]","haiku":"claude-haiku-4-5"}' ]
}

@test "env profile: Fable is managed and legacy small-fast follows Haiku" {
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":922000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":922000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000,"max_prompt_tokens":272000}}}]}'
  run env CATALOG="$catalog" bash -c "source '$SHELL_LIB'
    _copilot_env_json_for_model gpt-5.6-sol \"\$CATALOG\" \
      | jq -r '[.ANTHROPIC_DEFAULT_FABLE_MODEL,.ANTHROPIC_DEFAULT_OPUS_MODEL,.ANTHROPIC_DEFAULT_SONNET_MODEL,.ANTHROPIC_DEFAULT_HAIKU_MODEL,.ANTHROPIC_SMALL_FAST_MODEL,.CLAUDE_CODE_AUTO_COMPACT_WINDOW,(.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE // \"unset\")] | join(\"|\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna|922000|unset" ]
}

# --- copilot-model metadata surfacing -------------------------------------------
#
# `-l` flattens the catalog to bare ids, which threw away exactly the fields the
# tier ranker now depends on — so there was no way to audit what --auto chose.

details_catalog() {
  cat <<'JSON'
{"data":[
 {"id":"gpt-6-astra","model_picker_category":"powerful","model_picker_price_category":"very_high",
  "billing":{"restricted_to":["pro_plus","max"]},
  "capabilities":{"type":"chat","limits":{"max_context_window_tokens":1000000,"max_output_tokens":128000},
  "supports":{"reasoning_effort":["low","medium","high","max"]}}},
 {"id":"gpt-5.6-sol","model_picker_category":"powerful","model_picker_price_category":"high",
  "capabilities":{"type":"chat","limits":{"max_context_window_tokens":1050000,"max_output_tokens":128000},
  "supports":{"reasoning_effort":["none","max"]}}},
 {"id":"gpt-5.6-luna","model_picker_category":"lightweight","model_picker_price_category":"low",
  "capabilities":{"type":"chat","limits":{"max_context_window_tokens":1050000,"max_output_tokens":128000}}},
 {"id":"text-embedding-3-small","capabilities":{"type":"embeddings"},"model_picker_enabled":false}]}
JSON
}

@test "copilot-model --details renders the tier table and marks the --auto pick" {
  run bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { $(details_catalog | tr -d '\n' | sed "s/'/'\\\\\\\\''/g; s|^|printf '%s' '|; s|$|'|"); }
    _copilot_fast_routing_json() { printf '%s' '{"mappings":{}}'; }
    copilot-model --details"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"TIER"*"PRICE"*"CTX"*"PLANS"*"STATE"* ]]
  # tier order, newest generation first inside the tier
  [[ "${lines[1]}" == *"gpt-6-astra"*"powerful"*"very_high"*"1000k"*"pro_plus+"* ]]
  [[ "${lines[1]}" == "->"* ]]
  [[ "${lines[2]}" == *"gpt-5.6-sol"*"powerful"* ]]
  [[ "${lines[3]}" == *"gpt-5.6-luna"*"lightweight"* ]]
  # embeddings are LISTED (diagnostics show everything) but flagged
  [[ "$output" == *"text-embedding-3-small"*"nopick"* ]]
}

@test "copilot-model --why explains the pick and writes nothing" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf '%s\n' 'gpt-5.4[1m]' > "$TMP/state/copilot-proxy/model"
  run env XDG_STATE_HOME="$TMP/state" bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { $(details_catalog | tr -d '\n' | sed "s/'/'\\\\\\\\''/g; s|^|printf '%s' '|; s|$|'|"); }
    copilot-model --why"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run, nothing written"* ]]
  [[ "$output" == *"gpt-6-astra"* ]]
  # the state file must be untouched
  [ "$(cat "$TMP/state/copilot-proxy/model")" = "gpt-5.4[1m]" ]
}

@test "copilot-model --auto --why explains and then writes" {
  mkdir -p "$TMP/state/copilot-proxy"
  printf '%s\n' 'gpt-5.4[1m]' > "$TMP/state/copilot-proxy/model"
  run env XDG_STATE_HOME="$TMP/state" bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { $(details_catalog | tr -d '\n' | sed "s/'/'\\\\\\\\''/g; s|^|printf '%s' '|; s|$|'|"); }
    copilot-model --auto --why"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-model: --auto reasoning"* ]]
  [[ "$output" != *"dry run, nothing written"* ]]
  [ "$(cat "$TMP/state/copilot-proxy/model")" = "gpt-6-astra[1m]" ]
}

@test "copilot-model --json passes the catalog through" {
  run bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { $(details_catalog | tr -d '\n' | sed "s/'/'\\\\\\\\''/g; s|^|printf '%s' '|; s|$|'|"); }
    copilot-model --json | jq -r '.data | length'"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "copilot-model --why fails cleanly when every catalog entry is vetoed" {
  vetoed='{"data":[
    {"id":"gpt-disabled","policy":{"state":"disabled"},"capabilities":{"type":"chat"}},
    {"id":"gpt-hidden","model_picker_enabled":false,"capabilities":{"type":"chat"}},
    {"id":"text-embedding-3-small","capabilities":{"type":"embeddings"}}]}'
  run env TEST_CATALOG="$vetoed" bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    copilot-model --why"
  [ "$status" -eq 1 ]
  [[ "$output" == *"found no selectable chat model"* ]]
  [[ "$output" != *"  -> "* ]]
}

@test "copilot-model metadata flags reject malformed JSON and accept numeric strings" {
  for flag in --details --json --why --auto; do
    run env TEST_CATALOG='<html>gateway error</html>' bash -c "cd '$TMP'; source '$SHELL_LIB'
      _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
      copilot-model $flag"
    [ "$status" -eq 1 ]
    [[ "$output" == *"valid"*"catalog"* || "$output" == *"reachable proxy"* ]]
  done

  string_limits='{"data":[{"id":"gpt-6-astra","model_picker_category":"powerful",
    "capabilities":{"type":"chat","limits":{"max_context_window_tokens":"1000000","max_output_tokens":"128000"}}}]}'
  run env TEST_CATALOG="$string_limits" bash -c "cd '$TMP'; source '$SHELL_LIB'
    _copilot_model_catalog() { printf '%s' \"\$TEST_CATALOG\"; }
    _copilot_fast_routing_json() { printf '%s' '{\"mappings\":{}}'; }
    copilot-model --details"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1000k"*"128k"* ]]
}

@test "copilot-model metadata flags fail cleanly without a proxy" {
  local flag
  for flag in --details --json --why; do
    run bash -c "cd '$TMP'; source '$SHELL_LIB'
      _copilot_model_catalog() { printf ''; }
      copilot-model $flag"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a reachable proxy"* ]]
  done
}

@test "copilot-model --auto: refuses an offline static fallback" {
  run bash -c "cd '$TMP'; export XDG_STATE_HOME='$TMP/state'; source '$SHELL_LIB'
    _copilot_model_catalog() { return 1; }
    copilot-model --auto"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a reachable proxy and valid /v1/models catalog"* ]]
  [ ! -f "$TMP/state/copilot-proxy/model" ]
}

@test "copilot-model --auto: refreshes every role in an active local pin" {
  mkdir -p "$TMP/proj/.claude"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4141","ANTHROPIC_MODEL":"stale","ANTHROPIC_DEFAULT_SONNET_MODEL":"stale"},"permissions":{"defaultMode":"auto"}}' \
    > "$TMP/proj/.claude/settings.local.json"
  local catalog='{"data":[{"id":"gpt-5.6-sol","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":922000}}},{"id":"gpt-5.6-terra","capabilities":{"limits":{"max_context_window_tokens":1050000,"max_prompt_tokens":922000}}},{"id":"gpt-5.6-luna","capabilities":{"limits":{"max_context_window_tokens":400000,"max_prompt_tokens":272000}}}]}'
  run env CATALOG="$catalog" bash -c "cd '$TMP/proj'; source '$SHELL_LIB'
    _copilot_model_catalog() { printf '%s' \"\$CATALOG\"; }
    copilot-model --auto >/dev/null 2>&1
    jq -r '[.env.ANTHROPIC_MODEL,.env.ANTHROPIC_DEFAULT_FABLE_MODEL,.env.ANTHROPIC_DEFAULT_OPUS_MODEL,.env.ANTHROPIC_DEFAULT_SONNET_MODEL,.env.ANTHROPIC_DEFAULT_HAIKU_MODEL,.env.ANTHROPIC_SMALL_FAST_MODEL,.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW,.permissions.defaultMode] | join(\"|\")' .claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-sol[1m]|gpt-5.6-terra[1m]|gpt-5.6-luna|gpt-5.6-luna|922000|auto" ]
}

@test "copilot-model offline preserves same-model compact ceiling and drops it on model change" {
  mkdir -p "$TMP/proj/.claude"
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:4142","ANTHROPIC_MODEL":"gpt-5.5[1m]","CLAUDE_CODE_AUTO_COMPACT_WINDOW":"372000"}}' > "$TMP/proj/.claude/settings.local.json"
  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'; _copilot_model_catalog() { return 1; }; copilot-model gpt-5.5 >/dev/null; jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW' .claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "372000" ]

  run bash -c "cd '$TMP/proj'; source '$SHELL_LIB'; _copilot_model_catalog() { return 1; }; copilot-model gpt-5-mini >/dev/null; jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // \"removed\"' .claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "removed" ]
}
