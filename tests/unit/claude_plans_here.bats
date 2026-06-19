#!/usr/bin/env bats
# Unit tests for dot_config/shell/10_aliases.sh claude-plans-here helpers.

load "../test_helper.bash"

ALIASES_FILE="$REPO_ROOT/dot_config/shell/10_aliases.sh"

setup() {
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-plans-here.XXXXXX")"
  export WORKDIR
}

teardown() {
  [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
  cleanup_path_stubs
}

_encode_claude_project_path() {
  printf '%s' "$1" | tr '/.' '--'
}

@test "claude-plans-here imports authoritative global plans and ignores chat mentions" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local home="$WORKDIR/home"
  local repo="$WORKDIR/repo"
  local project_dir="$home/.claude/projects/$(_encode_claude_project_path "$repo")"
  mkdir -p "$home/.claude/plans" "$project_dir" "$repo/.claude/plans"

  printf 'write old\n' > "$home/.claude/plans/write-old.md"
  printf 'result new\n' > "$home/.claude/plans/result-new.md"
  printf 'exit plan\n' > "$home/.claude/plans/exit-plan.md"
  printf 'mention only\n' > "$home/.claude/plans/mention-only.md"
  printf 'already local\n' > "$home/.claude/plans/already-local.md"
  printf 'existing local wins\n' > "$repo/.claude/plans/already-local.md"

  cat > "$project_dir/session.jsonl" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$home/.claude/plans/write-old.md","content":"x"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Mention only: $home/.claude/plans/mention-only.md"}]}}
{"type":"user","toolUseResult":{"type":"create","filePath":"$home/.claude/plans/result-new.md","content":"x"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","input":{"planFilePath":"$home/.claude/plans/exit-plan.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$home/.claude/plans/already-local.md","content":"x"}}]}}
EOF

  run env HOME="$home" bash -c "cd '$repo' && source '$ALIASES_FILE' && _claude_plans_here_import_orphans 1"
  [ "$status" -eq 0 ]

  [ -f "$repo/.claude/plans/write-old.md" ]
  [ -f "$repo/.claude/plans/result-new.md" ]
  [ -f "$repo/.claude/plans/exit-plan.md" ]
  [ ! -f "$repo/.claude/plans/mention-only.md" ]
  [ "$(cat "$repo/.claude/plans/already-local.md")" = "existing local wins" ]
  [[ "$output" == *"Found 3 orphan plan(s)"* ]]
}

@test "claude-plans-here scans git root sessions when invoked from a subdirectory" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  local home="$WORKDIR/home"
  local repo="$WORKDIR/repo"
  local subdir="$repo/pkg/inner"
  local project_dir="$home/.claude/projects/$(_encode_claude_project_path "$repo")"
  mkdir -p "$home/.claude/plans" "$project_dir" "$subdir/.claude/plans" "$repo/.claude/plans"
  git -C "$repo" init >/dev/null 2>&1

  printf 'root plan\n' > "$home/.claude/plans/root-session.md"
  cat > "$project_dir/session.jsonl" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$home/.claude/plans/root-session.md","content":"x"}}]}}
EOF

  run env HOME="$home" bash -c "cd '$subdir' && source '$ALIASES_FILE' && _claude_plans_here_import_orphans 1"
  [ "$status" -eq 0 ]

  [ -f "$subdir/.claude/plans/root-session.md" ]
  [[ "$output" == *"Found 1 orphan plan(s)"* ]]
}
