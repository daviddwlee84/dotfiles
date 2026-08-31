#!/usr/bin/env bats
# Unit tests for dot_config/herdr/executable_pane-translate.sh — the text pipeline
# behind prefix+t and the "Translate pane" Quick Actions.
#
# Why this file earns its keep: the helper spends money. Every regression in the
# capture filter either sends terminal chrome to an LLM (waste) or silently sends
# nothing translatable (the dedent bug below). Both are invisible from the output
# of a successful run, so they have to be pinned here.
#
# Two behaviours in particular are non-obvious and have already bitten:
#
#   1. THE MODAL DEDENT. translate's bitext classifies a block as *code* once its
#      indent is >= base + 2. An agent pane renders prose behind a uniform left
#      margin while turn markers sit at column 0, so a min()-based base dedents
#      nothing and the ENTIRE page comes back untranslated — a successful,
#      billed, useless call. The base must be the MODAL indent.
#   2. `visible` IS NEVER TRIMMED AT THE TOP. It is literally what the user is
#      looking at; only `recent:N` windows may be snapped to a block boundary.
#
# The fixtures are shared with the Windows port: tests/fixtures/herdr/* here and
# the identical copies under dotfiles-windows/tests/fixtures/herdr/ are asserted
# byte-for-byte by tests/HerdrPaneTranslate.Tests.ps1 there. Regenerate an
# expectation with:
#   ./dot_config/herdr/executable_pane-translate.sh <mode> --dry-run < fixture
# only after convincing yourself the NEW output is the correct one.

load "../test_helper.bash"

setup() {
  HELPER="$REPO_ROOT/dot_config/herdr/executable_pane-translate.sh"
  FIX="$REPO_ROOT/tests/fixtures/herdr"
}

# The filter is an embedded python3 program inside the sh helper; run it directly
# so these tests need neither a herdr server nor the translate binary.
run_filter() { # MODE BUDGET < stdin
  local prog
  prog=$(sed -n '/^PY_FILTER=\$(cat <<.PY.$/,/^PY$/p' "$HELPER" | sed '1d;$d')
  python3 -c "$prog" "$1" "${2:-12000}" 2>/dev/null
}

@test "helper is valid POSIX sh" {
  run sh -n "$HELPER"
  [ "$status" -eq 0 ]
}

@test "visible: strips bottom chrome, dedents by the modal indent, keeps content" {
  output=$(run_filter visible < "$FIX/pane-capture.txt")
  [ "$output" = "$(cat "$FIX/pane-capture.visible.expected")" ]
}

@test "visible: the status-line block, prompt row and spinner are all gone" {
  output=$(run_filter visible < "$FIX/pane-capture.txt")
  [[ "$output" != *"Tokens 4.6M"* ]]
  [[ "$output" != *"bypass permissions"* ]]
  [[ "$output" != *"~statistics.json"* ]]
  [[ "$output" != *"Percolating"* ]]
  [[ "$output" != *"Context    "* ]]
}

@test "visible: prose is dedented to column 0 but a nested code block is not" {
  output=$(run_filter visible < "$FIX/pane-capture.txt")
  # Prose sat at the modal indent (5) and must land at 0...
  [[ "$output" == *$'\nThe TUI currently renders'* ]]
  # ...while the block indented deeper keeps a >= 2 relative indent, which is
  # what makes translate leave the command verbatim instead of translating it.
  [[ "$output" == *$'\n    $ just bats'* ]]
}

@test "visible: a collapsed-transcript marker becomes a bare ellipsis" {
  output=$(run_filter visible < "$FIX/pane-capture.txt")
  [[ "$output" != *"+194 lines"* ]]
  [[ "$output" == *"[…]"* ]]
}

@test "recent: a mid-sentence top edge is snapped to a block boundary" {
  output=$(run_filter recent:200 < "$FIX/pane-capture-midcut.txt")
  [ "$output" = "$(cat "$FIX/pane-capture-midcut.recent.expected")" ]
  [[ "$output" == "[… earlier output omitted …]"* ]]
  [[ "$output" != *"data become Git or runtime authority"* ]]
}

@test "visible: the same mid-sentence capture is kept whole and unmarked" {
  output=$(run_filter visible < "$FIX/pane-capture-midcut.txt")
  [ "$output" = "$(cat "$FIX/pane-capture-midcut.visible.expected")" ]
  [[ "$output" == "data become Git or runtime authority"* ]]
  [[ "$output" != *"omitted"* ]]
}

@test "the character budget trims from the top and lands on a boundary" {
  output=$(run_filter recent:200 60 < "$FIX/pane-capture-midcut.txt")
  [ "${#output}" -lt 200 ]
  [[ "$output" == *"omitted"* ]]
  # The newest content survives; the oldest block is what goes.
  [[ "$output" == *"Preserve lazy live loading"* ]]
}

@test "an all-chrome capture yields nothing rather than a billed empty call" {
  output=$(printf '❯\n  -- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle)\n' | run_filter visible)
  [ -z "$output" ]
}

@test "the mode argument is validated before any pane read" {
  run "$HELPER" recent:abc w0:p0
  [ "$status" -eq 64 ]
  [[ "$output" == *"mode must be visible or recent:N"* ]]
}
