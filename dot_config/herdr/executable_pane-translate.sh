#!/usr/bin/env sh
# ~/.config/herdr/pane-translate.sh
# Source: dot_config/herdr/executable_pane-translate.sh (managed by chezmoi)
#
# Translate a herdr pane's terminal content with the `translate` CLI and show the
# result as a BILINGUAL view — the original lines kept verbatim, each block's
# translation interleaved beneath as `  ↳ …` (`translate -2 --bilingual-mode doc`,
# one context-aware LLM call for the whole capture).
#
# HOW MUCH TO CAPTURE — the whole design question, and the measured answers:
#
#   * An agent pane on the ALTERNATE SCREEN has no scrollback at all. A Claude
#     Code pane reports scroll.max_offset_from_bottom = 0 and `pane read --source
#     recent --lines 1000` returns exactly viewport_rows — identical to --source
#     visible. Rows that leave the alternate screen never enter herdr's host
#     scrollback, so no --lines value can recover them. (A plain shell or a codex
#     pane next door will happily report thousands of rows: this is per-app.)
#     Hence the default mode is `visible`, which is not a compromise — it tracks
#     whatever you scrolled to INSIDE the app, so "the current page" is exact.
#   * `herdr pane read` caps at 1000 lines and has no offset/pagination flag, so
#     `recent:1000` is the hard ceiling (same limit pane-copy.sh documents).
#   * A 1000-line read is ~62 KB. translate costs roughly 10 KB ≈ 61 s, 20 KB ≈
#     96 s, and providers reject well before 62 KB — so the REAL cap is a
#     character budget (HERDR_TRANSLATE_MAX_CHARS, default 12000 ≈ 75 s), not a
#     line count. `recent:N` is only a coarse selector that the budget then trims;
#     every trim is announced in the header, never silent.
#
# NOT CUTTING MID-CONTENT is handled in two places. Mechanically, a `recent:N`
# window gets its TOP edge snapped down to the nearest block boundary (blank line,
# agent-turn marker, rule, heading) within a bounded margin. Semantically — and
# this matters more — the capture is sent with an --instructions string telling
# the model it is a terminal excerpt that may begin or end mid-sentence. An LLM
# translator does not need clean boundaries; it needs to be told they are dirty.
# A `visible` capture is never trimmed at the top: it is exactly what you are
# looking at, so it only ever gets a marker.
#
# Entry points (all four land here):
#   prefix+t                 type = "popup" -> --inline, has a PTY, pages in place
#   prefix+y "Translate pane: …"            -> Quick Action, `sh -c`, NO PTY/stdin:
#                                              captures, splits a pane, and re-execs
#                                              itself as `__view` inside it
#   prefix+y "…: copy"                      -> --copy, straight to `x copy`
#   prefix+y "…: into language…"            -> --to from the form field
#
# Usage:
#   pane-translate.sh [MODE] [PANE_ID] [--to LANG] [--copy|--inline|--dry-run]
#                     [--pager CMD]
#   pane-translate.sh __view CAPTURE_FILE LABEL [--to LANG] [--pager CMD]
#
#   MODE     visible (default) | recent:N   (N clamped to 1..1000)
#   PANE_ID  defaults to $HERDR_PLUS_PANE_ID, then `herdr pane current`
#   --to     target language; default is translate's own [general] config, or
#            $HERDR_TRANSLATE_TO
#   --dry-run  print the cleaned/repaired capture and stats, make no LLM call
#
# Env: HERDR_TRANSLATE_MAX_CHARS (12000), HERDR_TRANSLATE_TO, HERDR_RUN_HOLD
#      (fail|always|never, as in run-command.sh), PAGER.
#
# Consumers: the prefix+t keybind and the translate-pane* Quick Actions
# (dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/).
# See docs/tools/herdr.md § "Translate a pane".
set -eu

usage() {
    printf 'usage: %s [visible|recent:N] [PANE_ID] [--to LANG] [--copy|--inline|--dry-run] [--pager CMD]\n' "$0" >&2
    exit 64
}

MAX_CHARS="${HERDR_TRANSLATE_MAX_CHARS:-12000}"

# Sent to the model with every capture. This — not line arithmetic — is what makes
# a screen that starts or ends mid-sentence translate cleanly.
INSTRUCTIONS='This is a captured terminal screen from a coding-agent TUI. It may begin or end mid-sentence: translate exactly what is present, never complete or summarise it. Keep command names, file paths, flags, identifiers, code, log lines, JSON and box-drawing characters verbatim; translate only prose.'

# --- binary resolution ------------------------------------------------------
# A Quick Action / command pane may run us via `sh -c` without the interactive
# PATH, so every external tool is resolved by fallback rather than assumed.
# NB: a stale ~/.dotfiles/bin/translate shadows ~/.local/bin on some boxes — see
# the translate repo's pitfalls/duplicate-translate-on-path-*.md.
resolve_bin() {
    _name="$1"; shift
    if command -v "$_name" >/dev/null 2>&1; then command -v "$_name"; return 0; fi
    for _c in "$@"; do
        [ -x "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

TRANSLATE_BIN=$(resolve_bin translate \
    "$HOME/.local/bin/translate" /opt/homebrew/bin/translate /usr/local/bin/translate \
    "$HOME/go/bin/translate") \
    || { echo "pane-translate: translate not found" >&2; exit 1; }

# --- the text filter --------------------------------------------------------
# Kept as one embedded python3 program rather than an awk/sed pipeline: the
# dedent and the boundary scan both need to look at the whole document. python3
# is already a dependency of this directory (focus-pane.py).
PY_FILTER=$(cat <<'PY'
import re
import sys

mode, budget = sys.argv[1], int(sys.argv[2])
text = sys.stdin.read()
lines = text.split("\n")
raw_lines = len(lines)
raw_chars = len(text)

# --- chrome, matched only from the BOTTOM so content is never eaten ----------
FOOTER = re.compile(
    r"^\s*(\?\s*for shortcuts|ctrl\s*\+|[Ee]sc to |shift\s*\+\s*tab"
    r"|[>\u203a\u276f\u00bb]\s|[>\u203a\u276f\u00bb]\s*$)"
)
# Keywords that only ever appear in a live input/status fixture, matched
# anywhere on the line (a vim-mode indicator can precede them).
CHROME_KEY = re.compile(
    r"(\u23f5\u23f5|\? for shortcuts|bypass permissions|shift\s*\+\s*tab"
    r"|--\s*(INSERT|NORMAL|VISUAL)\s*--|esc to interrupt)",
    re.IGNORECASE,
)
# A working spinner row: a glyph, then an elapsed/token counter in parentheses.
SPINNER = re.compile(
    r"^\s*[\u273d\u273b\u2733\u2722\u00b7*\u2736]\s.*\(.*\d+\s*(s|m|ms)\b.*\)\s*$"
)
# A status bar is the other bottom fixture: several separated fields, no prose.
# Matching on the separator count keeps it from eating real sentences.
STATUS = re.compile(r"^[^\n]*( \u00b7 | \u2502 )([^\n]*( \u00b7 | \u2502 )){1,}[^\n]*$")
BOX_TOP = re.compile(r"^\s*[\u256d\u250c][\u2500\u2550\u2501]")
BOX_BOTTOM = re.compile(r"^\s*[\u2570\u2514][\u2500\u2550\u2501]")
BOX_SIDE = re.compile(r"^\s*[\u2502\u2503|]")
# A full-width rule, optionally carrying a trailing label.
RULE = re.compile(r"^\s*[\u2500\u2550\u2501_]{20,}(\s+\S.*)?$")


def is_chrome(ln):
    return bool(
        FOOTER.match(ln)
        or CHROME_KEY.search(ln)
        or STATUS.match(ln)
        or SPINNER.match(ln)
        or BOX_BOTTOM.match(ln)
        or BOX_SIDE.match(ln)
    )


while lines and not lines[-1].strip():
    lines.pop()

# Two passes over the bottom, repeated until stable: a row-wise walk, then a
# block-wise cut at a rule. Cutting a status block can expose another footer row
# that the first walk had stopped above.
for _ in range(3):
    orig = lines[:]
    # The live input frame plus its hint rows sit at the very bottom of an agent
    # pane. Walk up over footer/box rows; stop at the first real content row.
    i = len(orig)
    while i > 0:
        ln = orig[i - 1]
        if not ln.strip() or is_chrome(ln):
            i -= 1
            continue
        if BOX_TOP.match(ln):
            i -= 1
            break
        break

    # A custom status line is a whole BLOCK of non-prose rows the walk cannot
    # enumerate ("Tokens 4.6M (in: …)", "~statistics.json(+9)  ~dotfiles"…).
    # What it does have is a reliable anchor: a full-width rule separating it
    # from the transcript. Cut from that rule, but only when it is near the
    # bottom AND something below it is recognisable chrome — so a rule printed
    # mid-transcript is left alone.
    for r in range(len(orig) - 1, max(-1, len(orig) - 31), -1):
        if r >= i:
            continue
        if RULE.match(orig[r]) and any(is_chrome(x) for x in orig[r + 1 :]):
            i = r
            break

    lines = orig[:i]
    while lines and not lines[-1].strip():
        lines.pop()
    if lines == orig:
        break

# Collapsed-transcript markers carry no translatable prose.
HIDDEN = re.compile(r"^\s*(\u2026|\.\.\.)\s*\+\d+ lines?\b.*$")
lines = ["[\u2026]" if HIDDEN.match(ln) else ln for ln in lines]

# --- top-edge boundary repair (recent:N only) -------------------------------
# `visible` is literally what the user is looking at: mark it, never trim it.
BOUNDARY = re.compile(
    r"^(\s*$"
    r"|[●⏺⎿•✻>❯$#]\s"
    r"|[─═━]{10,}"
    r"|[A-Z0-9][^\n]{0,60}:\s*$)"
)
note = ""
if mode != "visible" and lines:
    margin = min(40, max(5, len(lines) * 15 // 100))
    cut = None
    for idx in range(min(margin, len(lines))):
        if BOUNDARY.match(lines[idx]):
            cut = idx
            break
    if cut is None:
        note = "[… continued from earlier output …]"
    elif cut > 0:
        lines = lines[cut:]
        note = "[… earlier output omitted …]"

# --- dedent -----------------------------------------------------------------
# Load-bearing. translate's bitext classifies a block as Code once its indent is
# >= base + 2 relative to the document's base margin, and an agent pane renders
# its prose behind a uniform left margin — leave it and every paragraph is
# classified as code and silently left untranslated.
#
# The base is the MODAL indent, not the minimum. An agent transcript mixes
# turn markers at column 0 with prose at column 5; min() would be 0, dedent
# nothing, and lose the whole page. The modal indent is the pane's dominant text
# column, so prose lands at 0 while a genuinely nested code block keeps its
# relative indent and stays classified as code.
indents = [len(ln) - len(ln.lstrip(" ")) for ln in lines if ln.strip()]
if indents:
    counts = {}
    for n in indents:
        counts[n] = counts.get(n, 0) + 1
    top = max(counts.values())
    base = min(n for n, c in counts.items() if c == top)
    if base:
        lines = [ln[min(base, len(ln) - len(ln.lstrip(" "))) :] if ln.strip() else ln for ln in lines]

lines = [ln.expandtabs(4).rstrip() for ln in lines]

# --- collapse blank runs ----------------------------------------------------
out = []
for ln in lines:
    if not ln and out and not out[-1]:
        continue
    out.append(ln)
while out and not out[0]:
    out.pop(0)
lines = out

# --- character budget -------------------------------------------------------
# The real cap. Drop leading blank-line-delimited blocks until we fit, so the
# newest content always survives and the cut always lands on a boundary.
def joined(ls):
    return "\n".join(ls)

trimmed = False
while len(joined(lines)) > budget and lines:
    trimmed = True
    try:
        nxt = lines.index("", 1)
    except ValueError:
        # One block bigger than the budget: fall back to a line-wise trim.
        while len(joined(lines)) > budget and len(lines) > 1:
            lines.pop(0)
        break
    lines = lines[nxt + 1 :]
    while lines and not lines[0]:
        lines.pop(0)
if trimmed and not note:
    note = "[… earlier output omitted …]"

if note:
    lines = [note, ""] + lines

body = joined(lines)
sys.stdout.write(body + ("\n" if body else ""))
sys.stderr.write(
    "raw_lines=%d raw_chars=%d out_lines=%d out_chars=%d trimmed=%d\n"
    % (raw_lines, raw_chars, len(lines), len(body), 1 if trimmed else 0)
)
PY
)

# ---------------------------------------------------------------------------
# __view: run inside the pane/popup that actually has a PTY. Translates the
# already-captured, already-cleaned file and pages the result.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "__view" ]; then
    shift
    capture="${1:-}"; label="${2:-pane}"
    [ -n "$capture" ] && [ -f "$capture" ] || { echo "pane-translate: no capture file" >&2; exit 1; }
    shift 2 || true
    to=""; pager="${PAGER:-less -R}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --to) to="${2:-}"; shift 2 ;;
            --to=*) to="${1#--to=}"; shift ;;
            --pager) pager="${2:-}"; shift 2 ;;
            --pager=*) pager="${1#--pager=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$to" ] || to="${HERDR_TRANSLATE_TO:-}"

    # Closing the viewer pane mid-translation sends SIGHUP; without this the
    # capture (and a partial result) would be left in TMPDIR.
    out="$capture.out"
    trap 'rm -f "$capture" "$out"' EXIT INT TERM HUP

    bytes=$(wc -c < "$capture" | tr -d ' ')
    printf '\033[1mtranslate\033[0m %s — %s bytes, ~%ss\n\n' "$label" "$bytes" "$((bytes / 160 + 5))"

    set +e
    if [ -n "$to" ]; then
        "$TRANSLATE_BIN" -2 --bilingual-mode doc --no-history \
            --instructions "$INSTRUCTIONS" --to "$to" < "$capture" > "$out"
    else
        "$TRANSLATE_BIN" -2 --bilingual-mode doc --no-history \
            --instructions "$INSTRUCTIONS" < "$capture" > "$out"
    fi
    rc=$?
    set -e

    if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
        # shellcheck disable=SC2086
        $pager "$out"
    else
        echo "pane-translate: translate failed (exit $rc)" >&2
        [ -s "$out" ] && cat "$out"
    fi

    hold="${HERDR_RUN_HOLD:-fail}"
    _wait=0
    case "$hold" in
        never) ;;
        always) _wait=1 ;;
        *) [ "$rc" -ne 0 ] && _wait=1 ;;
    esac
    if [ "$_wait" -eq 1 ]; then
        printf '\n[exit %s] press Enter to close…' "$rc"
        IFS= read -r _ || true
    fi
    exit "$rc"
fi

# ---------------------------------------------------------------------------
# Capture side.
# ---------------------------------------------------------------------------
command -v herdr >/dev/null 2>&1 || { echo "pane-translate: herdr not found" >&2; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo "pane-translate: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "pane-translate: python3 is required" >&2; exit 1; }

mode="visible"; pane=""; to=""; act="split"; pager="${PAGER:-less -R}"
positional=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --to) to="${2:-}"; shift 2 ;;
        --to=*) to="${1#--to=}"; shift ;;
        --pager) pager="${2:-}"; shift 2 ;;
        --pager=*) pager="${1#--pager=}"; shift ;;
        --copy) act="copy"; shift ;;
        --inline) act="inline"; shift ;;
        --dry-run) act="dry"; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            positional=$((positional + 1))
            case "$positional" in
                1) mode="$1" ;;
                2) pane="$1" ;;
                *) usage ;;
            esac
            shift
            ;;
    esac
done

# An unexpanded "$HERDR_ACTIVE_PANE_ID" (or an empty Quick Action var) must fall
# through to the current-pane lookup rather than be used as an id.
case "$pane" in '$'*) pane="" ;; esac
[ -n "$pane" ] || pane="${HERDR_PLUS_PANE_ID:-}"
case "$pane" in '$'*) pane="" ;; esac
if [ -z "$pane" ]; then
    pane=$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
[ -n "$pane" ] || { echo "pane-translate: could not determine a pane id" >&2; exit 1; }

case "$mode" in
    visible)
        src="visible"; lines=""
        ;;
    recent:*)
        lines="${mode#recent:}"
        case "$lines" in
            ''|*[!0-9]*)
                echo "pane-translate: mode must be visible or recent:N (got '$mode')" >&2
                exit 64
                ;;
        esac
        [ "$lines" -lt 1 ] && lines=1
        # herdr's own hard per-read ceiling; anything above still returns 1000.
        [ "$lines" -gt 1000 ] && lines=1000
        # recent-unwrapped joins soft wraps, so long lines never reach the
        # translator broken mid-word.
        src="recent-unwrapped"
        ;;
    *) echo "pane-translate: mode must be visible or recent:N (got '$mode')" >&2; exit 64 ;;
esac

if [ -n "$lines" ]; then
    raw=$(herdr pane read "$pane" --source "$src" --format text --lines "$lines" 2>/dev/null) \
        || { echo "pane-translate: failed to read $pane" >&2; exit 1; }
else
    raw=$(herdr pane read "$pane" --source "$src" --format text 2>/dev/null) \
        || { echo "pane-translate: failed to read $pane" >&2; exit 1; }
fi

tmpdir="${TMPDIR:-/tmp}"
capture="$tmpdir/herdr-translate-$pane-$$.txt"
capture=$(printf '%s' "$capture" | tr ':' '_')

# Body to $capture, one-line stats on stderr -> $stats.
stats=$(printf '%s\n' "$raw" | python3 -c "$PY_FILTER" "$mode" "$MAX_CHARS" 2>&1 >"$capture")

[ -s "$capture" ] || { rm -f "$capture"; echo "pane-translate: nothing to translate in $pane" >&2; exit 1; }

label="$pane ($mode)"

case "$act" in
    dry)
        cat "$capture"
        printf '\n--- %s: %s\n' "$label" "$stats" >&2
        rm -f "$capture"
        ;;
    copy)
        X_BIN=$(resolve_bin x "$HOME/.dotfiles/bin/x") \
            || { rm -f "$capture"; echo "pane-translate: clipboard tool 'x' not found" >&2; exit 1; }
        [ -n "$to" ] || to="${HERDR_TRANSLATE_TO:-}"
        # Do not leave the capture behind when translate fails under `set -e`.
        trap 'rm -f "$capture"' EXIT INT TERM
        if [ -n "$to" ]; then
            body=$("$TRANSLATE_BIN" -2 --bilingual-mode doc --no-history \
                --instructions "$INSTRUCTIONS" --to "$to" < "$capture")
        else
            body=$("$TRANSLATE_BIN" -2 --bilingual-mode doc --no-history \
                --instructions "$INSTRUCTIONS" < "$capture")
        fi
        printf '%s' "$body" | "$X_BIN" copy
        herdr notification show "Translated $label" --body "$stats" >/dev/null 2>&1 || true
        echo "copied translation of $label"
        ;;
    inline)
        # We already own a PTY (popup / command pane): no split needed.
        exec "$0" __view "$capture" "$label" ${to:+--to "$to"} --pager "$pager"
        ;;
    split)
        # Quick Action path: `sh -c`, no PTY. The capture is already on disk —
        # note it was taken BEFORE the split, because splitting narrows the source
        # pane and makes the app re-wrap what we just read.
        new=$(herdr pane split "$pane" --direction right --ratio 0.5 2>/dev/null \
            | jq -r '.result.pane_id // .result.pane.pane_id // empty') \
            || { rm -f "$capture"; echo "pane-translate: split failed" >&2; exit 1; }
        [ -n "$new" ] || { rm -f "$capture"; echo "pane-translate: split returned no pane id" >&2; exit 1; }

        # `pane run` types into the new pane's shell, so wait for one to exist.
        n=0
        while [ "$n" -lt 30 ]; do
            if herdr pane process-info --pane "$new" 2>/dev/null \
                | jq -e '.result.process_info.shell_pid // empty' >/dev/null 2>&1; then
                break
            fi
            n=$((n + 1))
            sleep 0.1
        done

        # Resolve our own absolute path rather than assuming the deployed one:
        # the same script must work when run straight from the chezmoi source
        # tree during development.
        self=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)/$(basename -- "$0")
        cmd="exec '$self' __view '$capture' '$label'"
        [ -n "$to" ] && cmd="$cmd --to '$to'"
        herdr pane run "$new" "$cmd" >/dev/null 2>&1 \
            || { echo "pane-translate: could not start the viewer in $new" >&2; exit 1; }

        # `pane split` has no --focus flag (PaneSplitParams.focus defaults false),
        # and `pane focus` is directional — so reuse the exact-pane focuser that
        # herdr-grep and the tv channels already share. It needs the socket path
        # as its session selector alongside the explicit ids.
        here=$(CDPATH='' cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)
        ids=$(herdr pane get "$new" 2>/dev/null | jq -r '.result.pane | "\(.workspace_id) \(.tab_id)"')
        if [ -n "$ids" ] && [ -x "$here/focus-pane.py" ]; then
            "$here/focus-pane.py" --socket-path "${HERDR_SOCKET_PATH:-}" \
                --workspace-id "${ids% *}" --tab-id "${ids#* }" --pane-id "$new" \
                >/dev/null 2>&1 || true
        fi
        ;;
esac
