#!/usr/bin/env bats

load "../test_helper.bash"

setup() {
  TEST_SANDBOX="$BATS_TEST_TMPDIR/lazyclash"
  mkdir -p "$TEST_SANDBOX/bin" "$TEST_SANDBOX/home"
}

@test "generic Go manifest keeps personal tools out of both platform selections" {
  run bash -c 'source "$REPO_ROOT/scripts/lib/go_tools.sh"; go_tool_packages "$REPO_ROOT/dot_ansible/roles/go_tools/defaults/main.yml" Darwin'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c 'source "$REPO_ROOT/scripts/lib/go_tools.sh"; go_tool_packages "$REPO_ROOT/dot_ansible/roles/go_tools/defaults/main.yml" Linux'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"golang.org/x/tools/gopls@"* ]]
}

@test "Go manifest rejects an invalid later entry without emitting an earlier package" {
  cat >"$TEST_SANDBOX/defaults.yml" <<'YAML'
go_tools:
  - name: example.com/first@v1.0.0
    binary: first
    platforms: [Darwin, Linux]
  - name: example.com/later@v1.0.0
    binary: later
    platforms: [TypoOS]
YAML
  run bash -c 'source "$REPO_ROOT/scripts/lib/go_tools.sh"; go_tool_packages "$1" Darwin >"$2"' bash "$TEST_SANDBOX/defaults.yml" "$TEST_SANDBOX/packages"
  [ "$status" -ne 0 ]
  [ ! -s "$TEST_SANDBOX/packages" ]
}

@test "Go upgrade consumer follows platform manifest without executing Go" {
  printf '#!/bin/sh\nexit 97\n' >"$TEST_SANDBOX/bin/go"
  chmod +x "$TEST_SANDBOX/bin/go"
  sed -n '/^cat_go() {$/,/^}$/p' "$REPO_ROOT/scripts/upgrade_tools.sh" >"$TEST_SANDBOX/cat-go.sh"
  run env HOME="$TEST_SANDBOX/home" PATH="$TEST_SANDBOX/bin:$PATH" \
    TEST_PLATFORM=Linux CALLS="$TEST_SANDBOX/calls" bash -c '
      source "$REPO_ROOT/scripts/lib/go_tools.sh"
      source "$1"
      _REPO_ROOT="$REPO_ROOT"
      SKIP_RC=77
      info() { :; }; warn() { :; }; error() { :; }
      uname() { printf "%s\n" "$TEST_PLATFORM"; }
      _run() { printf "%s\n" "$*" >>"$CALLS"; }
      cat_go
    ' bash "$TEST_SANDBOX/cat-go.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_SANDBOX/calls")" = "go install golang.org/x/tools/gopls@latest" ]
}

@test "actual Ansible install task selects platform and keeps creates idempotency with a fake Go" {
  command -v ansible-playbook >/dev/null || skip "ansible-playbook is unavailable"
  printf '[defaults]\nremote_tmp = %s/ansible-remote\n' "$TEST_SANDBOX" >"$TEST_SANDBOX/ansible.cfg"
  cat >"$TEST_SANDBOX/bin/go" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$GOBIN/calls"
package="${2%@*}"
binary="${package##*/}"
touch "$GOBIN/$binary"
SH
  chmod +x "$TEST_SANDBOX/bin/go"
  local platform
  for platform in Darwin Linux; do
    local fixture_home="$TEST_SANDBOX/$platform"
    mkdir -p "$fixture_home/.local/bin"
    cat >"$TEST_SANDBOX/install.yml" <<YAML
- hosts: localhost
  gather_facts: false
  vars_files:
    - "$REPO_ROOT/dot_ansible/roles/go_tools/defaults/main.yml"
  vars:
    go_bindir:
      stdout: "$TEST_SANDBOX/bin"
    ansible_facts:
      system: "$platform"
      env:
        HOME: "$fixture_home"
        PATH: "/usr/bin:/bin"
  tasks:
YAML
    # Run the real validation/install task definitions, excluding toolchain
    # discovery and Homebrew migration. Only the fake Go can be executed.
    awk '/^- name: Validate Go CLI platform declarations/ { selected=1 }
         selected { print "    " $0 }' \
      "$REPO_ROOT/dot_ansible/roles/go_tools/tasks/main.yml" >>"$TEST_SANDBOX/install.yml"
    run env ANSIBLE_CONFIG="$TEST_SANDBOX/ansible.cfg" ANSIBLE_LOCAL_TEMP="$TEST_SANDBOX/ansible-tmp" \
      ansible-playbook -i localhost, -c local "$TEST_SANDBOX/install.yml"
    [ "$status" -eq 0 ]
    local expected=0
    if [ "$platform" = Linux ]; then
      expected=1
      [ -f "$fixture_home/.local/bin/gopls" ]
    else
      [ ! -e "$fixture_home/.local/bin/calls" ]
    fi
    if [ "$platform" = Darwin ]; then
      [ ! -e "$fixture_home/.local/bin/dev" ]
      [ ! -e "$fixture_home/.local/bin/translate" ]
      [ ! -e "$fixture_home/.local/bin/gopls" ]
    fi
    run env ANSIBLE_CONFIG="$TEST_SANDBOX/ansible.cfg" ANSIBLE_LOCAL_TEMP="$TEST_SANDBOX/ansible-tmp" \
      ansible-playbook -i localhost, -c local "$TEST_SANDBOX/install.yml"
    [ "$status" -eq 0 ]
    if [ "$expected" -gt 0 ]; then
      [ "$(wc -l <"$fixture_home/.local/bin/calls" | tr -d ' ')" -eq "$expected" ]
    else
      [ ! -e "$fixture_home/.local/bin/calls" ]
    fi
  done
}

@test "completion --tool refreshes only lazyclash, skips fresh output, and preserves old output on failure" {
  cat >"$TEST_SANDBOX/bin/lazyclash" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$COMPLETION_CALLS"
[ "${FAIL_COMPLETION:-0}" != 1 ] || exit 1
case "$*" in
  "completion zsh") printf '#compdef lazyclash\n# fixture\n' ;;
  "completion bash") printf '# fixture lazyclash bash\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$TEST_SANDBOX/bin/lazyclash"
  mkdir -p "$TEST_SANDBOX/home/.zfunc" "$TEST_SANDBOX/data/bash-completion/completions"
  printf 'leave this alone\n' >"$TEST_SANDBOX/home/.zfunc/_dev"
  local generator="$REPO_ROOT/scripts/generate_completions.sh"
  run env HOME="$TEST_SANDBOX/home" XDG_DATA_HOME="$TEST_SANDBOX/data" \
    PATH="$TEST_SANDBOX/bin:$PATH" COMPLETION_CALLS="$TEST_SANDBOX/calls" \
    bash "$generator" --tool lazyclash --force --quiet
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_SANDBOX/home/.zfunc/_dev")" = "leave this alone" ]
  [ "$(wc -l <"$TEST_SANDBOX/calls" | tr -d ' ')" -eq 2 ]
  grep -q '^#compdef lazyclash$' "$TEST_SANDBOX/home/.zfunc/_lazyclash"
  [ -s "$TEST_SANDBOX/data/bash-completion/completions/lazyclash" ]

  run env HOME="$TEST_SANDBOX/home" XDG_DATA_HOME="$TEST_SANDBOX/data" \
    PATH="$TEST_SANDBOX/bin:$PATH" COMPLETION_CALLS="$TEST_SANDBOX/calls" \
    bash "$generator" --tool lazyclash --quiet
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TEST_SANDBOX/calls" | tr -d ' ')" -eq 2 ]

  run env HOME="$TEST_SANDBOX/home" XDG_DATA_HOME="$TEST_SANDBOX/data" \
    PATH="$TEST_SANDBOX/bin:$PATH" COMPLETION_CALLS="$TEST_SANDBOX/calls" FAIL_COMPLETION=1 \
    bash "$generator" --tool lazyclash --force --quiet
  [ "$status" -eq 1 ]
  grep -q '^#compdef lazyclash$' "$TEST_SANDBOX/home/.zfunc/_lazyclash"
  [ ! -e "$TEST_SANDBOX/home/.zfunc/_lazyclash.tmp" ]
}

@test "unknown completion tool fails without output directories" {
  run env HOME="$TEST_SANDBOX/home" XDG_DATA_HOME="$TEST_SANDBOX/data" \
    bash "$REPO_ROOT/scripts/generate_completions.sh" --tool no-such-tool
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_SANDBOX/home/.zfunc" ]
  [ ! -e "$TEST_SANDBOX/data" ]
}
