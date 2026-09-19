#!/usr/bin/env bats
load "../test_helper.bash"

@test "dotnet recipe handles startup failures, repeat apply, and opt-in rendering" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v ansible-playbook >/dev/null || skip "ansible-playbook required"
  command -v chezmoi >/dev/null || skip "chezmoi required"
  run python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p test_dotnet_tools.py -v
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
