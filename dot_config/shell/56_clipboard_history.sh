# 56_clipboard_history.sh — cross-platform clipboard-history helpers.
#
# Wraps Maccy (macOS, plaintext SQLite) and CopyQ (Linux, shipped CLI) behind
# a unified `cb` / `cbl` / `cbe` API. Replaces the Raycast-specific helper
# deleted in 2026-05 — Raycast 1.7+ encrypts its DB with SQLCipher and the
# key cannot be recovered without binary RE; see
# pitfalls/raycast-clipboard-sqlcipher-key-not-recoverable.md.
#
# Backend selection (override autodetect with CLIP_BACKEND=copyq|maccy):
#   macOS:  prefer Maccy SQLite, fall back to CopyQ if installed manually.
#   Linux:  CopyQ only.
# No backend → one-line install hint to stderr (ubuntu_server typical case).
#
# Maccy schema (verified against p0deje/Maccy@master HistoryItem.swift +
# HistoryItemContent.swift, 2026-05):
#   ZHISTORYITEM(Z_PK, ZAPPLICATION, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT,
#                ZNUMBEROFCOPIES, ZPIN, ZTITLE)
#   ZHISTORYITEMCONTENT(Z_PK, ZTYPE, ZVALUE, ZITEM -> ZHISTORYITEM.Z_PK)
# Core Data dates are seconds since 2001-01-01; add 978307200 for Unix epoch.

# ---- backend detection -----------------------------------------------------

_clip_maccy_path() {
    p="$HOME/Library/Application Support/Maccy/Storage.sqlite"
    [ -f "$p" ] && { printf 'maccy:%s\n' "$p"; return 0; }
    p="$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"
    [ -f "$p" ] && { printf 'maccy:%s\n' "$p"; return 0; }
    return 1
}

_clip_copyq_ready() {
    command -v copyq >/dev/null 2>&1 || return 1
    copyq size >/dev/null 2>&1
}

_clip_backend() {
    case "${CLIP_BACKEND:-}" in
        copyq) _clip_copyq_ready && echo copyq ;;
        maccy) _clip_maccy_path ;;
        '')
            if [ "$(uname)" = "Darwin" ]; then
                _clip_maccy_path && return 0
                _clip_copyq_ready && echo copyq
            else
                _clip_copyq_ready && echo copyq
            fi
            ;;
        *)
            printf 'clipboard-history: unknown CLIP_BACKEND=%s (expected: copyq|maccy)\n' "$CLIP_BACKEND" >&2
            return 1
            ;;
    esac
}

_clip_hint() {
    cat >&2 <<'HINT'
clipboard-history: no backend found.

  macOS:  brew install --cask maccy   (then launch once from Spotlight)
  Linux:  sudo apt install copyq      (autostarts on next X session)

See docs/tools/clipboard.md → Clipboard History.
HINT
}

_clip_is_uint() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ---- cbl: list recent N items (tab-separated <idx>\t<first-line>) ----------

cbl() {
    n=${1:-20}
    if ! _clip_is_uint "$n"; then
        echo "cbl: argument must be a positive integer (got: $n)" >&2
        return 1
    fi
    b=$(_clip_backend) || { _clip_hint; return 1; }
    case "$b" in
        copyq)
            copyq eval "
                var n = Math.min(size(), $n);
                for (var i = 0; i < n; i++) {
                    var line = read(i).split('\n')[0];
                    if (line.length > 0) print(i + '\t' + line + '\n');
                }
            "
            ;;
        maccy:*)
            db=${b#maccy:}
            sqlite3 -readonly -batch "$db" <<SQL
.mode tabs
.headers off
SELECT Z.Z_PK,
       substr(replace(CAST(C.ZVALUE AS TEXT), char(10), ' '), 1, 200)
FROM ZHISTORYITEM Z
JOIN ZHISTORYITEMCONTENT C ON C.ZITEM = Z.Z_PK
WHERE C.ZTYPE = 'public.utf8-plain-text'
ORDER BY Z.ZLASTCOPIEDAT DESC
LIMIT $n;
SQL
            ;;
    esac
}

# ---- cb: fzf-pick a clip → copy to system clipboard ------------------------

cb() {
    command -v fzf >/dev/null 2>&1 || { echo "cb: fzf not found" >&2; return 1; }
    b=$(_clip_backend) || { _clip_hint; return 1; }
    sel=$(cbl 100 | fzf --no-multi --with-nth=2.. --delimiter='	' --prompt='clip> ') || return 1
    idx=$(printf '%s\n' "$sel" | cut -f1)
    _clip_is_uint "$idx" || { echo "cb: bad index from fzf: $idx" >&2; return 1; }
    case "$b" in
        copyq)
            copyq select "$idx"
            ;;
        maccy:*)
            db=${b#maccy:}
            sqlite3 -readonly -batch "$db" \
                "SELECT CAST(ZVALUE AS TEXT) FROM ZHISTORYITEMCONTENT \
                 WHERE ZITEM=$idx AND ZTYPE='public.utf8-plain-text' LIMIT 1;" \
                | pbcopy
            ;;
    esac
}

# ---- cbe: fzf-pick → edit in $EDITOR → write back to clipboard -------------

cbe() {
    command -v fzf >/dev/null 2>&1 || { echo "cbe: fzf not found" >&2; return 1; }
    b=$(_clip_backend) || { _clip_hint; return 1; }
    sel=$(cbl 100 | fzf --no-multi --with-nth=2.. --delimiter='	' --prompt='cb-edit> ') || return 1
    idx=$(printf '%s\n' "$sel" | cut -f1)
    _clip_is_uint "$idx" || { echo "cbe: bad index from fzf: $idx" >&2; return 1; }
    tmp=$(mktemp -t clipedit.XXXXXX) || return 1
    case "$b" in
        copyq)
            copyq read "$idx" > "$tmp"
            ;;
        maccy:*)
            db=${b#maccy:}
            sqlite3 -readonly -batch "$db" \
                "SELECT CAST(ZVALUE AS TEXT) FROM ZHISTORYITEMCONTENT \
                 WHERE ZITEM=$idx AND ZTYPE='public.utf8-plain-text' LIMIT 1;" \
                > "$tmp"
            ;;
    esac
    ${EDITOR:-nvim} "$tmp"
    if [ -s "$tmp" ]; then
        case "$b" in
            copyq)  copyq copy - < "$tmp" ;;
            maccy:*) pbcopy < "$tmp" ;;
        esac
    fi
    rm -f "$tmp"
}
