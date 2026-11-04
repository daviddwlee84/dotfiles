#!/usr/bin/env bats

load "../test_helper.bash"

@test "uv config preserves optional cache and mirror settings" {
  command -v chezmoi >/dev/null || skip "chezmoi unavailable"
  run python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p test_uv_config.py -v
  [ "$status" -eq 0 ]
}
