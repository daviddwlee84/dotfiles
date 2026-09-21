#!/usr/bin/env bats

load "../test_helper.bash"

@test "personal tool installer ownership and atomic-update fixtures" {
  run python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p test_personal_tools.py -v
  [ "$status" -eq 0 ]
}

@test "personal tool prompt migration preserves explicit intent" {
  command -v uv >/dev/null || skip "uv unavailable"
  run uv run --no-project --with rich --with questionary --with tyro python -m unittest discover -s "$REPO_ROOT/tests/unit" -p test_personal_tools_prompts.py -v
  [ "$status" -eq 0 ]
}
