#!/usr/bin/env bats

load "../test_helper.bash"

ROLE="$REPO_ROOT/dot_ansible/roles/neovim/tasks/main.yml"

@test "macOS Neovim install is version-gated and install-only" {
  local section
  section="$(sed -n '/^- name: Install Neovim with Homebrew/,/^- name: Check Neovim version after/p' "$ROLE")"

  [[ "$section" == *"nvim_current_version is version(neovim_min_version, '<')"* ]]
  [[ "$section" == *"nvim_macos_arch == 'arm64'"* ]]
  [[ "$section" == *"state: present"* ]]
  ! grep -qF 'state: latest' "$ROLE"
}

@test "macOS Neovim fallback maps both official release architectures" {
  grep -qF "'x86_64' if target_architecture in ['x86_64', 'amd64']" "$ROLE"
  grep -qF "else 'arm64' if target_architecture in ['aarch64', 'arm64']" "$ROLE"
  grep -qF 'nvim-macos-{{ nvim_macos_arch }}.tar.gz' "$ROLE"
}

@test "macOS Neovim fallback verifies the release digest before extraction" {
  grep -qF "nvim_macos_asset.digest is match('^sha256:[0-9a-f]{64}$')" "$ROLE"
  grep -qF 'checksum: "{{ nvim_macos_asset.digest }}"' "$ROLE"
  grep -qF -- '- /usr/bin/tar' "$ROLE"
  grep -qF -- '- "{{ ansible_facts['"'"'env'"'"']['"'"'HOME'"'"'] }}/.local"' "$ROLE"
  grep -qF -- '--strip-components=1' "$ROLE"
}

@test "macOS Neovim fallback validates the installed version and fails clearly" {
  grep -qF "nvim_macos_release_version.stdout is version(neovim_min_version, '>=')" "$ROLE"
  grep -qF 'Failed to install Neovim from the official macOS release' "$ROLE"
  grep -qF 'ansible_check_mode' "$ROLE"
}
