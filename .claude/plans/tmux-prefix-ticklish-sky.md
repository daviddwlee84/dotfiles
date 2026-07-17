# Port tmux `prefix + u` URL picker to herdr

## Context

In tmux, `prefix + u` opens an fzf popup listing every URL in the current pane;
selecting one opens it in the browser. It is the third-party TPM plugin
[`joshmedeski/tmux-fzf-url`](https://github.com/joshmedeski/tmux-fzf-url)
(declared at `dot_config/tmux/common.conf.tmpl:37`, all defaults): capture the
visible pane → extract URLs with a stack of `grep -oE` passes → `fzf-tmux -m` →
`xdg-open`/`open`.

**herdr** (the repo's trial Rust multiplexer, coexists with tmux) has no URL
picker today. `prefix+u` (lowercase) is **free** — only `prefix+U` (`tv tools`)
is bound. herdr already ships every building block this needs:

- **Keybind vehicle** — `[[keys.command]] type="pane"` (herdr's analog of
  `tmux display-popup -E`): a real PTY that closes when the command exits, with
  `$HERDR_ACTIVE_PANE_ID` in its env. Already used for `lazygit`/`btop`/`tv tools`.
- **Pane text** — `herdr pane read <pane> --source visible|recent --format text`
  (used in `dot_config/herdr/executable_pane-copy.sh:132`).
- **Cross-platform open** — `x open <url>` (wslview / open / xdg-open), already
  the opener in every herdr-plus URL Quick Action (e.g. `github.toml`).

Outcome: `prefix + u` in herdr reproduces the tmux UX 1:1 — fzf-pick a URL from
the pane and open it.

> A prior session today (`.specstory/history/2026-07-17_07-30-59Z-…`) explored
> the same task but committed nothing (git log + tree confirm no URL helper exists).

## Decisions (confirmed with user)

1. **Picker = fzf** (faithful port of tmux-fzf-url; one helper, no tv channel).
2. **Scope = visible default + `--source recent` flag** (keybind uses visible,
   matching tmux; scrollback available via the helper flag).
3. **Extraction = full tmux-fzf-url parity** (http(s)/ftp/file, bare `www.`,
   IPv4[:port], `git@` SSH remotes → https, quoted `owner/repo` → github.com,
   `import "pkg"` → npmjs.com).

## Files to change

| File | Change |
|---|---|
| `dot_config/herdr/executable_url-pick.sh` | **New** helper → `~/.config/herdr/url-pick.sh` |
| `.chezmoitemplates/herdr/config.toml` | Add one `[[keys.command]]` for `prefix+u` |
| `docs/tools/herdr.md` | Keybind-table row + feasibility-matrix row + a short section |
| `docs/tools/herdr.zh-TW.md` | Mirror the same three doc edits |

Not needed: tab-completion (helper lives under `dot_config/herdr/`, not a
PATH-level `dot_dotfiles/bin/executable_*` CLI — same as `pane-copy.sh`);
`mkdocs.yml` nav (herdr page already listed); the agent skill (lean/self-discovering,
doesn't enumerate herdr keybinds); no `modify_config.toml.tmpl` change (we edit the
**managed body**, the documented path).

## New helper — `dot_config/herdr/executable_url-pick.sh`

POSIX `sh` + `set -eu`, matching the conventions of the sibling `pane-copy.sh`
(same `$HERDR_ACTIVE_PANE_ID`→`herdr pane current` fallback, same absolute-path
`x`/opener resolution for the no-interactive-PATH `sh -c` command-pane case).
Reference implementation:

```sh
#!/usr/bin/env sh
# ~/.config/herdr/url-pick.sh
# Source: dot_config/herdr/executable_url-pick.sh (managed by chezmoi)
#
# herdr analog of tmux's `prefix + u` (joshmedeski/tmux-fzf-url). Reads a herdr
# pane's text, extracts every URL-like token (same rewrite rules as tmux-fzf-url:
# http(s)/ftp/file, bare www., IPv4[:port], git@ SSH remotes, quoted owner/repo,
# npm imports), fuzzy-picks with fzf (multi-select), opens each choice via the
# repo's cross-platform `x open` (wslview / open / xdg-open).
#
# Runs inside a herdr `[[keys.command]] type="pane"` (a PTY that closes when this
# script exits), bound to prefix+u in .chezmoitemplates/herdr/config.toml.
#
# Usage: url-pick.sh [PANE_ID] [--source visible|recent]
#   PANE defaults to $HERDR_ACTIVE_PANE_ID (the keybind var), else the current
#   focused pane. --source defaults to visible (tmux-fzf-url's screen scope);
#   --source recent scans the full retained scrollback.
set -eu

usage() { printf 'usage: %s [PANE_ID] [--source visible|recent]\n' "$0" >&2; exit 64; }
command -v herdr >/dev/null 2>&1 || { echo "url-pick: herdr not found" >&2; exit 1; }
command -v fzf   >/dev/null 2>&1 || { echo "url-pick: fzf is required"  >&2; exit 1; }

# Resolve `x open` even without the interactive PATH (command panes run via sh -c).
if   command -v x >/dev/null 2>&1;         then X_BIN=x
elif [ -x "$HOME/.dotfiles/bin/x" ];       then X_BIN="$HOME/.dotfiles/bin/x"
else echo "url-pick: opener 'x' not found" >&2; exit 1
fi

pane=""; source="visible"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) source="${2:-}"; shift 2 ;;
        --source=*) source="${1#--source=}"; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) if [ -z "$pane" ]; then pane="$1"; shift; else usage; fi ;;
    esac
done
case "$source" in visible|recent|recent-unwrapped) ;; *) echo "url-pick: --source must be visible|recent" >&2; exit 64 ;; esac

# Default to the current focused pane when the keybind var was empty.
if [ -z "$pane" ]; then
    command -v jq >/dev/null 2>&1 || { echo "url-pick: jq required to resolve current pane" >&2; exit 1; }
    pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "url-pick: could not determine a pane id" >&2; exit 1; }

content=$(herdr pane read "$pane" --source "$source" --format text 2>/dev/null) \
    || { echo "url-pick: failed to read pane $pane" >&2; exit 1; }

# Extraction — same passes/rewrites as tmux-fzf-url's fzf-url.sh, POSIX-ized
# (plain vars instead of bash arrays; `|| true` so a no-match grep doesn't trip set -e).
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
```

Key edge cases handled: `set -eu` vs. no-match greps (`|| true`) and fzf-cancel
(`|| exit 0`); empty `$HERDR_ACTIVE_PANE_ID` → current-pane fallback; the
"no URLs" message pauses (`sleep 1.5`) because a command pane closes the instant
the script exits (tmux uses the status line instead); multi-select opens each URL.

## Keybind — `.chezmoitemplates/herdr/config.toml`

Add next to the `prefix+U` (`tv tools`) block so the `u`/`U` pair sits together:

```toml
# URL picker (tmux prefix+u analog): read the focused pane, fzf-pick a URL, open
# it with `x open`. Visible screen by default; url-pick.sh --source recent scans
# the full scrollback. Helper: ~/.config/herdr/url-pick.sh.
[[keys.command]]
key = "prefix+u"
type = "pane"
command = "~/.config/herdr/url-pick.sh \"$HERDR_ACTIVE_PANE_ID\""
description = "URL picker — open a URL from the pane (fzf)"
```

## Docs — `docs/tools/herdr.md` (+ zh-TW mirror)

1. **Keybindings table** (near line 114, after the `prefix+S` content-copy row):
   `| `` prefix + u `` | **URL picker** — fzf-pick a URL from the pane and open it (`x open`); tmux-fzf-url analog | command pane |`
2. **Feasibility matrix** (line 61–75): add
   `| URL picker (`prefix+u`, tmux-fzf-url) | **Custom command pane + helper** | `prefix+u` → `url-pick.sh` (fzf → `x open`); `--source recent` for scrollback |`
3. **New short section** "Open a URL from the pane (`prefix+u`)" as a sibling of
   "Copy focused-pane facts" (line 279): note the helper path, the visible/recent
   scope, the full parity extraction set, and that it opens via `x open`.

The zh-TW file has the same table/section anchors (`docs/tools/herdr.zh-TW.md`) —
translate the three edits identically.

## Verification (execution phase)

1. **Syntax / lint**: `sh -n dot_config/herdr/executable_url-pick.sh`;
   `shellcheck -s sh …` if available.
2. **Apply**: `chezmoi apply` — first preview the overlay merge with
   `chezmoi cat ~/.config/herdr/config.toml` to confirm the new `[[keys.command]]`
   round-trips and no other table drifts.
3. **herdr validates the config**: `herdr server reload-config` → expect
   `"status":"applied"` and an **empty `diagnostics`** array (no `prefix+u`
   collision). This is the repo's hard "validate with the app" rule.
4. **Extraction unit check (headless-safe)** — do *not* launch the herdr TUI to
   test (TUIs crash without a TTY, per the tv-channel validation lesson). Instead
   pipe known text through the extraction block standalone, e.g.
   `printf 'see https://github.com/foo/bar and git@github.com:o/r and "own/repo"\n' | <extraction pipeline>`
   and confirm the rewrites (`git@…`→https, `"own/repo"`→github.com).
5. **End-to-end in herdr** (interactive, on a host with herdr): open a pane,
   `echo https://example.com https://github.com/foo/bar`, press `prefix + u` →
   fzf lists both → select → opens via `x open`. Test the empty case (blank pane →
   "no URLs found" flashes ~1.5s). Test scrollback: `~/.config/herdr/url-pick.sh <pane> --source recent`.
6. **Docs build**: `uv run mkdocs build --strict` (expect only the known baseline
   llmstxt/i18n warnings, not new ones from these edits).
