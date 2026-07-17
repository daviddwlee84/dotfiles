# Copy-path picker: extrakto (tmux) + `path-pick.sh` (herdr)

## Context

Follow-up to the just-shipped herdr URL picker (`prefix+u` → `url-pick.sh`, commit
`068a085`). The user wants the same "grab something from the pane" ergonomics but
for **file paths**, copied to the clipboard — on **both** tmux and herdr.

The hard part is detection: URLs self-identify via `scheme://`, file paths don't,
so naive regex is noisy (dates `2024/01/02`, flags `--x=a/b`, rates `10k/s`,
fractions `1/2`). Two mitigations, per the user's answers:

- **tmux** → adopt the **`laktak/extrakto`** TPM plugin (`prefix + Tab`): a mature
  fzf extractor for paths/URLs/words with copy/insert. `prefix+Tab` is **free** in
  this repo (verified — no `Tab`/`C-i` binding anywhere in the tmux config).
- **herdr** → a custom **two-tier, existence-validated** `path-pick.sh`, borrowing
  extrakto's path heuristics but adding the noise-killer extrakto lacks: keep paths
  that **exist under the pane cwd** on top, unverified candidates below a separator.
  Copy via `x copy`. Bound to **`prefix+p`** (free; pairs with the uppercase copy
  family `P/D/V/S` exactly like `u`/`U`).

## Decisions (confirmed with user)

1. Engine: **extrakto on tmux, custom helper on herdr** (borrow extrakto's patterns).
2. Noise policy: **two-tier** — existence-validated (copied as resolved absolute
   path) on top, unverified candidates (as-seen) below a separator.

## Part A — tmux: add the extrakto plugin

**File:** `dot_config/tmux/common.conf.tmpl` — insert after the `tmux-open` block
(line 41), before `sainnhe/tmux-fzf` (line 43), matching the inline-comment +
`@plugin` + options convention every other plugin uses:

```tmux
# extrakto: prefix + Tab → fzf popup that extracts file paths / URLs / words from
# the pane. Enter = copy to clipboard, Tab = insert to prompt, Ctrl-f = cycle
# filter, Ctrl-t = cycle clipboard mode (incl. OSC 52 for SSH). PATH-first order
# (main use = grabbing file paths). Complements tmux-fzf-url (prefix+u, URLs) and
# prefix+C-y (line yank). prefix+Tab is otherwise unbound in this config.
set -g @plugin 'laktak/extrakto'
set -g @extrakto_filter_order 'path url word line'
```

- **Deps** already present: fzf, Python 3.6+, tmux ≥3.3 (repo already upgrades tmux
  for the popup menu). No new ansible/brew work.
- **Install:** auto on fresh ansible runs (TPM sentinel absent, task at
  `dot_ansible/roles/devtools/tasks/main.yml:4200`). On this already-provisioned
  machine it needs a one-time `prefix + I` (or `rm ~/.tmux/plugins/.ansible-installed`
  before apply). Verification step below.
- **Clipboard:** default `auto`/`bg` uses the same backends as `x copy`
  (pbcopy/xclip/wl-copy). Over SSH, toggle to OSC 52 in-popup with `Ctrl-t` (the
  repo's terminals have `set-clipboard on`). Left as default to avoid silent
  failures on non-OSC52 terminals — documented, not overridden.

## Part B — herdr: new `dot_config/herdr/executable_path-pick.sh`

POSIX `sh` + `set -eu`, a direct sibling of `executable_url-pick.sh` /
`executable_pane-copy.sh` (same `$HERDR_ACTIVE_PANE_ID`→`herdr pane current`
fallback, same absolute-path `x` resolution, same `herdr pane read`). Differences:
extraction is path-shaped, output is **two-tier**, action is **`x copy`**.

Reference implementation (refined + unit-tested at execution, like url-pick):

```sh
#!/usr/bin/env sh
# ~/.config/herdr/path-pick.sh
# Source: dot_config/herdr/executable_path-pick.sh (managed by chezmoi)
#
# Copy-path sibling of url-pick.sh. Reads the focused pane, extracts path-like
# tokens (extrakto path heuristics), TWO-TIER: paths that EXIST under the pane cwd
# (copied as resolved ABSOLUTE path) on top, unverified candidates (as-seen) below
# a separator. fzf-pick (multi) → `x copy`. Bound to prefix+p.
#
# Usage: path-pick.sh [PANE_ID] [--source visible|recent] [--cwd DIR]
#   PANE  = $HERDR_ACTIVE_PANE_ID (keybind var) else current pane.
#   --cwd = $HERDR_ACTIVE_PANE_CWD; else herdr pane get .foreground_cwd; else
#           process-info cwd; else $PWD. Used only for existence checks.
set -eu

usage() { printf 'usage: %s [PANE_ID] [--source visible|recent] [--cwd DIR]\n' "$0" >&2; exit 64; }
command -v herdr >/dev/null 2>&1 || { echo "path-pick: herdr not found" >&2; exit 1; }
command -v fzf   >/dev/null 2>&1 || { echo "path-pick: fzf is required"  >&2; exit 1; }
if   command -v x >/dev/null 2>&1;   then X_BIN=x
elif [ -x "$HOME/.dotfiles/bin/x" ]; then X_BIN="$HOME/.dotfiles/bin/x"
else echo "path-pick: clipboard tool 'x' not found" >&2; exit 1
fi

pane=""; source="visible"; cwd=""
while [ "$#" -gt 0 ]; do case "$1" in
  --source) source="${2:-}"; shift 2 ;;   --source=*) source="${1#--source=}"; shift ;;
  --cwd) cwd="${2:-}"; shift 2 ;;          --cwd=*) cwd="${1#--cwd=}"; shift ;;
  -h|--help) usage ;;   -*) usage ;;
  *) if [ -z "$pane" ]; then pane="$1"; shift; else usage; fi ;;
esac; done
case "$source" in visible|recent|recent-unwrapped) ;; *) echo "path-pick: --source must be visible|recent" >&2; exit 64 ;; esac

if [ -z "$pane" ]; then
  command -v jq >/dev/null 2>&1 || { echo "path-pick: jq required to resolve current pane" >&2; exit 1; }
  pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "path-pick: could not determine a pane id" >&2; exit 1; }

if [ -z "$cwd" ] && command -v jq >/dev/null 2>&1; then
  cwd=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null || true)
  [ -n "$cwd" ] || cwd=$(herdr pane process-info --pane "$pane" 2>/dev/null \
      | jq -r '.result.process_info.foreground_processes[0].cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

content=$(herdr pane read "$pane" --source "$source" --format text 2>/dev/null) \
  || { echo "path-pick: failed to read pane $pane" >&2; exit 1; }

# Path candidates (extrakto heuristics, POSIX-ized): slash-bearing tokens
# (abs /…, home ~/…, rel ./ ../ a/b/c) + bare filename.ext. rstrip trailing
# ",):; then drop rate/fraction noise (extrakto's exclude: 10k/s, 1/2). dedupe.
cands=$(printf '%s\n' "$content" \
  | grep -oE '(~|\.\.?)?/?[A-Za-z0-9._+~-]+(/[A-Za-z0-9._+~-]+)+|[A-Za-z0-9._+-]+\.[A-Za-z0-9]{1,8}' \
  | sed -E 's/[",):;]+$//' \
  | grep -vE '^[0-9]+/[0-9]+$|[kKmMgG]/s$' \
  | grep -v '^$' | awk '!seen[$0]++' || true)
[ -n "$cands" ] || { printf 'path-pick: no file paths found in pane %s (%s)\n' "$pane" "$source" >&2; sleep 1.5; exit 0; }

exist=""; maybe=""
OLDIFS=$IFS; IFS='
'
for c in $cands; do
  base=$(printf '%s' "$c" | sed -E 's/:[0-9]+(:[0-9]+)?$//')   # strip :line[:col] for the test
  case "$base" in
    /*)   abs="$base" ;;
    \~/*) abs="$HOME/${base#\~/}" ;;
    *)    abs="$cwd/$base" ;;
  esac
  if [ -e "$abs" ]; then
    rp=$(CDPATH= cd -- "$(dirname -- "$abs")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename -- "$abs")") || rp="$abs"
    exist="$exist$rp
"
  else
    maybe="$maybe$c
"
  fi
done
IFS=$OLDIFS
exist=$(printf '%s' "$exist" | grep -v '^$' | sort -u || true)
maybe=$(printf '%s' "$maybe" | grep -v '^$' | sort -u || true)

SEP='────────  unverified (not found under cwd)  ────────'
list=$( [ -n "$exist" ] && printf '%s\n' "$exist"; [ -n "$maybe" ] && { printf '%s\n' "$SEP"; printf '%s\n' "$maybe"; } )

chosen=$(printf '%s\n' "$list" | fzf --multi --no-sort --height=100% --border \
  --prompt='path> ' --header="Enter=copy · Tab=multi · cwd=$cwd") || exit 0
chosen=$(printf '%s\n' "$chosen" | grep -vFx "$SEP" | grep -v '^$' || true)   # drop separator if picked
[ -n "$chosen" ] || exit 0
printf '%s' "$chosen" | "$X_BIN" copy
echo "copied $(printf '%s\n' "$chosen" | grep -c .) path(s)"
```

**Keybind** in `.chezmoitemplates/herdr/config.toml`, placed in the copy family
right after the `prefix+S` block (lines ~211):

```toml
# Copy a file PATH from the pane (extrakto-style, herdr side). Extracts path-like
# tokens; two-tier: paths that exist under the pane cwd (copied absolute) on top,
# unverified below a separator. fzf-pick → `x copy`. Lowercase p pairs with the
# uppercase copy family (P/D/V/S), same u/U convention. Helper mirrors pane-copy.sh.
[[keys.command]]
key = "prefix+p"
type = "pane"
command = "~/.config/herdr/path-pick.sh \"$HERDR_ACTIVE_PANE_ID\" --cwd \"$HERDR_ACTIVE_PANE_CWD\""
description = "copy a file path from the pane (fzf, two-tier)"
```

## Docs & cross-file maintenance

**herdr** (`docs/tools/herdr.md` + `docs/tools/herdr.zh-TW.md`): keybind-table row
(`prefix + p`, in the copy family near `prefix+S`), a feasibility-matrix row
(`Path/token extractor (extrakto prefix+Tab) → path-pick.sh (prefix+p)`), and a new
section "Copy a file path from the pane (`prefix+p`)" — sibling of the `prefix+u`
and Copy-focused-pane sections; document the two-tier model + cwd resolution.

**tmux** (add extrakto to these + their `.zh-TW` mirrors):
- `docs/tools/tmux/README.md` plugin table (~line 203, after `tmux-open`).
- `docs/tools/tmux/keybindings.md` — a `prefix + Tab` row in the Capture-Pane
  section (~234–240) and/or a short "Extract (extrakto)" note.
- `dot_config/tmux/cheatsheet.md` — Capture-pane table (~127–134). *(no zh-TW tmux cheatsheet)*
- `docs/keyboard-shortcuts.md` (URL & Sessions table ~113–124) + zh-TW mirror.

**No change needed:**
- `docs/this_repo/tool-managers.md` — individual TPM plugins are **not** listed
  (neither are `tmux-fzf-url`/`tmux-open`/`tmux-floax`); extrakto is covered by the
  generic TPM entries (lines 779, 943). Adding a per-plugin row would break convention.
- Ansible / Brewfile (auto via TPM), tab-completion (herdr helpers under
  `dot_config/herdr/` get none — same as `pane-copy.sh`/`url-pick.sh`), the agent
  skill (self-discovering), repo-root `README.md` (doesn't enumerate tmux plugins).

## Verification

**herdr helper (headless-safe):**
1. `sh -n dot_config/herdr/executable_path-pick.sh`; `shellcheck -s sh`.
2. **Two-tier unit test**: `mktemp -d`, create `src/main.rs` etc. inside it, feed
   sample text (real relative paths + `2024/01/02` + `10k/s` + `/no/such/file` +
   `pkg.py:42:5`) through the extraction+tier logic with `--cwd $tmpdir`; assert the
   real files land in the `exist` tier (absolute) and the noise is excluded / in `maybe`.
3. `chezmoi apply ~/.config/herdr/config.toml ~/.config/herdr/path-pick.sh`; confirm
   the helper is deployed executable and `prefix+p` survives the modify_ overlay
   (`chezmoi cat`).
4. **`herdr server reload-config`** → expect `status:applied`, **empty
   `diagnostics`** (confirms `prefix+p` is truly free — the repo's app-validation rule).
5. Read-only live check: `herdr pane read` + the cwd-resolution chain against an
   existing pane.
6. Interactive (manual): inside herdr, `ls`/`grep` something, `prefix+p`, confirm the
   two tiers and that Enter copies the absolute path.

**tmux extrakto:**
7. `chezmoi apply`, then `tmux kill-server` won't be needed — install with `prefix + I`
   (TPM), then `tmux source-file ~/.tmux.conf`. Press `prefix + Tab`: confirm the
   popup opens, `path` filter is first, Enter copies a path, `Ctrl-f` cycles to `url`.
   Confirm `prefix + Tab` didn't shadow anything (it was unbound).

**Docs:** `uv run mkdocs build --strict` — expect only the known baseline
llmstxt/i18n warnings; none referencing the edited files.
