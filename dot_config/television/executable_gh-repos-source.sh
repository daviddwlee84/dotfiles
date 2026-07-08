#!/usr/bin/env bash
# Repo-list source for the `ghrepo` picker (dot_config/shell/41_github.sh) and
# the `github-repos` tv channel. Emits TSV:
#   nameWithOwner \t description \t primaryLanguage \t visibility
#
# Stale-while-revalidate cache at $XDG_CACHE_HOME/tv/gh-repos.tsv:
#   * prints the cached list immediately — the picker opens instantly after the
#     first run instead of waiting on the GitHub API (~300+ repos = a few sec)
#   * if the cache is older than GHREPO_CACHE_TTL seconds (default 3600), a
#     detached background fetch refreshes it for the NEXT launch
#   * first run (no cache yet) fetches synchronously
#   * `--refresh` forces a synchronous refetch (the picker's Ctrl-R / Alt-R)
#
# Keep the TSV columns in sync with both consumers' `cut -f` / `{split:\t:N}`.
set -uo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tv"
cache="$cache_dir/gh-repos.tsv"
ttl="${GHREPO_CACHE_TTL:-3600}"
mkdir -p "$cache_dir"

_fetch() {
  command gh repo list --limit 4000 --no-archived \
    --json nameWithOwner,description,primaryLanguage,visibility \
    --jq '.[] | [.nameWithOwner, (.description // ""), (.primaryLanguage.name // ""), .visibility] | @tsv'
}

_refresh_now() {
  local tmp
  tmp="$(mktemp "${cache}.XXXXXX")" || return 1
  if _fetch >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$cache"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Synchronous (re)fetch when forced or when there is no cache yet.
if [ "${1:-}" = "--refresh" ] || [ ! -s "$cache" ]; then
  _refresh_now || true
fi

# Serve whatever we have.
[ -s "$cache" ] && cat "$cache"

# Background revalidate if stale (skip right after a forced refresh).
if [ "${1:-}" != "--refresh" ] && [ -s "$cache" ]; then
  now="$(date +%s)"
  mtime="$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo "$now")"
  if [ "$((now - mtime))" -gt "$ttl" ]; then
    # Detach fds off the picker's source pipe so fzf/tv gets EOF immediately.
    ( _refresh_now ) </dev/null >/dev/null 2>&1 &
  fi
fi
exit 0
