#!/usr/bin/env bats
# Behavioral contracts for the read-only Lazygit branch-insights helper.

load "../test_helper.bash"

SCRIPT="$REPO_ROOT/dot_config/lazygit/executable_branch-insights.sh"
CONFIG="$REPO_ROOT/dot_config/lazygit/config.yml"

gitq() {
  git -C "$TEST_REPO" "$@" >/dev/null 2>&1
}

setup() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lazygit-branch-insights.XXXXXX")"
  TEST_REPO="$TEST_ROOT/repo"
  REMOTE_REPO="$TEST_ROOT/remote.git"
  WORKTREE_REPO="$TEST_ROOT/active-worktree"

  git init --bare "$REMOTE_REPO" >/dev/null
  git -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
  git init -b main "$TEST_REPO" >/dev/null
  gitq config user.name 'Test User'
  gitq config user.email test@example.com
  printf '%s\n' base >"$TEST_REPO/file.txt"
  gitq add file.txt
  gitq commit -m base
  gitq remote add origin "$REMOTE_REPO"
  gitq push -u origin main
  gitq remote set-head origin -a

  gitq branch contained origin/main
  gitq branch gone origin/main
  gitq push -u origin gone
  gitq push origin --delete gone

  printf '%s\n' local-main >>"$TEST_REPO/file.txt"
  gitq add file.txt
  gitq commit -m local-main
  gitq branch local-only

  gitq switch -c feature/unmerged origin/main
  printf '%s\n' feature >"$TEST_REPO/feature.txt"
  gitq add feature.txt
  gitq commit -m feature

  gitq branch worktree-active origin/main
  gitq worktree add "$WORKTREE_REPO" worktree-active
  gitq switch main
}

teardown() {
  git -C "$TEST_REPO" worktree remove --force "$WORKTREE_REPO" >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
  cleanup_path_stubs
}

@test "config enables branch context without adding low-signal hashes" {
  grep -q 'nerdFontsVersion: "3"' "$CONFIG"
  grep -q 'showDivergenceFromBaseBranch: arrowAndNumber' "$CONFIG"
  grep -q 'localBranchSortOrder: recency' "$CONFIG"
  grep -q 'context: localBranches' "$CONFIG"
  grep -q 'key: I' "$CONFIG"
  ! grep -q 'showBranchCommitHash: true' "$CONFIG"
}

@test "report separates local and remote containment and shows main divergence" {
  run sh -c 'cd "$1" && sh "$2" --mode git --selected feature/unmerged' _ "$TEST_REPO" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local main vs origin/main: ahead 1, behind 0"* ]]
  [[ "$output" == *"Y   Y"*"contained"* ]]
  [[ "$output" == *"Y   N"*"local-only"* ]]
  [[ "$output" == *">   N   N"*"feature/unmerged"* ]]
  [[ "$output" == *"gone"*"gone"* ]]
  [[ "$output" == *"active-worktree"*"worktree-active"* ]]
}

@test "repo-local base override supports non-main workflows" {
  gitq branch develop origin/main
  gitq config lazygit.branchBase develop
  run sh -c 'cd "$1" && sh "$2" --mode git --selected develop' _ "$TEST_REPO" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local base:  develop"* ]]
  [[ "$output" == *"Remote base: origin/main"* ]]
}

@test "PR mode keeps squash-style PR status separate from ancestry" {
  setup_path_stub
  printf '%s\n' '#!/bin/sh' \
    'printf '\''main\tCLOSED\tmain\t4\t2026-08-01T00:00:00Z\nfeature/unmerged\tMERGED\tmain\t42\t2026-09-01T00:00:00Z\n'\''' \
    >"$BATS_STUB_DIR/gh"
  chmod +x "$BATS_STUB_DIR/gh"
  gitq remote set-url origin https://github.com/example/demo.git

  run sh -c 'cd "$1" && sh "$2" --mode pr --selected feature/unmerged' _ "$TEST_REPO" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub PR data: loaded"* ]]
  [[ "$output" == *"N   N"*"feature/unmerged"*"MERGED->main#42"* ]]
  [[ "$output" != *"CLOSED->main#4"* ]]
}

@test "missing base is explanatory and remains successful" {
  empty_repo="$TEST_ROOT/empty"
  git init "$empty_repo" >/dev/null
  run sh -c 'cd "$1" && sh "$2" --mode git' _ "$empty_repo" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no base branch found"* ]]
  [[ "$output" == *"git config lazygit.branchBase"* ]]
}
