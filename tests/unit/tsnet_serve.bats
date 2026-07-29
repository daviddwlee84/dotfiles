#!/usr/bin/env bats
# Unit tests for `tsnet serve` / `tsnet doctor` — the preflight state machine.
#
# All offline. Two stubbing strategies, for a reason:
#
#   * LOCAL checks stub `tailscale` in $BATS_STUB_DIR.
#   * The Linux-vs-Darwin operator check is exercised through `--host`, with
#     `ssh` stubbed to emit a canned probe. tsnet reads the local platform via
#     os.uname() (a syscall, not the uname binary), so there is no honest way to
#     fake Darwin/Linux locally — and routing through --host has the bonus of
#     covering the remote code path, including the sentinel parser.
#
# The assertion that matters most in nearly every test is the NEGATIVE one:
# `tailscale serve` must never appear in the recorded argv when a check failed.

load "../test_helper.bash"

TSNET_SRC="$REPO_ROOT/dot_dotfiles/bin/executable_tsnet"

setup() {
    setup_path_stub
    TS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsnet-serve.XXXXXX")"
    export TS_TMP
    _status_json '"CertDomains": ["my-mac.tailtest.ts.net"]'
    echo '{}' > "$TS_TMP/serve.json"
    echo '{}' > "$TS_TMP/prefs.json"
    _stub_tailscale
}

teardown() {
    [ -n "$TS_TMP" ] && rm -rf "$TS_TMP"
    cleanup_path_stubs
}

tsnet() { uv run --quiet --script "$TSNET_SRC" "$@"; }

_stub_tailscale() {
    cat > "$BATS_STUB_DIR/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TS_TMP/tailscale.argv"
case "$1 $2" in
  "status --json") cat "$TS_TMP/status.json" ;;
  "serve status")  cat "$TS_TMP/serve.json" ;;
  "debug prefs")   cat "$TS_TMP/prefs.json" ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_STUB_DIR/tailscale"
}

_status_json() {
    cat > "$TS_TMP/status.json" <<EOF
{
  "BackendState": "Running",
  "MagicDNSSuffix": "tailtest.ts.net",
  "Health": [],
  ${1},
  "CurrentTailnet": {"Name": "unit.test", "MagicDNSEnabled": true},
  "Self": {
    "HostName": "my-mac",
    "DNSName": "my-mac.tailtest.ts.net.",
    "TailscaleIPs": ["100.10.0.1"],
    "OS": "macOS",
    "Online": true
  },
  "Peer": {}
}
EOF
}

# A stub `ssh` that replays the batched probe tsnet expects. $1 selects the
# platform fixture; prefs content comes from $TS_TMP/prefs.json.
_stub_ssh() {
    local uname_s="$1" user="${2:-tester}" uid="${3:-1000}"
    cat > "$BATS_STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$TS_TMP/ssh.argv"
echo
echo "---TSNET-PLATFORM---"; echo "$uname_s"; echo "$user"; echo "$uid"
echo
echo "---TSNET-STATUS---";   cat "\$TS_TMP/status.json"
echo
echo "---TSNET-SERVE---";    cat "\$TS_TMP/serve.json"
echo
echo "---TSNET-PREFS---";    cat "\$TS_TMP/prefs.json"
echo
echo "---TSNET-LISTEN---";   echo "LISTEN 0 128 127.0.0.1:8787 0.0.0.0:*"
echo
echo "---TSNET-END---"
EOF
    chmod +x "$BATS_STUB_DIR/ssh"
}

# Did tsnet actually MUTATE anything? Must match the write (`serve --bg …`)
# and not the preflight's own read (`serve status --json`), which also starts
# with "serve".
_served() { grep -q '^serve --bg' "$TS_TMP/tailscale.argv" 2>/dev/null; }

# ------------------------------------------------------------------ certs

@test "certs disabled: exit 6, remediation names the admin console, nothing served" {
    _status_json '"CertDomains": null'
    run tsnet serve 8787 --allow-no-listener
    [ "$status" -eq 6 ]
    [[ "$output" == *"login.tailscale.com/admin/dns"* ]]
    [[ "$output" == *"CANNOT be automated"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "certs enabled but this node not covered: exit 6, nothing served" {
    _status_json '"CertDomains": ["someone-else.tailtest.ts.net"]'
    run tsnet serve 8787 --allow-no-listener
    [ "$status" -eq 6 ]
    [[ "$output" == *"not covered"* ]] || [[ "$output" == *"NOT in CertDomains"* ]]
    [[ "$output" == *"someone-else.tailtest.ts.net"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "backend not running: exit 3, nothing served" {
    _status_json '"CertDomains": ["my-mac.tailtest.ts.net"]'
    sed -i.bak 's/"BackendState": "Running"/"BackendState": "NeedsLogin"/' "$TS_TMP/status.json"
    run tsnet serve 8787 --allow-no-listener
    [ "$status" -eq 3 ]
    run _served
    [ "$status" -ne 0 ]
}

# --------------------------------------------------------------- listener

@test "nothing listening on the target port: exit 8, nothing served" {
    # 1 is a privileged port nothing in a test env binds.
    run tsnet serve 1
    [ "$status" -eq 8 ]
    [[ "$output" == *"502s on every request"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "--allow-no-listener proceeds past the listener check" {
    run tsnet serve 1 --dry-run --allow-no-listener
    [ "$status" -eq 0 ]
    [[ "$output" == *"tailscale serve --bg --https=443 http://127.0.0.1:1"* ]]
}

# ------------------------------------------------------------------- :443

@test "443 already mapped to a different target: exit 9, nothing served" {
    cat > "$TS_TMP/serve.json" <<'EOF'
{"Web": {"my-mac.tailtest.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}}}
EOF
    run tsnet serve 8787 --allow-no-listener
    [ "$status" -eq 9 ]
    [[ "$output" == *"127.0.0.1:3000"* ]]
    [[ "$output" == *"--force"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "443 already mapped to OUR target: exit 0 no-op, nothing served" {
    cat > "$TS_TMP/serve.json" <<'EOF'
{"Web": {"my-mac.tailtest.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8787"}}}}}
EOF
    run tsnet serve 8787 --allow-no-listener
    [ "$status" -eq 0 ]
    [[ "$output" == *"already serving"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "unreadable serve config is treated as UNKNOWN, never as free" {
    _stub_ssh Linux
    printf 'not json at all\n' > "$TS_TMP/serve.json"
    printf '{"OperatorUser": "tester"}\n' > "$TS_TMP/prefs.json"
    run tsnet --host somebox doctor
    [[ "$output" == *"UNKNOWN, not free"* ]]
}

# --------------------------------------------------------------- operator

@test "operator check is skipped on Darwin" {
    _stub_ssh Darwin admin 501
    run tsnet --host somebox doctor
    [[ "$output" == *"operator"* ]]
    [[ "$output" == *"not applicable on Darwin"* ]]
}

@test "operator unset on Linux: exit 7 with the sudo command pre-filled" {
    # OperatorUser is json:\",omitempty\" -- an ABSENT key is the unset state,
    # which is what a real box actually returns. Test that shape, not "".
    _stub_ssh Linux
    printf '{"ControlURL": "https://controlplane.tailscale.com"}\n' > "$TS_TMP/prefs.json"
    run tsnet --host somebox serve 8787 --allow-no-listener
    [ "$status" -eq 7 ]
    [[ "$output" == *"ssh somebox 'sudo tailscale set --operator=\$USER'"* ]]
}

@test "operator set to the current user passes on Linux" {
    _stub_ssh Linux
    printf '{"OperatorUser": "tester"}\n' > "$TS_TMP/prefs.json"
    run tsnet --host somebox doctor
    [ "$status" -eq 0 ]
}

@test "running as root on Linux passes without an operator" {
    _stub_ssh Linux root 0
    run tsnet --host somebox doctor
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------ funnel

@test "funnel enabled warns loudly but does not fail" {
    cat > "$TS_TMP/serve.json" <<'EOF'
{"AllowFunnel": {"my-mac.tailtest.ts.net:443": true}}
EOF
    run tsnet doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"PUBLIC INTERNET"* ]]
    [[ "$output" == *"funnel --https=443 off"* ]]
}

# ------------------------------------------------------------- dry-run/json

@test "--dry-run prints the exact command and invokes no write" {
    run tsnet serve 8787 --dry-run --allow-no-listener
    [ "$status" -eq 0 ]
    [[ "$output" == *"tailscale serve --bg --https=443 http://127.0.0.1:8787"* ]]
    run _served
    [ "$status" -ne 0 ]
}

@test "--dry-run with --path uses --set-path" {
    run tsnet serve 8787 --path /mcp --dry-run --allow-no-listener
    [ "$status" -eq 0 ]
    [[ "$output" == *"--set-path /mcp"* ]]
}

@test "doctor --json is a scriptable gate and mutates nothing" {
    _status_json '"CertDomains": null'
    run bash -c "uv run --quiet --script '$TSNET_SRC' doctor --json"
    [ "$status" -eq 6 ]
    run bash -c "uv run --quiet --script '$TSNET_SRC' doctor --json | jq -e '.ok == false'"
    [ "$status" -eq 0 ]
    run bash -c "uv run --quiet --script '$TSNET_SRC' doctor --json | jq -r '.checks[] | select(.id==\"certs\") | .status'"
    [ "$output" = "fail" ]
    run _served
    [ "$status" -ne 0 ]
}

@test "doctor passes cleanly when every precondition is met" {
    run tsnet doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready"* ]]
}

# -------------------------------------------------------------------- misc

@test "a truncated remote probe is an error, not a silent empty read" {
    cat > "$BATS_STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
echo
echo "---TSNET-PLATFORM---"; echo Linux; echo tester; echo 1000
echo
echo "---TSNET-STATUS---"; echo '{}'
EOF
    chmod +x "$BATS_STUB_DIR/ssh"
    run tsnet --host somebox doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"truncated"* ]]
}

@test "a remote without tailscale installed is a clean exit 2" {
    # The local no-binary path cannot be tested honestly on a Mac: find_tailscale
    # deliberately falls back to /usr/local/bin/tailscale and the app bundle
    # (the cask wrapper lives there and PATH is often minimal), so the real
    # binary is always found. The remote path exercises the same exit.
    cat > "$BATS_STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
echo "TSNET_NO_TAILSCALE"
exit 127
EOF
    chmod +x "$BATS_STUB_DIR/ssh"
    run tsnet --host somebox doctor
    [ "$status" -eq 2 ]
    [[ "$output" == *"not installed on somebox"* ]]
    [[ "$output" != *"Traceback"* ]]
}
