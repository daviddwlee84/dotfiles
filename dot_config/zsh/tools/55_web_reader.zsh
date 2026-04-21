# 55_web_reader.zsh - Render web pages as markdown in the terminal
#
# Four extractors, pick by function name:
#   readurl   - jina.ai Reader (remote, zero local deps beyond glow)
#   readlocal - trafilatura (local, Python; offline article extraction)
#   readnode  - readability-cli / `readable` (local, Node; Mozilla Readability)
#   readraw   - curl + pandoc (full page -> GFM; no article extraction)
#
# All wrap the underlying fetch in `try_direct_then_proxy` from 50_networking.zsh,
# so non-GFW'd URLs pay zero proxy overhead and only fall back if direct fetch fails.

# Normalize URL: prepend https:// if scheme missing.
_norm_url() {
  local url="$1"
  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="https://$url"
  fi
  printf '%s\n' "$url"
}

# Missing-binary guard: print a one-line install hint and return 127.
__zsh_reader_require() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" &>/dev/null; then
    print -u2 "$bin not found -- install: $hint"
    return 127
  fi
  return 0
}

# readurl <url> - jina.ai Reader + glow. The default convenience.
readurl() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    print -u2 "usage: readurl <url>"
    return 2
  fi
  __zsh_reader_require glow "brew install glow  (or the devtools ansible role)" || return
  local url; url="$(_norm_url "$raw")"
  try_direct_then_proxy glow -p "https://r.jina.ai/$url"
}

# readlocal <url> - trafilatura (offline article extraction) + glow.
readlocal() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    print -u2 "usage: readlocal <url>"
    return 2
  fi
  __zsh_reader_require trafilatura "uv tool install trafilatura  (or enable the python_uv_tools ansible role)" || return
  __zsh_reader_require glow "brew install glow  (or the devtools ansible role)" || return
  local url; url="$(_norm_url "$raw")"
  try_direct_then_proxy trafilatura -u "$url" --markdown | glow -
}

# readnode <url> - readability-cli (`readable`) + glow.
readnode() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    print -u2 "usage: readnode <url>"
    return 2
  fi
  __zsh_reader_require readable "npm install -g readability-cli" || return
  __zsh_reader_require glow "brew install glow  (or the devtools ansible role)" || return
  local url; url="$(_norm_url "$raw")"
  try_direct_then_proxy readable "$url" | glow -
}

# readraw <url> - full-page HTML -> markdown via pandoc (no article extraction).
readraw() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    print -u2 "usage: readraw <url>"
    return 2
  fi
  __zsh_reader_require curl "apt install curl  (usually preinstalled)" || return
  __zsh_reader_require pandoc "brew install pandoc  (or apt install pandoc)" || return
  __zsh_reader_require glow "brew install glow  (or the devtools ansible role)" || return
  local url; url="$(_norm_url "$raw")"
  try_direct_then_proxy curl -fsSL "$url" | pandoc -f html -t gfm | glow -
}
