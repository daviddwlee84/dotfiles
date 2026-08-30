#!/usr/bin/env bats

load "../test_helper.bash"

setup() {
  setup_path_stub
  EXTERNALS="$REPO_ROOT/.chezmoiexternal.toml.tmpl"
  PATH_FRAGMENT="$REPO_ROOT/dot_config/shell/08_pi_agents.sh.tmpl"
  ROLE="$REPO_ROOT/dot_ansible/roles/coding_agents/tasks/main.yml"
  CLEANUP="$REPO_ROOT/dot_ansible/roles/coding_agents/files/pi_omp_package_cleanup.sh"
  UPGRADES="$REPO_ROOT/scripts/upgrade_tools.sh"
  COMPLETIONS="$REPO_ROOT/scripts/generate_completions.sh"
}

_seed_npm_package() {
  local prefix="$1" package="$2" binary="${3:-}"
  mkdir -p "$prefix/lib/node_modules/$package" "$prefix/bin"
  printf '%s\n' '{}' >"$prefix/lib/node_modules/$package/package.json"
  if [ -n "$binary" ]; then
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$prefix/bin/$binary"
    chmod +x "$prefix/bin/$binary"
  fi
}

_write_npm_stub() {
  cat >"$BATS_STUB_DIR/npm" <<'EOF'
#!/bin/sh
set -eu
cmd="${1:-}"
[ "$#" -eq 0 ] || shift
printf '%s %s\n' "$cmd" "$*" >>"$PIA_TEST_NPM_LOG"

if [ "$cmd" = "prefix" ]; then
  printf '%s\n' "$PIA_TEST_ACTIVE_PREFIX"
  exit 0
fi

prefix=""
package=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    @*) package="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$prefix" ] && [ -n "$package" ] || exit 2
manifest="$prefix/lib/node_modules/$package/package.json"

case "$cmd" in
  list) [ -f "$manifest" ] ;;
  uninstall)
    rm -rf "$prefix/lib/node_modules/$package"
    case "$package" in
      @mariozechner/pi-coding-agent|@earendil-works/pi-coding-agent)
        rm -f "$prefix/bin/pi"
        ;;
      @oh-my-pi/pi-coding-agent)
        rm -f "$prefix/bin/omp"
        ;;
    esac
    ;;
  install)
    [ "${PIA_TEST_FAIL_PI_INSTALL:-0}" -ne 1 ] || exit 42
    mkdir -p "${manifest%/*}/dist/bundle" "$prefix/bin"
    printf '%s\n' '{}' >"$manifest"
    if [ "$package" = "@earendil-works/pi-coding-agent" ]; then
      printf '%s\n' '#!/bin/sh' '[ "${1:-}" = "--version" ]' \
        >"${manifest%/*}/dist/bundle/cli.js"
      chmod +x "${manifest%/*}/dist/bundle/cli.js"
      ln -s "../lib/node_modules/$package/dist/bundle/cli.js" "$prefix/bin/pi"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_STUB_DIR/npm"
  cat >"$BATS_STUB_DIR/node" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = "-e" ] || exit 2
case "$(readlink "$3" 2>/dev/null || true)" in
  *"@earendil-works/pi-coding-agent"*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_STUB_DIR/node"
}

_write_bun_stub() {
  cat >"$BATS_STUB_DIR/bun" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$PIA_TEST_BUN_LOG"
[ "${1:-}" = "remove" ] || exit 2
[ "${4:-}" = "@oh-my-pi/pi-coding-agent" ] || exit 2
rm -rf "$BUN_INSTALL_GLOBAL_DIR/node_modules/@oh-my-pi/pi-coding-agent"
rm -f "$BUN_INSTALL_BIN/omp"
EOF
  chmod +x "$BATS_STUB_DIR/bun"
}

_write_curl_stub() {
  cat >"$BATS_STUB_DIR/curl" <<'EOF'
#!/bin/sh
set -eu
[ "${PIA_TEST_FAIL_OMP_INSTALL:-0}" -ne 1 ] || exit 22
cat <<'INSTALLER'
#!/bin/sh
set -eu
mkdir -p "$PI_INSTALL_DIR"
cat >"$PI_INSTALL_DIR/omp" <<'BINARY'
#!/bin/sh
[ "${1:-}" = "--version" ]
BINARY
chmod +x "$PI_INSTALL_DIR/omp"
INSTALLER
EOF
  chmod +x "$BATS_STUB_DIR/curl"
}

@test "installCodingAgents gates both the pi-agents external and pia PATH" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

  run chezmoi execute-template --source "$REPO_ROOT" \
    --override-data '{"installCodingAgents":true}' <"$EXTERNALS"
  [ "$status" -eq 0 ]
  [[ "$output" == *'[".local/share/pi-agents"]'* ]]
  [[ "$output" == *'https://github.com/daviddwlee84/pi-agents.git'* ]]

  run chezmoi execute-template --source "$REPO_ROOT" \
    --override-data '{"installCodingAgents":false}' <"$EXTERNALS"
  [ "$status" -eq 0 ]
  [[ "$output" != *'.local/share/pi-agents'* ]]

  run chezmoi execute-template --source "$REPO_ROOT" \
    --override-data '{"installCodingAgents":true}' <"$PATH_FRAGMENT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'export PATH="$HOME/.local/bin:$PATH"'* ]]
  [[ "$output" == *'_pia_root="$HOME/.local/share/pi-agents"'* ]]
  [[ "$output" == *'export PATH="$_pia_root/bin:$PATH"'* ]]

  run chezmoi execute-template --source "$REPO_ROOT" \
    --override-data '{"installCodingAgents":false}' <"$PATH_FRAGMENT"
  [ "$status" -eq 0 ]
  [[ "$output" != *'_pia_root='* ]]
}

@test "late shared fragment makes managed pi omp and pia beat mise Bun and PATH shadows" {
  command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

  local test_home="$BATS_TEST_TMPDIR/path-home"
  local rendered="$BATS_TEST_TMPDIR/08_pi_agents.sh"
  local mise_bin="$BATS_TEST_TMPDIR/mise-node/bin"
  local bun_bin="$test_home/.bun/bin"
  mkdir -p "$test_home/.local/bin" "$test_home/.local/share/pi-agents/bin" \
    "$mise_bin" "$bun_bin"

  for path in "$test_home/.local/bin/pi" "$test_home/.local/bin/omp" \
    "$test_home/.local/share/pi-agents/bin/pia" "$mise_bin/pi" \
    "$bun_bin/omp" "$BATS_STUB_DIR/pia"; do
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$path"
    chmod +x "$path"
  done

  chezmoi execute-template --source "$REPO_ROOT" \
    --override-data '{"installCodingAgents":true}' <"$PATH_FRAGMENT" >"$rendered"

  for shell in /bin/bash /bin/zsh; do
    run env HOME="$test_home" PATH="$mise_bin:$bun_bin:$BATS_STUB_DIR:/usr/bin:/bin" \
      "$shell" -c '. "$1"; command -v pi; command -v omp; command -v pia' _ "$rendered"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$test_home/.local/bin/pi" ]
    [ "${lines[1]}" = "$test_home/.local/bin/omp" ]
    [ "${lines[2]}" = "$test_home/.local/share/pi-agents/bin/pia" ]
  done
}

@test "Pi migration verifies canonical install before removing exact shadows" {
  local test_home="$BATS_TEST_TMPDIR/pi-home"
  local managed="$test_home/.local"
  local active="$BATS_TEST_TMPDIR/mise-node"
  local npm_log="$BATS_TEST_TMPDIR/pi-npm.log"
  mkdir -p "$test_home"
  _write_npm_stub
  _seed_npm_package "$active" "@mariozechner/pi-coding-agent" pi
  _seed_npm_package "$active" "@earendil-works/pi-coding-agent" pi
  _seed_npm_package "$active" "@keep/tool" keep
  _seed_npm_package "$managed" "@mariozechner/pi-coding-agent" pi
  _seed_npm_package "$managed" "@keep/stable" keep-stable

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PATH="$BATS_STUB_DIR:/usr/bin:/bin" bash "$CLEANUP" pi-install
  [ "$status" -eq 0 ]
  [[ "$output" == *'PI_INSTALL_CHANGED=1'* ]]
  [ -f "$active/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ -f "$active/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]
  [ -f "$managed/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ -f "$managed/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]
  [ -x "$managed/bin/pi" ]

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PATH="$BATS_STUB_DIR:/usr/bin:/bin" bash "$CLEANUP" pi-install
  [ "$status" -eq 0 ]
  [[ "$output" == *'PI_INSTALL_CHANGED=0'* ]]

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PATH="$BATS_STUB_DIR:/usr/bin:/bin" bash "$CLEANUP" pi-cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *'PI_CLEANUP_CHANGED=1'* ]]
  [ ! -e "$active/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ ! -e "$active/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]
  [ ! -e "$managed/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ -f "$managed/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]
  [ -x "$managed/bin/pi" ]
  [ -f "$active/lib/node_modules/@keep/tool/package.json" ]
  [ -x "$active/bin/keep" ]
  [ -f "$managed/lib/node_modules/@keep/stable/package.json" ]
  [ -x "$managed/bin/keep-stable" ]

  grep -Fq "uninstall -g --ignore-scripts --prefix $active @mariozechner/pi-coding-agent" "$npm_log"
  grep -Fq "uninstall -g --ignore-scripts --prefix $active @earendil-works/pi-coding-agent" "$npm_log"
  grep -Eq "install -g --ignore-scripts --prefix $managed( --force)? @earendil-works/pi-coding-agent" "$npm_log"
}

@test "OMP migration verifies binary install before removing exact npm and Bun shadows" {
  local test_home="$BATS_TEST_TMPDIR/omp-home"
  local managed="$test_home/.local"
  local active="$BATS_TEST_TMPDIR/active-node"
  local bun_global="$BATS_TEST_TMPDIR/custom-bun-global"
  local bun_bin="$BATS_TEST_TMPDIR/custom-bun-bin"
  local npm_log="$BATS_TEST_TMPDIR/omp-npm.log"
  local bun_log="$BATS_TEST_TMPDIR/omp-bun.log"
  mkdir -p "$test_home" "$bun_global/node_modules/@oh-my-pi/pi-coding-agent" \
    "$bun_global/node_modules/@keep/bun-tool" "$bun_bin"
  printf '%s\n' '{}' >"$bun_global/node_modules/@oh-my-pi/pi-coding-agent/package.json"
  printf '%s\n' '{}' >"$bun_global/node_modules/@keep/bun-tool/package.json"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$bun_bin/omp"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$bun_bin/keep-bun"
  chmod +x "$bun_bin/omp" "$bun_bin/keep-bun"
  _write_npm_stub
  _write_bun_stub
  _write_curl_stub
  _seed_npm_package "$active" "@oh-my-pi/pi-coding-agent" omp
  _seed_npm_package "$active" "@keep/tool" keep
  _seed_npm_package "$managed" "@oh-my-pi/pi-coding-agent" omp
  _seed_npm_package "$managed" "@keep/stable" keep-stable

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PIA_TEST_BUN_LOG="$bun_log" BUN_INSTALL_GLOBAL_DIR="$bun_global" \
    BUN_INSTALL_BIN="$bun_bin" PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$CLEANUP" omp-status
  [ "$status" -eq 0 ]
  [[ "$output" == *'OMP_PACKAGE_PRESENT=1'* ]]

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PATH="$BATS_STUB_DIR:/usr/bin:/bin" bash "$CLEANUP" omp-install
  [ "$status" -eq 0 ]
  [[ "$output" == *'OMP_INSTALL_CHANGED=1'* ]]
  [ -f "$active/lib/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ -f "$managed/lib/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ -f "$bun_global/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ -x "$managed/bin/omp" ]

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PIA_TEST_BUN_LOG="$bun_log" BUN_INSTALL_GLOBAL_DIR="$bun_global" \
    BUN_INSTALL_BIN="$bun_bin" PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$CLEANUP" omp-cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *'OMP_CLEANUP_CHANGED=1'* ]]
  [ ! -e "$active/lib/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ ! -e "$managed/lib/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ ! -e "$bun_global/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  [ ! -e "$bun_bin/omp" ]
  [ -x "$managed/bin/omp" ]
  [ -f "$active/lib/node_modules/@keep/tool/package.json" ]
  [ -x "$active/bin/keep" ]
  [ -f "$managed/lib/node_modules/@keep/stable/package.json" ]
  [ -x "$managed/bin/keep-stable" ]
  [ -f "$bun_global/node_modules/@keep/bun-tool/package.json" ]
  [ -x "$bun_bin/keep-bun" ]
  grep -Fq "uninstall -g --ignore-scripts --prefix $active @oh-my-pi/pi-coding-agent" "$npm_log"
  grep -Fq 'remove -g --ignore-scripts @oh-my-pi/pi-coding-agent' "$bun_log"
}

@test "failed Pi and OMP installs restore prior commands and never start cleanup" {
  local test_home="$BATS_TEST_TMPDIR/failure-home"
  local managed="$test_home/.local"
  local active="$BATS_TEST_TMPDIR/failure-active"
  local npm_log="$BATS_TEST_TMPDIR/failure-npm.log"
  mkdir -p "$test_home"
  _write_npm_stub
  _write_curl_stub
  _seed_npm_package "$active" "@mariozechner/pi-coding-agent" pi
  _seed_npm_package "$managed" "@mariozechner/pi-coding-agent" pi
  _seed_npm_package "$managed" "@oh-my-pi/pi-coding-agent" omp
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$managed/bin/pi"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$managed/bin/omp"
  chmod +x "$managed/bin/pi" "$managed/bin/omp"

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PIA_TEST_FAIL_PI_INSTALL=1 PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$CLEANUP" pi-install
  [ "$status" -ne 0 ]
  [ -x "$managed/bin/pi" ]
  grep -Fxq 'exit 0' "$managed/bin/pi"
  [ -f "$managed/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ -f "$active/lib/node_modules/@mariozechner/pi-coding-agent/package.json" ]
  [ ! -e "$managed/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]
  ! grep -Fq 'uninstall ' "$npm_log"
  ! grep -Fq -- '--force' "$npm_log"

  run env HOME="$test_home" PI_AGENTS_MANAGED_PREFIX="$managed" \
    PIA_TEST_ACTIVE_PREFIX="$active" PIA_TEST_NPM_LOG="$npm_log" \
    PIA_TEST_FAIL_OMP_INSTALL=1 PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$CLEANUP" omp-install
  [ "$status" -ne 0 ]
  [ -x "$managed/bin/omp" ]
  grep -Fxq 'exit 0' "$managed/bin/omp"
  [ -f "$managed/lib/node_modules/@oh-my-pi/pi-coding-agent/package.json" ]
  ! grep -Fq '@oh-my-pi/pi-coding-agent' "$npm_log"
}

@test "role verifies canonical agents before gated package cleanup" {
  grep -Fq 'Node >= 22.19' "$ROLE"
  grep -Fq 'cmd: pi_omp_package_cleanup.sh pi-install' "$ROLE"
  grep -Fq 'cmd: pi_omp_package_cleanup.sh pi-cleanup' "$ROLE"
  grep -Fq 'cmd: pi_omp_package_cleanup.sh omp-status' "$ROLE"
  grep -Fq 'cmd: pi_omp_package_cleanup.sh omp-install' "$ROLE"
  grep -Fq 'cmd: pi_omp_package_cleanup.sh omp-cleanup' "$ROLE"
  grep -Fq "BUN_INSTALL_GLOBAL_DIR:" "$ROLE"
  grep -Fq "BUN_INSTALL_BIN:" "$ROLE"
  local omp_block
  omp_block="$(sed -n '/Remove package-managed Oh My Pi copies after binary verification/,/register: omp_package_cleanup/p' "$ROLE")"
  [[ "$omp_block" == *"target_architecture in ['x86_64', 'amd64', 'aarch64', 'arm64']"* ]]
  [[ "$omp_block" == *'not (oldEL | default(false))'* ]]
  local pi_install_line pi_verify_line pi_cleanup_line
  local omp_install_line omp_verify_line omp_cleanup_line
  pi_install_line="$(grep -n 'Install and transactionally verify maintained Pi' "$ROLE" | cut -d: -f1)"
  pi_verify_line="$(grep -n 'Verify Pi can start from the managed npm runtime' "$ROLE" | cut -d: -f1)"
  pi_cleanup_line="$(grep -n 'Remove deprecated and duplicate Pi packages after canonical verification' "$ROLE" | cut -d: -f1)"
  omp_install_line="$(grep -n 'Install Oh My Pi from the official prebuilt binary' "$ROLE" | cut -d: -f1)"
  omp_verify_line="$(grep -n 'Verify Oh My Pi can start from the canonical install path' "$ROLE" | cut -d: -f1)"
  omp_cleanup_line="$(grep -n 'Remove package-managed Oh My Pi copies after binary verification' "$ROLE" | cut -d: -f1)"
  [ "$pi_install_line" -lt "$pi_verify_line" ]
  [ "$pi_verify_line" -lt "$pi_cleanup_line" ]
  [ "$omp_install_line" -lt "$omp_verify_line" ]
  [ "$omp_verify_line" -lt "$omp_cleanup_line" ]
  grep -Fq 'coding_agents Pi/OMP cleanup:' \
    "$REPO_ROOT/.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl"
  grep -Fq '"{{ ansible_facts['"'"'env'"'"']['"'"'HOME'"'"'] }}/.local/bin/mise" exec -- \' "$ROLE"
  grep -Fq '"{{ ansible_facts['"'"'env'"'"']['"'"'HOME'"'"'] }}/.local/bin/pi" --version' "$ROLE"
}

@test "OMP install and both agent upgrades preserve their canonical channels" {
  grep -Fq 'https://omp.sh/install' "$CLEANUP"
  grep -Fq -- '--max-time 300' "$CLEANUP"
  grep -Fq 'sh -s -- --binary' "$CLEANUP"
  grep -Fq 'cmd: "{{ ansible_facts['"'"'env'"'"']['"'"'HOME'"'"'] }}/.local/bin/omp --version"' "$ROLE"
  grep -Fq 'local pi_cmd="$HOME/.local/bin/pi"' "$UPGRADES"
  grep -Fq 'local pi_update="$pi_cmd update --self"' "$UPGRADES"
  grep -Fq -- '--prefix \"$HOME/.local\" @earendil-works/pi-coding-agent' "$UPGRADES"
  grep -Fq 'local omp_cmd="$HOME/.local/bin/omp"' "$UPGRADES"
  grep -Fq 'local omp_update="$omp_cmd update"' "$UPGRADES"
  grep -Fq 'PI_INSTALL_DIR=\"$HOME/.local/bin\" sh -s -- --binary' "$UPGRADES"
}

@test "agent upgrades ignore PATH shadows and invoke only canonical pi and omp" {
  local test_home="$BATS_TEST_TMPDIR/upgrade-home"
  local npm_log="$BATS_TEST_TMPDIR/npm.log"
  local agent_log="$BATS_TEST_TMPDIR/agents.log"
  mkdir -p "$test_home/.local/bin"

  for agent in pi omp; do
    cat >"$BATS_STUB_DIR/$agent" <<'EOF'
#!/bin/sh
printf 'shadow:%s\n' "${0##*/}" >>"$PIA_TEST_AGENT_LOG"
exit 0
EOF
    chmod +x "$BATS_STUB_DIR/$agent"
    cat >"$test_home/.local/bin/$agent" <<'EOF'
#!/bin/sh
printf 'canonical:%s\n' "${0##*/}" >>"$PIA_TEST_AGENT_LOG"
exit 1
EOF
    chmod +x "$test_home/.local/bin/$agent"
  done
  cat >"$BATS_STUB_DIR/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$PIA_TEST_NPM_LOG"
EOF
  chmod +x "$BATS_STUB_DIR/npm"
  cat >"$BATS_STUB_DIR/curl" <<'EOF'
#!/bin/sh
printf '%s\n' '#!/bin/sh' 'exit 0'
EOF
  chmod +x "$BATS_STUB_DIR/curl"

  run env HOME="$test_home" PIA_TEST_NPM_LOG="$npm_log" \
    PIA_TEST_AGENT_LOG="$agent_log" \
    PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$UPGRADES" agents
  [ "$status" -eq 0 ]
  [[ "$output" == *'Pi self-update failed/timed out'* ]]
  [[ "$output" == *'Oh My Pi self-update failed/timed out'* ]]
  grep -Fq "install -g --ignore-scripts --prefix $test_home/.local @earendil-works/pi-coding-agent" "$npm_log"
  grep -Fq 'canonical:pi' "$agent_log"
  grep -Fq 'canonical:omp' "$agent_log"
  ! grep -Fq 'shadow:' "$agent_log"
  [[ "$output" == *'category '\''agents'\'' completed'* ]]
}

@test "OMP completion generator writes zsh and bash outputs" {
  local test_home="$BATS_TEST_TMPDIR/home"
  local data_home="$BATS_TEST_TMPDIR/data"
  mkdir -p "$test_home/.local/bin" "$data_home"
  cat >"$test_home/.local/bin/omp" <<'EOF'
#!/bin/sh
case "${1:-} ${2:-}" in
  "completions zsh")
    printf '%s\n' '#compdef omp' '_omp() { :; }' 'compdef _omp omp'
    ;;
  "completions bash")
    printf '%s\n' '_omp_complete() { :; }' 'complete -F _omp_complete omp'
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$test_home/.local/bin/omp"

  run env HOME="$test_home" XDG_DATA_HOME="$data_home" \
    PATH="/usr/bin:/bin" \
    bash "$COMPLETIONS" --force --quiet
  [ "$status" -eq 0 ]
  grep -Fq '#compdef omp' "$test_home/.zfunc/_omp"
  grep -Fq 'complete -F _omp_complete omp' "$data_home/bash-completion/completions/omp"
}

@test "pia completion generator uses the canonical external and Git revision stamp" {
  local test_home="$BATS_TEST_TMPDIR/home"
  local data_home="$BATS_TEST_TMPDIR/data"
  local checkout="$test_home/.local/share/pi-agents"
  local shadow_log="$BATS_TEST_TMPDIR/pia-shadow.log"
  mkdir -p "$checkout/bin" "$checkout/.git" "$test_home/.zfunc" \
    "$data_home/bash-completion/completions"

  cat >"$checkout/bin/pia" <<'EOF'
#!/bin/sh
case "${1:-} ${2:-}" in
  "completion zsh")
    printf '%s\n' '#compdef pia' '_pia() { :; }' 'compdef _pia pia'
    ;;
  "completion bash")
    printf '%s\n' '_pia_complete() { :; }' 'complete -F _pia_complete pia'
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$checkout/bin/pia"
  cat >"$BATS_STUB_DIR/pia" <<'EOF'
#!/bin/sh
printf '%s\n' shadow >>"$PIA_TEST_SHADOW_LOG"
exit 99
EOF
  chmod +x "$BATS_STUB_DIR/pia"

  printf '%s\n' stale >"$test_home/.zfunc/_pia"
  printf '%s\n' stale >"$data_home/bash-completion/completions/pia"
  : >"$checkout/.git/index"
  touch -t 201901010000 "$checkout/bin/pia"
  touch -t 202001010000 "$test_home/.zfunc/_pia" \
    "$data_home/bash-completion/completions/pia"
  touch -t 202101010000 "$checkout/.git/index"

  run env HOME="$test_home" XDG_DATA_HOME="$data_home" \
    PIA_TEST_SHADOW_LOG="$shadow_log" PATH="$BATS_STUB_DIR:/usr/bin:/bin" \
    bash "$COMPLETIONS" --quiet
  [ "$status" -eq 0 ]
  grep -Fq '#compdef pia' "$test_home/.zfunc/_pia"
  grep -Fq 'complete -F _pia_complete pia' "$data_home/bash-completion/completions/pia"
  [ ! -e "$shadow_log" ]
}

@test "prompt, README, completion docs, and agent skill surface Pi OMP and pia" {
  local consent='Install coding agents (Claude Code, Pi, Oh My Pi, pia presets, OpenCode, Cursor, Copilot, Gemini, etc.)'
  grep -Fq 'Pi/OMP with pia presets' "$REPO_ROOT/scripts/init/dotfiles_init.py"
  grep -Fq "prompt_text=\"$consent\"" "$REPO_ROOT/scripts/init/dotfiles_init.py"
  grep -Fq "$consent" "$REPO_ROOT/.chezmoi.toml.tmpl"
  grep -Fq "$consent" "$REPO_ROOT/Dockerfile"
  grep -Fq 'Oh My Pi (`omp`)' "$REPO_ROOT/README.md"
  grep -Fq 'docs/tools/pi-agents.md' "$REPO_ROOT/README.md"
  grep -Fq 'regen omp "completions zsh" "completions bash"' "$COMPLETIONS"
  grep -Fq 'regen pia "completion zsh" "completion bash"' "$COMPLETIONS"
  grep -Fq '$HOME/.local/share/pi-agents/bin/pia' "$COMPLETIONS"
  grep -Fq '$HOME/.local/share/pi-agents/.git/index' "$COMPLETIONS"
  grep -Fq '| `omp` | `omp completions zsh` |' "$REPO_ROOT/docs/zsh/zsh-completions.md"
  grep -Fq '| `omp` | `omp completions zsh` |' "$REPO_ROOT/docs/zsh/zsh-completions.zh-TW.md"
  grep -Fq '| `pia` | `pia completion zsh` |' "$REPO_ROOT/docs/zsh/zsh-completions.md"
  grep -Fq '| `pia` | `pia completion zsh` |' "$REPO_ROOT/docs/zsh/zsh-completions.zh-TW.md"
  grep -Fq 'pia use <Tab>' "$REPO_ROOT/docs/tools/pi-agents.md"
  grep -Fq 'pia use <Tab>' "$REPO_ROOT/docs/tools/pi-agents.zh-TW.md"
  grep -Fq 'Pi (`pi`), Oh My Pi (`omp`), the `pia` Git-managed harness-combo manager' \
    "$REPO_ROOT/dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl"
}
