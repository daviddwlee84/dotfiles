#!/usr/bin/env bats
# Unit tests for `tsnet ssh-config` — the managed-block writer.
#
# Everything here is offline: `tailscale` is stubbed in $BATS_STUB_DIR and the
# ssh-config tree lives in a temp dir addressed via $SSH_CFG_ROOT. No tailnet,
# no network, no writes anywhere near the real ~/.ssh.
#
# The fixture deliberately reproduces all four shapes that bite a casual reading
# of `tailscale status --json`, because all four are live on a real tailnet:
#   * `Peer` is a DICT keyed by nodekey, not a list
#   * every `DNSName` carries a trailing dot
#   * nodes from more than one tailnet appear
#   * untagged nodes have NO `Tags` key at all

load "../test_helper.bash"

TSNET_SRC="$REPO_ROOT/dot_dotfiles/bin/executable_tsnet"

setup() {
    setup_path_stub
    TS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsnet-ssh.XXXXXX")"
    export TS_TMP
    mkdir -p "$TS_TMP/config.d"
    _write_status_fixture
    _stub_tailscale
    # Keep the real ~/.ssh completely out of reach.
    export SSH_CFG_ROOT="$TS_TMP/config"
    OUT="$TS_TMP/config.d/20-tailscale"
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
  "serve status")  cat "$TS_TMP/serve.json" 2>/dev/null || echo '{}' ;;
  "debug prefs")   cat "$TS_TMP/prefs.json" 2>/dev/null || echo '{}' ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_STUB_DIR/tailscale"
}

_write_status_fixture() {
    cat > "$TS_TMP/status.json" <<'EOF'
{
  "BackendState": "Running",
  "MagicDNSSuffix": "tailtest.ts.net",
  "CertDomains": null,
  "Health": [],
  "CurrentTailnet": {"Name": "unit.test", "MagicDNSEnabled": true},
  "Self": {
    "HostName": "my-mac",
    "DNSName": "my-mac.tailtest.ts.net.",
    "TailscaleIPs": ["100.10.0.1", "fd7a:115c::1"],
    "OS": "macOS",
    "Online": true
  },
  "Peer": {
    "nodekey:aaa": {
      "HostName": "David-Ubuntu",
      "DNSName": "david-ubuntu.tailtest.ts.net.",
      "TailscaleIPs": ["100.20.0.2"],
      "OS": "linux",
      "Online": true
    },
    "nodekey:bbb": {
      "HostName": "ta-stg",
      "DNSName": "ta-stg.tailtest.ts.net.",
      "TailscaleIPs": ["100.30.0.3"],
      "OS": "linux",
      "Online": false,
      "Tags": ["tag:server", "tag:prod"]
    },
    "nodekey:ccc": {
      "HostName": "stranger",
      "DNSName": "stranger.othertail.ts.net.",
      "TailscaleIPs": ["100.40.0.4"],
      "OS": "linux",
      "Online": true
    }
  }
}
EOF
}

# `Include` must come before any Host block, otherwise ssh scopes it to that
# block -- see tsnet's reachability() and dot_ssh/create_private_config.
_reachable_root() {
    printf 'Include %s/config.d/*\n\nHost manual\n    HostName manual.invalid\n' \
        "$TS_TMP" > "$TS_TMP/config"
}

_legacy_root() {
    printf 'Host manual\n    HostName manual.invalid\n' > "$TS_TMP/config"
}

# --------------------------------------------------------------- rendering

@test "renders the expected block" {
    _reachable_root
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify \
        --hostname-style magicdns
    [ "$status" -eq 0 ]
    grep -q '^# BEGIN tsnet ssh-config v1' "$OUT"
    grep -q '^Host david-ubuntu$' "$OUT"
    grep -q '^    HostName david-ubuntu.tailtest.ts.net$' "$OUT"
    grep -q '^    # tailscale IP: 100.20.0.2$' "$OUT"
    grep -q '^    User dave$' "$OUT"
    grep -q '^# END tsnet ssh-config$' "$OUT"
}

@test "hostname-style auto falls back to the IP when MagicDNS does not resolve" {
    # The fixture tailnet is fake, so getaddrinfo() fails -- which is exactly
    # the dns-forward-failing case `auto` exists for. A stale MagicDNS name in
    # ssh config fails confusingly; the IP at least connects.
    _reachable_root
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 0 ]
    grep -q '^    HostName 100.20.0.2$' "$OUT"
    grep -q 'fallback: MagicDNS name david-ubuntu.tailtest.ts.net not used' "$OUT"
}

@test "hostname-style ip is honoured and still records the MagicDNS name" {
    _reachable_root
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify --hostname-style ip
    [ "$status" -eq 0 ]
    grep -q '^    HostName 100.20.0.2$' "$OUT"
    grep -q '# MagicDNS name: david-ubuntu.tailtest.ts.net' "$OUT"
}

@test "block carries no timestamp (idempotency depends on it)" {
    _reachable_root
    tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    # Any 4-digit year or HH:MM would make every rerun a diff.
    run grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}:[0-9]{2}' "$OUT"
    [ "$status" -ne 0 ]
}

@test "rerun is byte-identical and does not touch mtime" {
    _reachable_root
    tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    local before after m1 m2
    before="$(cat "$OUT")"
    m1="$(_mtime "$OUT")"
    sleep 1
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 0 ]
    [[ "$output" == *unchanged* ]]
    after="$(cat "$OUT")"
    m2="$(_mtime "$OUT")"
    [ "$before" = "$after" ]
    [ "$m1" = "$m2" ]
}

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

@test "content outside the markers is preserved" {
    _reachable_root
    tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    printf 'Host after-block\n    HostName keep.after\n' >> "$OUT"
    printf 'Host before-block\n    HostName keep.before\n\n' | cat - "$OUT" > "$OUT.n"
    mv "$OUT.n" "$OUT"

    run tsnet ssh-config david-ubuntu ta-stg --out "$OUT" --user other --no-verify
    [ "$status" -eq 0 ]
    grep -q 'keep.before' "$OUT"
    grep -q 'keep.after' "$OUT"
    grep -q '^    User other$' "$OUT"
    grep -q '^Host ta-stg$' "$OUT"
}

@test "malformed markers refuse to write and leave the file byte-identical" {
    _reachable_root
    tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    printf '\n# BEGIN tsnet ssh-config v1 — a second one\n' >> "$OUT"
    local before; before="$(cat "$OUT")"

    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 5 ]
    [[ "$output" == *"Refusing to guess"* ]]
    [ "$before" = "$(cat "$OUT")" ]
}

@test "BEGIN without END is also refused" {
    _reachable_root
    printf '# BEGIN tsnet ssh-config v1 — truncated\nHost x\n' > "$OUT"
    local before; before="$(cat "$OUT")"
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 5 ]
    [ "$before" = "$(cat "$OUT")" ]
}

# ------------------------------------------------------- reachability / legacy

@test "legacy config with no Include: exits 4 and creates nothing" {
    _legacy_root
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --add-include=no --no-verify
    [ "$status" -eq 4 ]
    [[ "$output" == *"SILENT no-op"* ]]
    [ ! -f "$OUT" ]
}

@test "an Include scoped inside a Host block is reported as conditional" {
    printf 'Host manual\n    HostName manual.invalid\n\nInclude %s/config.d/*\n' \
        "$TS_TMP" > "$TS_TMP/config"
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [[ "$output" == *"only Included conditionally"* ]]
    [[ "$output" == *"Host manual"* ]]
}

@test "--add-include=yes fixes reachability and agrees with _ssh_cfg_py" {
    _legacy_root
    # Before: both implementations must say "unreachable".
    run bash -c "source '$REPO_ROOT/dot_config/shell/96_ssh_setup.sh'; _ssh_cfg_py ensure-include"
    [ "$status" -eq 1 ]

    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --add-include=yes --yes --no-verify
    [ "$status" -eq 0 ]
    grep -q 'Include' "$TS_TMP/config"
    [ -f "$OUT" ]

    # After: both must say "reachable". This is the cross-implementation SSOT
    # guard -- tsnet reimplements Include resolution on purpose, so the two
    # copies are kept honest behaviourally rather than by shared code.
    run bash -c "source '$REPO_ROOT/dot_config/shell/96_ssh_setup.sh'; _ssh_cfg_py ensure-include"
    [ "$status" -eq 0 ]
}

@test "--include-position=bottom appends the Include at EOF" {
    _legacy_root
    tsnet ssh-config david-ubuntu --out "$OUT" --user dave \
        --add-include=yes --include-position=bottom --yes --no-verify
    # The last non-blank line must be the Include, not the first.
    run bash -c "grep -n Include '$TS_TMP/config' | cut -d: -f1"
    [ "$output" -gt 1 ]
}

@test "--inline writes into the root config and never creates config.d" {
    rm -rf "$TS_TMP/config.d"
    _legacy_root
    run tsnet ssh-config david-ubuntu --inline --user dave --no-verify
    [ "$status" -eq 0 ]
    grep -q '^Host david-ubuntu$' "$TS_TMP/config"
    grep -q 'manual.invalid' "$TS_TMP/config"
    [ ! -d "$TS_TMP/config.d" ]
}

@test "non-TTY refuses to add the Include without --yes" {
    _legacy_root
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 4 ]
    run grep -c Include "$TS_TMP/config"
    [ "$output" -eq 0 ]
}

# ---------------------------------------------------------- shadow detection

@test "an earlier Host definition is reported as shadowing ours" {
    printf 'Host david-ubuntu\n    HostName impostor.invalid\n\nInclude %s/config.d/*\n' \
        "$TS_TMP" > "$TS_TMP/config"
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"parses BEFORE"* ]]
}

@test "--strict turns a shadowed block into exit 10" {
    printf 'Host david-ubuntu\n    HostName impostor.invalid\n\nInclude %s/config.d/*\n' \
        "$TS_TMP" > "$TS_TMP/config"
    run tsnet ssh-config david-ubuntu --out "$OUT" --user dave --no-verify --strict
    [ "$status" -eq 10 ]
}

@test "--alias-prefix sidesteps the shadow" {
    printf 'Host david-ubuntu\n    HostName impostor.invalid\n\nInclude %s/config.d/*\n' \
        "$TS_TMP" > "$TS_TMP/config"
    run tsnet ssh-config david-ubuntu --out "$OUT" --alias-prefix ts- --user dave --no-verify --strict
    [ "$status" -eq 0 ]
    grep -q '^Host ts-david-ubuntu$' "$OUT"
}

# ----------------------------------------------------------------- User field

@test "User is omitted, not guessed, when it cannot be resolved" {
    _reachable_root
    export FLEET_CONFIG="$TS_TMP/nonexistent.toml"
    run tsnet ssh-config david-ubuntu --out "$OUT" --no-verify
    [ "$status" -eq 0 ]
    run grep -c '^    User ' "$OUT"
    [ "$output" -eq 0 ]
    grep -q 'User: unset' "$OUT"
}

@test "User is picked up from the fleet inventory" {
    _reachable_root
    cat > "$TS_TMP/machines.toml" <<'EOF'
[[hosts]]
name = "ubuntu-box"
ssh_alias = "david-ubuntu"
user = "fleetuser"
EOF
    export FLEET_CONFIG="$TS_TMP/machines.toml"
    run tsnet ssh-config david-ubuntu --out "$OUT" --no-verify
    [ "$status" -eq 0 ]
    grep -q '^    User fleetuser$' "$OUT"
}

# ------------------------------------------------------------ device parsing

@test "--tsv emits exactly 7 columns in the documented order" {
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | awk -F'\t' '{print NF}' | sort -u"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]

    # 0:name 1:fqdn 2:ip 3:os 4:online 5:tailnet 6:tags
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | grep '^David-Ubuntu'"
    [ "$output" = "David-Ubuntu	david-ubuntu.tailtest.ts.net	100.20.0.2	linux	up	tailtest.ts.net	-" ]
}

@test "handles Peer-as-dict, trailing dots, foreign tailnets and absent Tags" {
    # Peer is a dict: 3 peers + self = 4, minus the foreign one = 3.
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | wc -l | tr -d ' '"
    [ "$output" = "3" ]
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv --all-tailnets | wc -l | tr -d ' '"
    [ "$output" = "4" ]
    # Trailing dot stripped.
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | cut -f2 | grep -c '\.$' || true"
    [ "$output" = "0" ]
    # Absent Tags key renders as '-', present Tags are comma-joined.
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | grep '^ta-stg' | cut -f7"
    [ "$output" = "tag:server,tag:prod" ]
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv | grep '^David-Ubuntu' | cut -f7"
    [ "$output" = "-" ]
}

@test "--online-only drops offline devices" {
    run bash -c "uv run --quiet --script '$TSNET_SRC' list --tsv --online-only | cut -f1"
    [[ "$output" != *"ta-stg"* ]]
    [[ "$output" == *"David-Ubuntu"* ]]
}

@test "an unknown machine name is a clean error, not a traceback" {
    _reachable_root
    run tsnet ssh-config no-such-box --out "$OUT" --no-verify
    [ "$status" -ne 0 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" == *"no tailnet device matches"* ]]
}

@test "--host is rejected for ssh-config" {
    run tsnet --host somewhere ssh-config david-ubuntu
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid for"* ]]
}
