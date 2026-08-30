#!/usr/bin/env bash
# Install canonical Pi/OMP commands before removing exact package-manager
# shadows. Binary transactions restore the previous command on failure.

set -euo pipefail

mode="${1:-}"
managed_prefix="${PI_AGENTS_MANAGED_PREFIX:-$HOME/.local}"
managed_prefix="${managed_prefix%/}"
changed=0

if [ -x "$HOME/.local/bin/mise" ]; then
  mise_bin="$HOME/.local/bin/mise"
elif command -v mise >/dev/null 2>&1; then
  mise_bin="mise"
else
  mise_bin=""
fi

run_npm() {
  if [ -n "$mise_bin" ]; then
    "$mise_bin" exec -- npm "$@"
  elif command -v npm >/dev/null 2>&1; then
    npm "$@"
  else
    printf '%s\n' "Pi/OMP package migration requires npm (preferably through mise)" >&2
    return 127
  fi
}

run_bun() {
  if [ -n "$mise_bin" ]; then
    "$mise_bin" exec -- bun "$@"
  elif command -v bun >/dev/null 2>&1; then
    bun "$@"
  else
    printf '%s\n' "OMP package migration found a Bun install but no usable bun command" >&2
    return 127
  fi
}

run_pi() {
  if [ -n "$mise_bin" ]; then
    "$mise_bin" exec -- "$managed_prefix/bin/pi" --version
  else
    "$managed_prefix/bin/pi" --version
  fi
}

run_node() {
  if [ -n "$mise_bin" ]; then
    "$mise_bin" exec -- node "$@"
  elif command -v node >/dev/null 2>&1; then
    node "$@"
  else
    return 127
  fi
}

npm_has() {
  local prefix="$1" package="$2"
  run_npm list -g --depth=0 --prefix "$prefix" "$package" >/dev/null 2>&1
}

package_manifest() {
  printf '%s/lib/node_modules/%s/package.json\n' "$1" "$2"
}

pi_is_canonical() {
  local pi_path="$managed_prefix/bin/pi"
  local package_root="$managed_prefix/lib/node_modules/@earendil-works/pi-coding-agent"
  [ -f "$package_root/package.json" ] && [ -x "$pi_path" ] || return 1
  run_node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const bin = fs.realpathSync(process.argv[1]);
    const root = fs.realpathSync(process.argv[2]);
    process.exit(bin.startsWith(root + path.sep) ? 0 : 1);
  ' "$pi_path" "$package_root" >/dev/null 2>&1 || return 1
  run_pi >/dev/null 2>&1
}

# Package-manager removal may own the same bin path as the already-verified
# canonical command. Move that exact command aside, run the removal, then put
# it back even if the removal fails.
run_preserving_bin() {
  local bin_path="$1"
  shift
  local backup_dir="" backup_path="" rc=0

  if [ -e "$bin_path" ] || [ -L "$bin_path" ]; then
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-agent-bin.XXXXXX")"
    backup_path="$backup_dir/${bin_path##*/}"
    mv "$bin_path" "$backup_path"
  fi

  if "$@"; then
    rc=0
  else
    rc=$?
  fi

  if [ -n "$backup_path" ]; then
    rm -f -- "$bin_path"
    mkdir -p "${bin_path%/*}"
    mv "$backup_path" "$bin_path"
    rmdir "$backup_dir"
  fi
  return "$rc"
}

npm_remove_if_present() {
  local prefix="$1" package="$2" preserve_bin="${3:-}"
  local manifest
  manifest="$(package_manifest "$prefix" "$package")"
  if [ -f "$manifest" ] || npm_has "$prefix" "$package"; then
    if [ -n "$preserve_bin" ]; then
      run_preserving_bin "$preserve_bin" \
        run_npm uninstall -g --ignore-scripts --prefix "$prefix" "$package"
    else
      run_npm uninstall -g --ignore-scripts --prefix "$prefix" "$package"
    fi
    changed=1
  fi
}

active_npm_prefix="$(run_npm prefix -g 2>/dev/null || true)"
active_npm_prefix="${active_npm_prefix%/}"
bun_install="${BUN_INSTALL:-$HOME/.bun}"
bun_global_dir="${BUN_INSTALL_GLOBAL_DIR:-$bun_install/install/global}"
bun_bin_dir="${BUN_INSTALL_BIN:-$bun_install/bin}"
bun_bin_dir="${bun_bin_dir%/}"
bun_omp_manifest="$bun_global_dir/node_modules/@oh-my-pi/pi-coding-agent/package.json"

case "$mode" in
pi-install)
  pi_path="$managed_prefix/bin/pi"

  if ! pi_is_canonical; then
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-install.XXXXXX")"
    backup_path="$backup_dir/pi"
    had_backup=0
    committed=0

    if [ -e "$pi_path" ] || [ -L "$pi_path" ]; then
      mkdir -p "${pi_path%/*}"
      mv "$pi_path" "$backup_path"
      had_backup=1
    fi

    rollback_pi() {
      local rc=$?
      trap - EXIT
      if [ "$committed" -ne 1 ]; then
        rm -f -- "$pi_path"
        if [ "$had_backup" -eq 1 ]; then
          mv "$backup_path" "$pi_path"
        fi
      fi
      rm -rf -- "$backup_dir"
      exit "$rc"
    }
    trap rollback_pi EXIT

    run_npm install -g --ignore-scripts --prefix "$managed_prefix" \
      "@earendil-works/pi-coding-agent"
    [ -x "$pi_path" ]
    run_pi >/dev/null

    committed=1
    changed=1
    trap - EXIT
    rm -rf -- "$backup_dir"
  fi
  printf 'PI_INSTALL_CHANGED=%s\n' "$changed"
  ;;

pi-cleanup)
  # Cleanup happens only after Ansible has verified the stable canonical Pi.
  # Preserve that bin while npm removes the deprecated stable package.
  npm_remove_if_present "$managed_prefix" "@mariozechner/pi-coding-agent" \
    "$managed_prefix/bin/pi"
  if [ -n "$active_npm_prefix" ] && [ "$active_npm_prefix" != "$managed_prefix" ]; then
    npm_remove_if_present "$active_npm_prefix" "@mariozechner/pi-coding-agent"
    npm_remove_if_present "$active_npm_prefix" "@earendil-works/pi-coding-agent"
  fi
  printf 'PI_CLEANUP_CHANGED=%s\n' "$changed"
  ;;

omp-status)
  package_present=0
  if [ -f "$(package_manifest "$managed_prefix" "@oh-my-pi/pi-coding-agent")" ] \
    || npm_has "$managed_prefix" "@oh-my-pi/pi-coding-agent"; then
    package_present=1
  fi
  if [ -n "$active_npm_prefix" ] && [ "$active_npm_prefix" != "$managed_prefix" ] \
    && { [ -f "$(package_manifest "$active_npm_prefix" "@oh-my-pi/pi-coding-agent")" ] \
      || npm_has "$active_npm_prefix" "@oh-my-pi/pi-coding-agent"; }; then
    package_present=1
  fi
  if [ -f "$bun_omp_manifest" ]; then
    package_present=1
  fi
  printf 'OMP_PACKAGE_PRESENT=%s\n' "$package_present"
  ;;

omp-install)
  omp_path="$managed_prefix/bin/omp"
  backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/omp-install.XXXXXX")"
  backup_path="$backup_dir/omp"
  had_backup=0
  committed=0

  if [ -e "$omp_path" ] || [ -L "$omp_path" ]; then
    mkdir -p "${omp_path%/*}"
    mv "$omp_path" "$backup_path"
    had_backup=1
  fi

  rollback_omp() {
    local rc=$?
    trap - EXIT
    if [ "$committed" -ne 1 ]; then
      rm -f -- "$omp_path"
      if [ "$had_backup" -eq 1 ]; then
        mv "$backup_path" "$omp_path"
      fi
    fi
    rm -rf -- "$backup_dir"
    exit "$rc"
  }
  trap rollback_omp EXIT

  curl -fsSL --connect-timeout 10 --max-time 300 \
    "https://omp.sh/install" \
    | PI_INSTALL_DIR="$managed_prefix/bin" sh -s -- --binary
  [ -x "$omp_path" ]
  "$omp_path" --version >/dev/null

  committed=1
  changed=1
  trap - EXIT
  rm -rf -- "$backup_dir"
  printf 'OMP_INSTALL_CHANGED=%s\n' "$changed"
  ;;

omp-cleanup)
  # Cleanup happens only after the standalone binary has been verified.
  npm_remove_if_present "$managed_prefix" "@oh-my-pi/pi-coding-agent" \
    "$managed_prefix/bin/omp"
  if [ -n "$active_npm_prefix" ] && [ "$active_npm_prefix" != "$managed_prefix" ]; then
    npm_remove_if_present "$active_npm_prefix" "@oh-my-pi/pi-coding-agent"
  fi

  if [ -f "$bun_omp_manifest" ]; then
    if [ "$bun_bin_dir/omp" = "$managed_prefix/bin/omp" ]; then
      run_preserving_bin "$managed_prefix/bin/omp" \
        run_bun remove -g --ignore-scripts "@oh-my-pi/pi-coding-agent"
    else
      run_bun remove -g --ignore-scripts "@oh-my-pi/pi-coding-agent"
    fi
    changed=1
  fi
  printf 'OMP_CLEANUP_CHANGED=%s\n' "$changed"
  ;;

*)
  printf 'usage: %s {pi-install|pi-cleanup|omp-status|omp-install|omp-cleanup}\n' \
    "${0##*/}" >&2
  exit 2
  ;;
esac
