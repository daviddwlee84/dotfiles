#!/usr/bin/env bats

load "../test_helper.bash"

setup() {
  setup_path_stub
  printf '#!/bin/sh\nexit 0\n' >"$BATS_STUB_DIR/sesh"
  chmod +x "$BATS_STUB_DIR/sesh"
  SESH_LIB="$REPO_ROOT/dot_config/shell/22_sesh.sh"
}

@test "SpecStory exit wrapper injects run id and finalizes before kill" {
  run bash -c 'source "$1"; _sesh_on_exit_wrap "specstory run claude" kill' _ "$SESH_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *'DEV_AGENT_RUN_ID="$_dev_agent_run_id" specstory run claude'* ]]
  [[ "$output" == *'command dev artifact finalize --run-id "$_dev_agent_run_id" --if-pending --writer-stopped'* ]]
  [[ "$output" == *'artifact finalization blocked — staying in shell'* ]]
  [[ "$output" == *'exit $_dev_agent_rc'* ]]
}

@test "restart checks finalization before announcing respawn" {
  run bash -c 'source "$1"; _sesh_on_exit_wrap "specstory run codex" restart' _ "$SESH_LIB"
  [ "$status" -eq 0 ]
  finalize_pos="${output%%command dev artifact finalize*}"
  respawn_pos="${output%%respawning in 1s*}"
  [ "${#finalize_pos}" -lt "${#respawn_pos}" ]
}

@test "non-SpecStory commands keep the original exit wrapper" {
  run bash -c 'source "$1"; _sesh_on_exit_wrap "opencode" kill' _ "$SESH_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *'opencode'* ]]
  [[ "$output" != *'artifact finalize'* ]]
  [[ "$output" != *'DEV_AGENT_RUN_ID'* ]]
}
