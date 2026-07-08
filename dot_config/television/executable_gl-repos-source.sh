#!/usr/bin/env bash
# Repo-list source for the `glrepo` picker (dot_config/shell/42_gitlab.sh) and
# the `gitlab-repos` tv channel. Emits TSV:
#   path_with_namespace \t description \t visibility \t web_url
#
# Stale-while-revalidate cache at $XDG_CACHE_HOME/tv/gl-repos.tsv — same model as
# gh-repos-source.sh (instant after first run; background revalidate when older
# than GLREPO_CACHE_TTL seconds, default 3600; `--refresh` forces a refetch).
# gitlab.com by default; export GITLAB_HOST for a self-hosted instance (glab
# honors it).
#
# Keep the TSV columns in sync with both consumers' `cut -f` / `{split:\t:N}`.
set -uo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tv"
cache="$cache_dir/gl-repos.tsv"
ttl="${GLREPO_CACHE_TTL:-3600}"
mkdir -p "$cache_dir"

_fetch() {
  command glab repo list --mine --per-page 100 -F json \
    | command jq -r '.[] | [.path_with_namespace, (.description // ""), .visibility, .web_url] | @tsv'
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

if [ "${1:-}" = "--refresh" ] || [ ! -s "$cache" ]; then
  _refresh_now || true
fi

[ -s "$cache" ] && cat "$cache"

if [ "${1:-}" != "--refresh" ] && [ -s "$cache" ]; then
  now="$(date +%s)"
  mtime="$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo "$now")"
  if [ "$((now - mtime))" -gt "$ttl" ]; then
    ( _refresh_now ) </dev/null >/dev/null 2>&1 &
  fi
fi
exit 0
