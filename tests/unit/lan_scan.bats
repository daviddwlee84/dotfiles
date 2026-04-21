#!/usr/bin/env bats
# Unit tests for pure helpers in
# dot_config/television/executable_lan-scan.sh.
#
# We cover only the functions that are pure string / IP logic — the network
# probes (arp-scan, nmap, ping, dig) are out of scope. Bugs in these pure
# helpers are silent-regression-risk: a mis-filter in `is_usable_ip` silently
# drops real hosts from LAN scans; a mis-normalised MAC prefix silently
# mis-attributes a vendor.
#
# The script dispatches at the bottom (line 325+), so bare `source` runs the
# "all" command and tries to probe the network. Work around by sourcing with
# the `clean` subcommand, pointing XDG_CACHE_HOME at an isolated tempdir so
# clean just wipes our scratch space. After `clean` returns, the function
# definitions are left in scope.

load "../test_helper.bash"

LAN_SCAN="$REPO_ROOT/dot_config/television/executable_lan-scan.sh"

# Build the prologue that sources the script in `clean` mode against an
# isolated cache dir. Call this inside `bash -c "..."` bodies.
_source_prologue() {
  cat <<EOF
export XDG_CACHE_HOME="$BATS_STUB_DIR/tv-cache"
export HOME="$BATS_STUB_DIR/home"
mkdir -p "\$HOME" "\$XDG_CACHE_HOME"
source '$LAN_SCAN' clean >/dev/null 2>&1
set +u
EOF
}

@test "is_usable_ip: accepts normal /24 host addresses" {
  setup_path_stub
  run bash -c "
    $(_source_prologue)
    for ip in 192.168.1.1 192.168.1.50 10.0.0.42 172.16.3.99; do
      if is_usable_ip \"\$ip\"; then echo \"ok:\$ip\"; else echo \"rejected:\$ip\"; fi
    done
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok:192.168.1.1"* ]]
  [[ "$output" == *"ok:192.168.1.50"* ]]
  [[ "$output" == *"ok:10.0.0.42"* ]]
  [[ "$output" == *"ok:172.16.3.99"* ]]
  [[ "$output" != *"rejected:"* ]]
}

@test "is_usable_ip: rejects link-local, multicast, broadcast, network" {
  setup_path_stub
  run bash -c "
    $(_source_prologue)
    for ip in \
      169.254.1.1 \
      169.254.100.5 \
      224.0.0.1 \
      239.255.255.250 \
      255.255.255.255 \
      0.0.0.0 \
      192.168.1.0 \
      192.168.1.255; do
      if is_usable_ip \"\$ip\"; then echo \"unexpected-ok:\$ip\"; else echo \"rejected:\$ip\"; fi
    done
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"unexpected-ok:"* ]]
  # Spot-check specific junk categories were explicitly rejected.
  [[ "$output" == *"rejected:169.254.1.1"* ]]
  [[ "$output" == *"rejected:224.0.0.1"* ]]
  [[ "$output" == *"rejected:192.168.1.0"* ]]
  [[ "$output" == *"rejected:192.168.1.255"* ]]
}

@test "is_usable_ip: rejects empty input" {
  setup_path_stub
  run bash -c "
    $(_source_prologue)
    if is_usable_ip ''; then echo ok; else echo rejected; fi
  "
  [[ "$output" == "rejected" ]]
}

@test "vendor_for_mac: looks up vendor in nmap-style OUI DB" {
  setup_path_stub
  cat > "$BATS_STUB_DIR/oui.db" <<'EOF'
001122 AcmeNetworks Inc.
00B0C6 CiscoSystems Routing
AABBCC ZetaCorp
EOF

  run bash -c "
    $(_source_prologue)
    # Override OUI_DB to point at our fake db. The script sets it at source
    # time via find_oui_db() which only succeeds if the real nmap OUI file
    # exists on this machine.
    OUI_DB='$BATS_STUB_DIR/oui.db'
    vendor_for_mac '00:11:22:aa:bb:cc'
    echo '---'
    vendor_for_mac '00-B0-C6-12-34-56'
    echo '---'
    vendor_for_mac 'aabbcc112233'
    echo '---'
    vendor_for_mac '00:00:00:00:00:00'
    echo '---'
    vendor_for_mac ''
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"AcmeNetworks Inc."* ]]
  [[ "$output" == *"CiscoSystems Routing"* ]]
  [[ "$output" == *"ZetaCorp"* ]]
}

@test "vendor_for_mac: returns nothing when prefix is too short" {
  setup_path_stub
  : > "$BATS_STUB_DIR/oui.db"

  result="$(bash -c "
    $(_source_prologue)
    OUI_DB='$BATS_STUB_DIR/oui.db'
    vendor_for_mac '01:02'
  ")"
  [ -z "$result" ]
}
