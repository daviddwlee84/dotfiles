#!/usr/bin/env bats
# Static and parser-level contracts for the managed git.yazi integration.

load "../test_helper.bash"

PACKAGE="$REPO_ROOT/dot_config/yazi/package.toml"
INIT="$REPO_ROOT/dot_config/yazi/init.lua"
CONFIG="$REPO_ROOT/dot_config/yazi/yazi.toml"
GUARD="$REPO_ROOT/dot_config/yazi/plugins/git-guard.yazi/main.lua"

@test "git.yazi: lockfile pins the reviewed latest revision without comments" {
  [ "$(grep -c '^use = "yazi-rs/plugins:git"$' "$PACKAGE")" -eq 1 ]
  grep -q '^rev = "c591a36"$' "$PACKAGE"
  grep -q '^hash = "5bb0bfab901d3601c370eafdd66edd31"$' "$PACKAGE"
  ! grep -q '^[[:space:]]*#' "$PACKAGE"
}

@test "git.yazi: setup is fail-soft and tells old hosts how to recover" {
  grep -q 'local git_ok, git_err = pcall' "$INIT"
  grep -q 'require("git"):setup({ order = 1500 })' "$INIT"
  grep -q 'Upgrade yazi/ya to 26.8.15+' "$INIT"
  grep -q 'run `ya pkg install`' "$INIT"
}

@test "git.yazi: file and directory fetchers use the compatibility guard" {
  [ "$(grep -c '^id = "git"$' "$CONFIG")" -eq 2 ]
  [ "$(grep -c '^group = "git"$' "$CONFIG")" -eq 2 ]
  [ "$(grep -c '^run = "git-guard"$' "$CONFIG")" -eq 2 ]
  [ "$(grep -c '^url = "\*"$' "$CONFIG")" -eq 1 ]
  [ "$(grep -c '^url = "\*/"$' "$CONFIG")" -eq 1 ]
}

@test "git.yazi: guard caches compatibility and falls back to Yazi noop" {
  grep -q 'available, git = pcall(require, "git")' "$GUARD"
  grep -q 'return plugin:fetch(job)' "$GUARD"
  grep -q 'return require("noop"):fetch(job)' "$GUARD"
}

@test "git.yazi: installed Yazi accepts the managed config" {
  command -v yazi >/dev/null 2>&1 || skip "yazi not installed"
  run env YAZI_CONFIG_HOME="$REPO_ROOT/dot_config/yazi" yazi --debug
  [ "$status" -eq 0 ]
}
