#!/usr/bin/env bats

load "../test_helper.bash"

OPTIONS_FILE="$REPO_ROOT/dot_config/nvim/lua/config/options.lua"
PROBE_FILE="$REPO_ROOT/tests/fixtures/nvim_clipboard_probe.lua"

setup() {
  command -v nvim >/dev/null 2>&1 || skip "nvim is not installed"
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  unset HERDR_ENV ZELLIJ SSH_CONNECTION SSH_TTY SSH_CLIENT X_CLIPBOARD
}

run_probe() {
  run env "$@" NVIM_CLIPBOARD_OPTIONS="$OPTIONS_FILE" nvim --clean --headless -u NONE -l "$PROBE_FILE"
}

json_result() {
  printf '%s\n' "$output" | tail -n 1
}

@test "local Neovim keeps native unnamedplus clipboard" {
  run_probe NVIM_CLIPBOARD_ACTION=inspect
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.clipboard' <<<"$result")" = "unnamedplus" ]
  [ "$(jq -r '.provider' <<<"$result")" = "null" ]
  [ "$(jq -r '.paste_factory_calls' <<<"$result")" -eq 0 ]
}

@test "SSH herdr zellij and explicit osc52 select copy-only mode" {
  local selector result
  for selector in SSH_CONNECTION HERDR_ENV ZELLIJ; do
    run_probe "$selector=1" NVIM_CLIPBOARD_ACTION=inspect
    [ "$status" -eq 0 ]
    result="$(json_result)"
    [ "$(jq -r '.clipboard' <<<"$result")" = "" ]
    [ "$(jq -r '.provider' <<<"$result")" = "OSC 52 copy-only" ]
    [ "$(jq -r '.paste_factory_calls' <<<"$result")" -eq 0 ]
  done

  run_probe X_CLIPBOARD=osc52 NVIM_CLIPBOARD_ACTION=inspect
  [ "$status" -eq 0 ]
  result="$(json_result)"
  [ "$(jq -r '.provider' <<<"$result")" = "OSC 52 copy-only" ]

  run_probe HERDR_ENV=1 X_CLIPBOARD=auto NVIM_CLIPBOARD_ACTION=inspect
  [ "$status" -eq 0 ]
  result="$(json_result)"
  [ "$(jq -r '.provider' <<<"$result")" = "OSC 52 copy-only" ]
}

@test "a named local backend opts out inside herdr" {
  run_probe HERDR_ENV=1 X_CLIPBOARD=pbcopy NVIM_CLIPBOARD_ACTION=inspect
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.clipboard' <<<"$result")" = "unnamedplus" ]
  [ "$(jq -r '.provider' <<<"$result")" = "null" ]
}

@test "yank copies once while normal paste stays on the Neovim register" {
  run_probe HERDR_ENV=1 NVIM_CLIPBOARD_ACTION=yank_and_paste
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.sent | length' <<<"$result")" -eq 1 ]
  [ "$(jq -r '.sent[0].reg' <<<"$result")" = "+" ]
  [ "$(jq -r '.sent[0].lines[0]' <<<"$result")" = "alpha" ]
  [ "$(jq -r '.lines | join("|")' <<<"$result")" = "alpha|alpha|beta" ]
  [ "$(jq -r '.notifications | length' <<<"$result")" -eq 0 ]
}

@test "delete does not overwrite the attached client clipboard" {
  run_probe HERDR_ENV=1 NVIM_CLIPBOARD_ACTION=delete_and_paste
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.sent | length' <<<"$result")" -eq 0 ]
  [ "$(jq -r '.lines | join("|")' <<<"$result")" = "beta|alpha" ]
}

@test "explicit plus register copies and pastes from the session cache" {
  run_probe HERDR_ENV=1 NVIM_CLIPBOARD_ACTION=setreg_plus
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.sent | length' <<<"$result")" -eq 1 ]
  [ "$(jq -r '.cached_plus[0]' <<<"$result")" = "@lua/config/options.lua:1" ]
  [ "$(jq -r '.notifications | length' <<<"$result")" -eq 0 ]
}

@test "explicit plus paste without cache warns and returns immediately" {
  run_probe HERDR_ENV=1 NVIM_CLIPBOARD_ACTION=empty_plus_paste
  [ "$status" -eq 0 ]

  result="$(json_result)"
  [ "$(jq -r '.lines | join("|")' <<<"$result")" = "alpha" ]
  [ "$(jq -r '.notifications | length' <<<"$result")" -eq 1 ]
  [[ "$(jq -r '.notifications[0]' <<<"$result")" == *"terminal's native paste"* ]]
  [ "$(jq -r '.paste_factory_calls' <<<"$result")" -eq 0 ]
}
