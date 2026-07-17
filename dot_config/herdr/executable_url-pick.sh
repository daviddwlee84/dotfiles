#!/usr/bin/env sh
# ~/.config/herdr/url-pick.sh
# Source: dot_config/herdr/executable_url-pick.sh (managed by chezmoi)
#
# herdr analog of tmux's `prefix + u` (joshmedeski/tmux-fzf-url). Reads a herdr
# pane's text, extracts every URL-like token (same rewrite rules as tmux-fzf-url:
# http(s)/ftp/file, bare www., IPv4[:port], git@ SSH remotes, quoted owner/repo,
# npm imports), fuzzy-picks with fzf (multi-select), then opens each choice via
# the repo's cross-platform `x open` (wslview / open / xdg-open).
#
# Runs inside a herdr `[[keys.command]] type="pane"` (a PTY that closes when this
# script exits), bound to prefix+u in .chezmoitemplates/herdr/config.toml. The
# SAME building blocks as the sibling pane-copy.sh: $HERDR_ACTIVE_PANE_ID (the
# keybind-context pane) with a `herdr pane current` fallback, `herdr pane read`
# for the text, and an absolute-path opener fallback because a command pane runs
# us via `sh -c` without the interactive-shell PATH.
#
# Usage:
#   url-pick.sh [PANE_ID] [--source visible|recent]
# PANE defaults to $HERDR_ACTIVE_PANE_ID (passed by the keybind), else the current
# focused pane. --source defaults to visible (tmux-fzf-url's on-screen scope);
# --source recent scans the full retained scrollback.
#
# Consumers: the prefix+u keybind (.chezmoitemplates/herdr/config.toml). See
# docs/tools/herdr.md § "Open a URL from the pane".
set -eu

usage() { printf 'usage: %s [PANE_ID] [--source visible|recent]\n' "$0" >&2; exit 64; }

command -v herdr >/dev/null 2>&1 || { echo "url-pick: herdr not found" >&2; exit 1; }
command -v fzf   >/dev/null 2>&1 || { echo "url-pick: fzf is required"  >&2; exit 1; }

# Resolve the opener (`x open`) even without the interactive PATH.
if command -v x >/dev/null 2>&1; then
    X_BIN=x
elif [ -x "$HOME/.dotfiles/bin/x" ]; then
    X_BIN="$HOME/.dotfiles/bin/x"
else
    echo "url-pick: opener 'x' not found" >&2
    exit 1
fi

pane=""
source="visible"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) source="${2:-}"; shift 2 ;;
        --source=*) source="${1#--source=}"; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            if [ -z "$pane" ]; then
                pane="$1"
                shift
            else
                usage
            fi
            ;;
    esac
done

case "$source" in
    visible|recent|recent-unwrapped) ;;
    *) echo "url-pick: --source must be visible|recent" >&2; exit 64 ;;
esac

# Default to the current focused pane when no id was passed (or an empty env var).
if [ -z "$pane" ]; then
    command -v jq >/dev/null 2>&1 || { echo "url-pick: jq required to resolve current pane" >&2; exit 1; }
    pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "url-pick: could not determine a pane id" >&2; exit 1; }

content=$(herdr pane read "$pane" --source "$source" --format text 2>/dev/null) \
    || { echo "url-pick: failed to read pane $pane" >&2; exit 1; }

# Extraction — same passes/rewrites as tmux-fzf-url's fzf-url.sh, POSIX-ized
# (plain vars instead of bash arrays; trailing `|| true` so a no-match grep,
# which exits 1, does not trip `set -e`).
urls=$(printf '%s\n' "$content" | grep -oE '(https?|ftp|file):/?//[-A-Za-z0-9+&@#/%?=~_|!:,.;]*[-A-Za-z0-9+&@#/%=~_|]' || true)
wwws=$(printf '%s\n' "$content" | grep -oE '(https?://)?www\.[a-zA-Z](-?[a-zA-Z0-9])+\.[a-zA-Z]{2,}(/\S+)*' | grep -vE '^https?://' | sed 's#^#http://#' || true)
ips=$(printf  '%s\n' "$content" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?(/\S+)*' | sed 's#^#http://#' || true)
gits=$(printf '%s\n' "$content" | grep -oE '(ssh://)?git@\S*' | sed 's#:#/#g' | sed 's#^\(ssh///\)\{0,1\}git@\(.*\)$#https://\2#' || true)
gh=$(printf   '%s\n' "$content" | grep -oE "['\"]([A-Za-z0-9_-]+/[.A-Za-z0-9_-]+)['\"]" | sed "s/['\"]//g" | sed 's#^#https://github.com/#' || true)
npm=$(printf  '%s\n' "$content" | grep -oE "import[[:space:]]+[^\"';]*[\"']([^.][^\"';]*)[\"']" | sed "s/[^'\"]*['\"]\([^'\"]*\)['\"];*/\1/" | sed 's#^#https://npmjs.com/package/#' || true)

items=$(printf '%s\n' "$urls" "$wwws" "$gh" "$npm" "$ips" "$gits" | grep -v '^$' | sort -u || true)

if [ -z "$items" ]; then
    printf 'url-pick: no URLs found in pane %s (%s)\n' "$pane" "$source" >&2
    sleep 1.5   # command pane closes on exit — pause so the message is visible
    exit 0
fi

# fzf multi-select; Esc / no-match (exit 130 / 1) → clean no-op.
chosen=$(printf '%s\n' "$items" | fzf --multi --prompt='url> ' --height=100% --border --no-sort) || exit 0
[ -n "$chosen" ] || exit 0

printf '%s\n' "$chosen" | while IFS= read -r url; do
    [ -n "$url" ] && "$X_BIN" open "$url" >/dev/null 2>&1 || true
done
