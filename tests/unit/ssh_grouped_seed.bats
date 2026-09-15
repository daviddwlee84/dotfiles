#!/usr/bin/env bats
load "../test_helper.bash"
setup() {
  command -v chezmoi >/dev/null || skip "chezmoi required"
  export SSH_SEED_TMP
  SSH_SEED_TMP=$(mktemp -d)
  export SSH_SEED_HOME="$SSH_SEED_TMP/home"
  mkdir -p "$SSH_SEED_HOME" "$SSH_SEED_TMP/source"
  cp -R "$REPO_ROOT/private_dot_ssh" "$SSH_SEED_TMP/source/"
  sed -n '/# BEGIN SSH grouped seed gating/,/# END SSH grouped seed gating/p' "$REPO_ROOT/.chezmoiignore.tmpl" > "$SSH_SEED_TMP/source/.chezmoiignore.tmpl"
}
teardown() { [ -n "${SSH_SEED_TMP:-}" ] && rm -rf "$SSH_SEED_TMP"; }
# Own persistent state per run: never touch the user's real chezmoistate.boltdb
# (which a live `chezmoi update --apply` can be holding a lock on — see
# pitfalls/chezmoi-ssh-dir-mode-drift-prompt.md).
seed_apply() {
  HOME="$SSH_SEED_HOME" XDG_CONFIG_HOME="$SSH_SEED_HOME/.config" chezmoi --source "$SSH_SEED_TMP/source" --destination "$SSH_SEED_HOME" --persistent-state "$SSH_SEED_TMP/state.db" --no-tty apply --exclude=scripts "$@"
}
# Portable octal mode of a path (GNU stat, then BSD/macOS stat).
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
@test "fresh SSH seed uses exact grouped Includes and stays create-only" {
  run seed_apply
  [ "$status" -eq 0 ]
  # .ssh must be 0700 so ssh/dev never fight chezmoi over the dir mode
  # (private_dot_ssh). A bare dot_ssh would apply 0755 and drift forever.
  [ "$(mode_of "$SSH_SEED_HOME/.ssh")" = 700 ]
  grep -F '# dotfiles-ssh-layout: grouped-v1' "$SSH_SEED_HOME/.ssh/config"
  [ -f "$SSH_SEED_HOME/.ssh/config.d/git/github.conf" ]
  [ ! -e "$SSH_SEED_HOME/.ssh/config.d/01_git" ]
  printf '\n# user note\n' >> "$SSH_SEED_HOME/.ssh/config.d/git/github.conf"
  run seed_apply
  [ "$status" -eq 0 ]
  grep -F '# user note' "$SSH_SEED_HOME/.ssh/config.d/git/github.conf"
}
@test "existing wildcard SSH config neither migrates nor receives grouped seeds" {
  mkdir -p "$SSH_SEED_HOME/.ssh"
  printf 'Include ~/.ssh/config.d/*\nHost existing\n    HostName 192.0.2.1\n' > "$SSH_SEED_HOME/.ssh/config"
  cp "$SSH_SEED_HOME/.ssh/config" "$SSH_SEED_TMP/original"
  run seed_apply
  [ "$status" -eq 0 ]
  cmp "$SSH_SEED_TMP/original" "$SSH_SEED_HOME/.ssh/config"
  [ ! -e "$SSH_SEED_HOME/.ssh/config.d/git/github.conf" ]
}

@test "apply does not recreate a seed moved into another group" {
  run seed_apply
  [ "$status" -eq 0 ]
  mkdir -p "$SSH_SEED_HOME/.ssh/config.d/work"
  mv "$SSH_SEED_HOME/.ssh/config.d/git/github.conf" "$SSH_SEED_HOME/.ssh/config.d/work/github.conf"
  sed 's@config.d/git/github.conf@config.d/work/github.conf@' "$SSH_SEED_HOME/.ssh/config" > "$SSH_SEED_TMP/changed"
  cp "$SSH_SEED_TMP/changed" "$SSH_SEED_HOME/.ssh/config"
  run seed_apply
  [ "$status" -eq 0 ]
  [ ! -e "$SSH_SEED_HOME/.ssh/config.d/git/github.conf" ]
  [ -f "$SSH_SEED_HOME/.ssh/config.d/work/github.conf" ]
}

@test "referenced seeds can be explicitly restored with quoted Includes" {
  run seed_apply
  [ "$status" -eq 0 ]
  rm "$SSH_SEED_HOME/.ssh/config.d/git/github.conf"
  sed 's@Include ~/.ssh/config.d/git/github.conf@Include "~/.ssh/config.d/git/github.conf"@' "$SSH_SEED_HOME/.ssh/config" > "$SSH_SEED_TMP/quoted"
  cp "$SSH_SEED_TMP/quoted" "$SSH_SEED_HOME/.ssh/config"
  run seed_apply --force
  [ "$status" -eq 0 ]
  [ -f "$SSH_SEED_HOME/.ssh/config.d/git/github.conf" ]
}
