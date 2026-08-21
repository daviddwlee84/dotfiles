# shellcheck shell=bash
# Shared Herdr agent-skill synchronizer.
#
# The installed Herdr binary is the authority for its agent skill. Upstream's
# `herdr --skill` output is built from the same release, so copying that output
# avoids the version drift possible with a branch-based `npx skills add`.
#
# Callers must load scripts/lib/log_shared.sh before invoking this function.

sync_herdr_skill() {
  local destination="${1:-$HOME/.agents/skills/herdr/SKILL.md}"
  local destination_dir tmp first_line

  if ! command -v herdr >/dev/null 2>&1; then
    return 77
  fi

  destination_dir="${destination%/*}"
  if ! mkdir -p "$destination_dir"; then
    warn "Could not create Herdr skill directory: $destination_dir"
    return 1
  fi

  if ! tmp=$(mktemp "$destination_dir/.SKILL.md.tmp.XXXXXX"); then
    warn "Could not create a temporary file for the Herdr skill"
    return 1
  fi

  if ! herdr --skill >"$tmp"; then
    rm -f "$tmp"
    warn "Installed Herdr does not provide a usable \`herdr --skill\` output; keeping the existing global skill"
    return 1
  fi

  first_line=$(sed -n '1p' "$tmp")
  if [[ "$first_line" != "---" ]] || ! grep -Eq '^name:[[:space:]]*herdr[[:space:]]*$' "$tmp"; then
    rm -f "$tmp"
    warn "\`herdr --skill\` returned invalid skill content; keeping the existing global skill"
    return 1
  fi

  chmod 0644 "$tmp"
  if [[ -f "$destination" ]] && cmp -s "$tmp" "$destination"; then
    rm -f "$tmp"
    return 0
  fi

  if ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp"
    warn "Could not replace the global Herdr skill at $destination"
    return 1
  fi

  success "Herdr agent skill synced from $(herdr --version 2>/dev/null || printf 'installed binary')"
}
