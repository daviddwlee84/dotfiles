#!/usr/bin/env bats
# Unit tests for dot_config/shell/96_ssh_setup.sh.
#
# Two behaviours this file exists to pin down, both of which were real failures:
#
#   1. A target reached via ProxyJump used to get set up ALONE. ssh(1) tunnels
#      through the jump host transparently, so the wizard never noticed it and
#      every later connection still asked for the jump host's password.
#   2. A private key whose .pub half is missing passed the existence check
#      (`[ ! -f key ] && [ ! -f key.pub ]` is OR semantics) and only blew up
#      later inside ssh-copy-id with a confusing errno message.
#
# Everything external is stubbed on PATH: `ssh` doubles as a canned `ssh -G`
# oracle and as a request log, `ssh-copy-id` records its argv and asserts the
# .pub it was handed actually exists. Both shells are exercised because this
# fragment carries explicit $ZSH_VERSION/$BASH_VERSION dispatch and runs under
# `emulate -L zsh`, where unquoted command substitution does NOT word-split.

load "../test_helper.bash"

SSH_FILE="$REPO_ROOT/dot_config/shell/96_ssh_setup.sh"

setup() {
  setup_path_stub
  SSH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ssh-setup.XXXXXX")"
  export SSH_TMP
  export CAPTURE_LOG="$SSH_TMP/capture.log"
  export PS_LOG="$SSH_TMP/ps.log"
  export FAKE_HOME="$SSH_TMP/home"
  mkdir -p "$FAKE_HOME/.ssh"
  _install_ssh_stubs
}

teardown() {
  [ -n "${SSH_TMP:-}" ] && [ -d "$SSH_TMP" ] && rm -rf "$SSH_TMP"
  cleanup_path_stubs
}

# `ssh` stub: answers `ssh -G <host>` from a fixture table, logs everything
# else, and decodes any -EncodedCommand payload so tests can assert on the
# PowerShell actually sent to a Windows remote.
_install_ssh_stubs() {
  cat > "$BATS_STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-G" ]; then
  case "$2" in
    plain)      printf 'hostname plain\n' ;;
    one)        printf 'proxyjump jump1\n' ;;
    jump1)      printf 'hostname jump1\n' ;;
    deep)       printf 'proxyjump mid\n' ;;
    mid)        printf 'proxyjump jump1\n' ;;
    multi)      printf 'proxyjump a,b:2222\n' ;;
    a)          printf 'hostname a\n' ;;
    b)          printf 'hostname b\n' ;;
    nojump)     printf 'proxyjump none\n' ;;
    cyc1)       printf 'proxyjump cyc2\n' ;;
    cyc2)       printf 'proxyjump cyc1\n' ;;
    winbox)     printf 'hostname winbox\n' ;;
    *)          printf 'hostname %s\n' "$2" ;;
  esac
  exit 0
fi
echo "ssh $*" >> "$CAPTURE_LOG"
last="${!#}"
case "$last" in
  'uname -s')
    # A reachable POSIX host answers this; a Windows one has no uname, and a
    # host we cannot reach at all exits 255 (which the wizard must NOT confuse
    # with "connected but unidentifiable").
    [ "${FAKE_WINDOWS:-0}" = "1" ] && exit 255
    [ "${FAKE_UNREACHABLE:-0}" = "1" ] && { echo "ssh: connect failed" >&2; exit 255; }
    printf 'Linux\n'
    exit 0 ;;
  *EncodedCommand*)
    [ "${FAKE_WINDOWS:-0}" = "1" ] || exit 255
    enc="${last##*EncodedCommand }"
    src="$(printf '%s' "$enc" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8)"
    printf '%s\n' "$src" >> "$PS_LOG"
    case "$src" in
      *"whoami /groups"*) printf 'windows admin=%s user=Ada\r\n' "${FAKE_WINDOWS_ADMIN:-1}" ;;
      *)                  printf 'added:remote\r\n' ;;
    esac
    exit 0 ;;
esac
exit 255
EOF
  cat > "$BATS_STUB_DIR/ssh-copy-id" <<'EOF'
#!/usr/bin/env bash
echo "ssh-copy-id $*" >> "$CAPTURE_LOG"
for a in "$@"; do
  case "$a" in
    *.pub) [ -f "$a" ] || { echo "MISSING-PUB $a" >> "$CAPTURE_LOG"; exit 1; } ;;
  esac
done
exit 0
EOF
  chmod +x "$BATS_STUB_DIR/ssh" "$BATS_STUB_DIR/ssh-copy-id"
}

# Run a snippet against the fragment under a chosen shell, with $HOME pointing
# at the throwaway tree so ~/.ssh is never the developer's real one.
_ssh_run() {
  local shell="$1" snippet="$2"
  HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    "$shell" -c "source '$SSH_FILE'; $snippet"
}

_mkkey() {
  ssh-keygen -q -t ed25519 -N '' -C "test $1" -f "$FAKE_HOME/.ssh/$1" </dev/null
}

# ── ProxyJump chain resolution ────────────────────────────────────────────

@test "chain: a host with no ProxyJump has an empty chain (zsh + bash)" {
  local sh
  for sh in bash zsh; do
    run _ssh_run "$sh" '_ssh_setup_chain plain'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "chain: 'ProxyJump none' is not a hop" {
  run _ssh_run bash '_ssh_setup_chain nojump'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "chain: one jump host is reported, target excluded (zsh + bash)" {
  local sh
  for sh in bash zsh; do
    run _ssh_run "$sh" '_ssh_setup_chain one'
    [ "$status" -eq 0 ]
    [ "$output" = "jump1" ]
  done
}

@test "chain: nested ProxyJump resolves outermost-first (zsh + bash)" {
  # deep -> mid -> jump1, so jump1 must be set up before mid.
  local sh
  for sh in bash zsh; do
    run _ssh_run "$sh" '_ssh_setup_chain deep'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "jump1" ]
    [ "${lines[1]}" = "mid" ]
    [ "${#lines[@]}" -eq 2 ]
  done
}

@test "chain: a comma-separated -J list keeps its order and port suffixes" {
  run _ssh_run bash '_ssh_setup_chain multi'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a" ]
  [ "${lines[1]}" = "b:2222" ]
}

@test "chain: a ProxyJump cycle terminates and never lists the target itself" {
  run _ssh_run bash '_ssh_setup_chain cyc1'
  [ "$status" -eq 0 ]
  [ "$output" = "cyc2" ]
}

# ── Hop spec splitting ────────────────────────────────────────────────────

@test "split_hop: user@host:port, IPv6 literal, bare alias, non-numeric port" {
  run _ssh_run bash '
    _ssh_setup_split_hop "user@host:2222"; printf "%s|%s\n" "$_SSH_HOP_DEST" "$_SSH_HOP_PORT"
    _ssh_setup_split_hop "[::1]:22";       printf "%s|%s\n" "$_SSH_HOP_DEST" "$_SSH_HOP_PORT"
    _ssh_setup_split_hop "plain";          printf "%s|%s\n" "$_SSH_HOP_DEST" "$_SSH_HOP_PORT"
    _ssh_setup_split_hop "host:notaport";  printf "%s|%s\n" "$_SSH_HOP_DEST" "$_SSH_HOP_PORT"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "user@host|2222" ]
  [ "${lines[1]}" = "[::1]|22" ]
  [ "${lines[2]}" = "plain|" ]
  [ "${lines[3]}" = "host:notaport|" ]
}

# ── Key discovery ─────────────────────────────────────────────────────────

@test "list_keys: finds a private key with no .pub and marks it" {
  _mkkey lonely
  rm -f "$FAKE_HOME/.ssh/lonely.pub"
  run _ssh_run bash '_ssh_setup_list_keys'
  [ "$status" -eq 0 ]
  [[ "$output" == *"lonely  (no .pub)"* ]]
}

@test "list_keys: skips config, known_hosts, .DS_Store and .pub files" {
  _mkkey normal
  : > "$FAKE_HOME/.ssh/config"
  : > "$FAKE_HOME/.ssh/known_hosts"
  : > "$FAKE_HOME/.ssh/.DS_Store"
  mkdir -p "$FAKE_HOME/.ssh/config.d"
  run _ssh_run bash '_ssh_setup_list_keys'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"/normal" ]]
  [[ "$output" != *"known_hosts"* ]]
  [[ "$output" != *"DS_Store"* ]]
}

@test "ensure_pubkey: regenerates a missing .pub matching ssh-keygen -y" {
  _mkkey k
  cp "$FAKE_HOME/.ssh/k.pub" "$SSH_TMP/expected.pub"
  rm -f "$FAKE_HOME/.ssh/k.pub"
  run env SSH_SETUP_ASSUME_YES=1 bash -c \
    "HOME='$FAKE_HOME'; source '$SSH_FILE'; _ssh_setup_ensure_pubkey '$FAKE_HOME/.ssh/k'"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.ssh/k.pub" ]
  # ssh-keygen -y omits the comment, so compare the key material only.
  [ "$(cut -d' ' -f1,2 < "$FAKE_HOME/.ssh/k.pub")" = "$(cut -d' ' -f1,2 < "$SSH_TMP/expected.pub")" ]
}

@test "ensure_pubkey: declining leaves no truncated .pub behind" {
  _mkkey k
  rm -f "$FAKE_HOME/.ssh/k.pub"
  run bash -c "HOME='$FAKE_HOME'; source '$SSH_FILE'; _ssh_setup_ensure_pubkey '$FAKE_HOME/.ssh/k'" <<< "n"
  [ "$status" -eq 1 ]
  [ ! -f "$FAKE_HOME/.ssh/k.pub" ]
}

# ── Driver ────────────────────────────────────────────────────────────────

@test "driver: the jump host is set up before the final target (zsh + bash)" {
  _mkkey k
  local sh
  for sh in bash zsh; do
    : > "$CAPTURE_LOG"
    run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
      SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
      "$sh" -c "source '$SSH_FILE'; ssh-setup-remote one"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ProxyJump chain detected: jump1 -> one"* ]]
    local order
    order="$(grep -c . "$CAPTURE_LOG")"
    [ "$order" -gt 0 ]
    # jump1 must appear on an earlier ssh-copy-id line than one.
    local first second
    first="$(grep -n 'ssh-copy-id .* jump1$' "$CAPTURE_LOG" | head -1 | cut -d: -f1)"
    second="$(grep -n 'ssh-copy-id .* one$' "$CAPTURE_LOG" | head -1 | cut -d: -f1)"
    [ -n "$first" ]
    [ -n "$second" ]
    [ "$first" -lt "$second" ]
  done
}

@test "driver: a key missing its .pub is repaired before ssh-copy-id runs" {
  # The original bug: ssh-copy-id got a .pub that did not exist.
  _mkkey k
  rm -f "$FAKE_HOME/.ssh/k.pub"
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
    bash -c "source '$SSH_FILE'; ssh-setup-remote plain"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_HOME/.ssh/k.pub" ]
  grep -q 'ssh-copy-id' "$CAPTURE_LOG"
  ! grep -q 'MISSING-PUB' "$CAPTURE_LOG"
}

@test "driver: a single-hop target reports no chain" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
    bash -c "source '$SSH_FILE'; ssh-setup-remote plain"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ProxyJump chain detected"* ]]
}

@test "driver: still rejects anything other than exactly one argument" {
  # tsnet execvp's `ssh-setup-remote "$1"` — the one-arg contract is load-bearing.
  run _ssh_run bash 'ssh-setup-remote'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: ssh-setup-remote"* ]]
  run _ssh_run bash 'ssh-setup-remote a b'
  [ "$status" -eq 1 ]
}

# ── Windows remotes ───────────────────────────────────────────────────────

@test "windows remote: an admin account gets administrators_authorized_keys + icacls" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
    FAKE_WINDOWS=1 FAKE_WINDOWS_ADMIN=1 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote winbox"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ada is in the remote Administrators group"* ]]
  # No ssh-copy-id on Windows — it does not exist there.
  ! grep -q 'ssh-copy-id' "$CAPTURE_LOG"
  grep -q "administrators_authorized_keys" "$PS_LOG"
  grep -q "icacls" "$PS_LOG"
  grep -q "SYSTEM:F" "$PS_LOG"
}

@test "windows remote: a non-admin account gets ~/.ssh/authorized_keys" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
    FAKE_WINDOWS=1 FAKE_WINDOWS_ADMIN=0 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote winbox"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Administrators group"* ]]
  grep -q "USERPROFILE" "$PS_LOG"
}

@test "windows remote: a quote in the key comment survives PowerShell embedding" {
  ssh-keygen -q -t ed25519 -N '' -C "ada@mac -> ada's box" -f "$FAKE_HOME/.ssh/q" </dev/null
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/q" \
    FAKE_WINDOWS=1 FAKE_WINDOWS_ADMIN=0 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote winbox"
  [ "$status" -eq 0 ]
  # Single quotes are doubled, not escaped, inside a PowerShell '...' literal.
  grep -q "ada''s box" "$PS_LOG"
}

# ── _ssh_cfg_py (previously untested) ─────────────────────────────────────

@test "cfg_py find: reports rc 3 for an unknown alias" {
  : > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash '_ssh_cfg_py find nosuchhost ""'
  [ "$status" -eq 3 ]
  [[ "$output" == *"found=0"* ]]
}

@test "cfg_py find: locates a Host defined in an Included drop-in" {
  mkdir -p "$FAKE_HOME/.ssh/config.d"
  printf 'Include ~/.ssh/config.d/*\n' > "$FAKE_HOME/.ssh/config"
  printf 'Host box\n    HostName 10.0.0.1\n' > "$FAKE_HOME/.ssh/config.d/host_box"
  run _ssh_run bash '_ssh_cfg_py find box ""'
  [ "$status" -eq 0 ]
  [[ "$output" == *"found=1"* ]]
  [[ "$output" == *"host_box"* ]]
  [[ "$output" == *"has_identityfile=0"* ]]
}

@test "cfg_py find: a wildcard Host pattern never matches" {
  printf 'Host *\n    IdentitiesOnly yes\n' > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash '_ssh_cfg_py find "*" ""'
  [ "$status" -eq 3 ]
}

@test "cfg_py insert: replace swaps the existing IdentityFile in place" {
  printf 'Host box\n    HostName 10.0.0.1\n    IdentityFile ~/.ssh/old\n' > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash "_ssh_cfg_py insert '$FAKE_HOME/.ssh/config' box '$FAKE_HOME/.ssh/new' replace"
  [ "$status" -eq 0 ]
  grep -q 'IdentityFile.*new' "$FAKE_HOME/.ssh/config"
  ! grep -q 'IdentityFile.*old' "$FAKE_HOME/.ssh/config"
  grep -q 'HostName 10.0.0.1' "$FAKE_HOME/.ssh/config"
}

@test "cfg_py insert: add keeps both keys, --identities-only appends the flag" {
  printf 'Host box\n    IdentityFile ~/.ssh/old\n' > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash "_ssh_cfg_py insert '$FAKE_HOME/.ssh/config' box '$FAKE_HOME/.ssh/new' add --identities-only"
  [ "$status" -eq 0 ]
  grep -q 'IdentityFile.*old' "$FAKE_HOME/.ssh/config"
  grep -q 'IdentityFile.*new' "$FAKE_HOME/.ssh/config"
  grep -q 'IdentitiesOnly yes' "$FAKE_HOME/.ssh/config"
}

@test "cfg_py insert: a ProxyJump line in the block is preserved" {
  # The whole point of Mode B — editing must not disturb the jump wiring.
  printf 'Host zr\n    HostName 10.0.0.2\n    ProxyJump zr-windows\n' > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash "_ssh_cfg_py insert '$FAKE_HOME/.ssh/config' zr '$FAKE_HOME/.ssh/k' insert"
  [ "$status" -eq 0 ]
  grep -q 'ProxyJump zr-windows' "$FAKE_HOME/.ssh/config"
  grep -q 'IdentityFile' "$FAKE_HOME/.ssh/config"
}

@test "cfg_py add-include: wires config.d in and is idempotent" {
  printf 'Host box\n    HostName 10.0.0.1\n' > "$FAKE_HOME/.ssh/config"
  run _ssh_run bash '_ssh_cfg_py ensure-include'
  [ "$status" -eq 1 ]
  run _ssh_run bash '_ssh_cfg_py add-include'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Include' "$FAKE_HOME/.ssh/config")" -eq 1 ]
  run _ssh_run bash '_ssh_cfg_py ensure-include'
  [ "$status" -eq 0 ]
  run _ssh_run bash '_ssh_cfg_py add-include'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Include' "$FAKE_HOME/.ssh/config")" -eq 1 ]
}

# ── Connection multiplexing ───────────────────────────────────────────────
#
# These exist because the ControlPath bug shipped undetected: every test above
# sets SSH_SETUP_ASSUME_YES=1, which returns from _ssh_setup_mux_start before
# a path is ever built, so the whole feature had zero coverage. On macOS the
# obvious "$TMPDIR/ssh-setup.XXXXXX/%C" is 107 bytes against a 104-byte
# sockaddr_un limit, and ssh then failed EVERY connection with rc 255.

# Expand a ControlPath template the way ssh would, so the length assertion
# measures the socket path that actually reaches bind(2).
_expanded_len() {
  local p="${1/\%C/0000000000000000000000000000000000000000}"
  printf '%s' "${#p}"
}

@test "mux: the ControlPath stays inside the 104-byte sockaddr_un limit" {
  local sh
  for sh in bash zsh; do
    run env HOME="$FAKE_HOME" \
      "$sh" -c "source '$SSH_FILE'; _ssh_setup_mux_start; printf '%s' \"\$_SSH_SETUP_MUX_PATH\"; _ssh_setup_mux_stop"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(_expanded_len "$output")" -lt 104 ]
  done
}

@test "mux: a long TMPDIR does not push the ControlPath over the limit" {
  # The real macOS shape: /var/folders/<2>/<26>/T/ is ~49 bytes on its own.
  local long="$SSH_TMP/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "$long"
  run env HOME="$FAKE_HOME" TMPDIR="$long" \
    bash -c "source '$SSH_FILE'; _ssh_setup_mux_start; printf '%s' \"\$_SSH_SETUP_MUX_PATH\"; _ssh_setup_mux_stop"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(_expanded_len "$output")" -lt 104 ]
}

@test "mux: no short enough base degrades to no multiplexing, not a broken path" {
  # Force every candidate to be rejected; the wizard must still run.
  run env HOME="$FAKE_HOME" \
    bash -c "source '$SSH_FILE'; _SSH_SETUP_MUX_MAXDIR=1; _ssh_setup_mux_start; printf 'rc=%s path=[%s]' \"\$?\" \"\$_SSH_SETUP_MUX_PATH\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"path=[]"* ]]
}

@test "mux: SSH_SETUP_NO_MUX=1 opts out entirely" {
  run env HOME="$FAKE_HOME" SSH_SETUP_NO_MUX=1 \
    bash -c "source '$SSH_FILE'; _ssh_setup_mux_start; printf 'path=[%s]' \"\$_SSH_SETUP_MUX_PATH\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"path=[]"* ]]
}

# ── Transport errors must not masquerade as "unknown OS" ──────────────────

@test "probe: an unreachable host is reported as unreachable, not unknown" {
  run env HOME="$FAKE_HOME" FAKE_WINDOWS=0 FAKE_UNREACHABLE=1 \
    bash -c "source '$SSH_FILE'; _ssh_setup_probe_kind deadhost"
  [ "$status" -eq 0 ]
  [[ "$output" == "unreachable" ]]
}

@test "probe: the real stderr survives instead of being sent to /dev/null" {
  run env HOME="$FAKE_HOME" FAKE_UNREACHABLE=1 \
    bash -c "source '$SSH_FILE'; _ssh_setup_probe_kind deadhost >/dev/null; _ssh_setup_err_summary; _ssh_setup_err_cleanup"
  [ "$status" -eq 0 ]
  [[ "$output" == *"connect failed"* ]]
}

@test "driver: an unreachable hop does not ask whether it is a Windows box" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" FAKE_UNREACHABLE=1 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote nojump"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Windows (OpenSSH sshd) machine?"* ]]
  [[ "$output" == *"Cannot connect to nojump"* ]]
}

# ── A failed install must not swallow the local config step ───────────────

@test "driver: a failed key install still offers the local ~/.ssh/config edit" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" FAKE_UNREACHABLE=1 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote nojump"
  # Overall failure is still reported ...
  [ "$status" -eq 1 ]
  [[ "$output" == *"Done, with errors"* ]]
  # ... but step 3 ran, which is the part the user actually noticed missing.
  [[ "$output" == *"--- Local SSH config ---"* ]]
  grep -q 'Host nojump' "$FAKE_HOME/.ssh/config"
  grep -q "IdentityFile $FAKE_HOME/.ssh/k" "$FAKE_HOME/.ssh/config"
}

@test "driver: an unreachable hop never tries to copy the key pair to it" {
  _mkkey k
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" FAKE_UNREACHABLE=1 \
    bash -c "source '$SSH_FILE'; ssh-setup-remote nojump"
  [[ "$output" != *"--- Copy key pair to remote ---"* ]]
}

# ── Prompt layer ──────────────────────────────────────────────────────────

@test "prompt: defaults are honoured under SSH_SETUP_ASSUME_YES" {
  local sh
  for sh in bash zsh; do
    run env SSH_SETUP_ASSUME_YES=1 "$sh" -c "source '$SSH_FILE'
      _ssh_setup_confirm 'a?' yes && printf 'A=y ' || printf 'A=n '
      _ssh_setup_confirm 'b?' no  && printf 'B=y ' || printf 'B=n '
      _ssh_setup_input 'L' 'dflt';         printf 'I=%s ' \"\$_SSH_SETUP_REPLY\"
      _ssh_setup_choose 'H' 'replace' replace add skip; printf 'C=%s' \"\$_SSH_SETUP_REPLY\""
    [[ "$output" == *"A=y "* ]]
    [[ "$output" == *"B=n "* ]]
    [[ "$output" == *"I=dflt "* ]]
    [[ "$output" == *"C=replace"* ]]
  done
}

@test "prompt: piped answers are read, and an empty answer takes the default" {
  local sh
  for sh in bash zsh; do
    run env SSH_SETUP_NO_GUM=1 "$sh" -c "printf 'n\ny\nmine\n2\n' | { source '$SSH_FILE'
      _ssh_setup_confirm 'a?' yes && printf 'A=y ' || printf 'A=n '
      _ssh_setup_confirm 'b?' no  && printf 'B=y ' || printf 'B=n '
      _ssh_setup_input 'L' 'dflt';         printf 'I=%s ' \"\$_SSH_SETUP_REPLY\"
      _ssh_setup_choose 'H' 'replace' replace add skip; printf 'C=%s' \"\$_SSH_SETUP_REPLY\"; }"
    [[ "$output" == *"A=n "* ]]
    [[ "$output" == *"B=y "* ]]
    [[ "$output" == *"I=mine "* ]]
    [[ "$output" == *"C=add"* ]]

    run env SSH_SETUP_NO_GUM=1 "$sh" -c "printf '\n\n\n\n' | { source '$SSH_FILE'
      _ssh_setup_confirm 'a?' yes && printf 'A=y ' || printf 'A=n '
      _ssh_setup_input 'L' 'dflt';         printf 'I=%s ' \"\$_SSH_SETUP_REPLY\"
      _ssh_setup_choose 'H' 'replace' replace add skip; printf 'C=%s' \"\$_SSH_SETUP_REPLY\"; }"
    [[ "$output" == *"A=y "* ]]
    [[ "$output" == *"I=dflt "* ]]
    [[ "$output" == *"C=replace"* ]]
  done
}

@test "prompt: gum is never invoked when stdin is not a terminal" {
  # gum needs a tty; the wizard must fall back rather than hang or crash when
  # it is piped, which is how the bats suite and `tsnet` drive it.
  cat > "$BATS_STUB_DIR/gum" <<'EOF'
#!/usr/bin/env bash
echo "GUM-WAS-CALLED $*" >> "$CAPTURE_LOG"
exit 1
EOF
  chmod +x "$BATS_STUB_DIR/gum"
  run env SSH_SETUP_NO_GUM=0 bash -c "printf 'y\n' | { source '$SSH_FILE'; _ssh_setup_confirm 'q?' yes; }"
  ! grep -q 'GUM-WAS-CALLED' "$CAPTURE_LOG"
}

@test "driver: a working Windows hop counts as already set up (rc 1, not 255)" {
  # `true` is not a cmd.exe builtin, so a perfectly authenticated Windows hop
  # answers 1. Only 255 means ssh itself could not get in.
  _mkkey k
  cat > "$BATS_STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-G" ]; then printf 'hostname %s\n' "$2"; exit 0; fi
echo "ssh $*" >> "$CAPTURE_LOG"
last="${!#}"
[ "$last" = "true" ] && exit 1     # authenticated; cmd.exe just has no `true`
exit 255
EOF
  chmod +x "$BATS_STUB_DIR/ssh"
  run env HOME="$FAKE_HOME" SSH_CFG_ROOT="$FAKE_HOME/.ssh/config" \
    SSH_SETUP_ASSUME_YES=1 SSH_SETUP_KEY="$FAKE_HOME/.ssh/k" \
    bash -c "source '$SSH_FILE'; ssh-setup-remote winbox"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already accepts key-based login"* ]]
  [[ "$output" == *"Skipped."* ]]
}
