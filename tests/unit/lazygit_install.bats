#!/usr/bin/env bats

load "../test_helper.bash"

ROLE="$REPO_ROOT/dot_ansible/roles/lazyvim_deps/tasks/main.yml"
DEFAULTS="$REPO_ROOT/dot_ansible/roles/lazyvim_deps/defaults/main.yml"

@test "LazyGit minimum version matches the diffRenderers schema" {
  grep -qF 'lazygit_min_version: "0.64.0"' "$DEFAULTS"
  grep -qF "lazygit_current_version is version(lazygit_min_version, '<')" "$ROLE"
  grep -qF "lazygit_final_version.stdout" "$ROLE"
}

@test "Homebrew LazyGit is detected before the targeted upgrade" {
  local section
  section="$(sed -n '/^- name: Detect Homebrew-managed LazyGit/,/^- name: Re-check LazyGit version after Homebrew/p' "$ROLE")"

  [[ "$section" == *'[ -n "$(brew --prefix 2>/dev/null)" ]'* ]]
  [[ "$section" == *'brew list --formula lazygit'* ]]
  [[ "$section" == *'brew upgrade lazygit'* ]]
  ! grep -qF 'state: latest' "$ROLE"
}

@test "official LazyGit fallbacks are version-gated and checksum-verified" {
  grep -qF "lazygit_effective_version is version(lazygit_min_version, '<')" "$ROLE"
  grep -qF "lazygit_post_system_version is version(lazygit_min_version, '<')" "$ROLE"
  grep -qF "lazygit_system_asset.digest is match('^sha256:[0-9a-f]{64}$')" "$ROLE"
  grep -qF "lazygit_user_asset.digest is match('^sha256:[0-9a-f]{64}$')" "$ROLE"
  grep -qF "checksum: \"{{ lazygit_system_asset.digest }}\"" "$ROLE"
  grep -qF "checksum: \"{{ lazygit_user_asset.digest }}\"" "$ROLE"
}

@test "official LazyGit assets cover Linux and macOS without stale case-sensitive names" {
  grep -qF "_linux_{{ lazygit_arch }}.tar.gz" "$ROLE"
  grep -qF "'darwin' if ansible_facts['os_family'] == 'Darwin' else 'linux'" "$ROLE"
  ! grep -qF '_Linux_{{ lazygit_arch }}.tar.gz' "$ROLE"
}
