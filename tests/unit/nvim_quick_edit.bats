#!/usr/bin/env bats
load '../test_helper.bash'

@test "quick-edit recognizes Windows temp paths, boundaries and explicit overrides" {
  command -v nvim >/dev/null 2>&1 || skip 'nvim is not installed'
  run env NVIM_QUICK_EDIT_SOURCE="$REPO_ROOT/dot_config/nvim/lua/config/autocmds.lua" \
    nvim --clean --headless -u NONE -l "$REPO_ROOT/tests/fixtures/nvim_quick_edit_probe.lua"
  [ "$status" -eq 0 ]
  [[ "$output" == *'11 cases passed'* ]]
}
