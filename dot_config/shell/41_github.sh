# 41_github.sh - GitHub URL helpers (shared bash + zsh).
# Moved from dot_config/zsh/tools/41_github.zsh. The original relied on
# zsh-only constructs for the URL parsing:
#   ${(s:/:)url}      → split on `/`        — replaced with tr + while-read
#   ${(j:/:)slice}    → join with `/`       — replaced with an explicit loop
#   ${parts[N]}       → 1-indexed access    — replaced with an explicit loop
#   ${parts[5,-1]}    → slice               — replaced with an explicit loop
#   ${var:t}          → basename            — replaced with `${var##*/}`
#   ${#arr}           → array length        — replaced with `${#arr[@]}`
# setopt localoptions pipefail is gated on $ZSH_VERSION; bash falls back to
# `set -o pipefail` (leaks for the rest of the shell — benign).

# Download a subdirectory from a GitHub repository tree URL.
# Example:
#   ghget https://github.com/microsoft/qlib/tree/high-freq-execution/examples/trade/
ghget() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    # bash: no function-local options; setting pipefail leaks but is benign.
    set -o pipefail
  fi

  local usage="Usage: ghget https://github.com/<owner>/<repo>/tree/<branch>/<path>"
  local branch_note="ghget currently supports only GitHub tree URLs with a single-segment branch name (no '/' in branch)."

  if [ $# -ne 1 ]; then
    printf '%s\n' "$usage" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  local url="$1"
  local prefix="https://github.com/"
  if [[ "$url" != ${prefix}* ]]; then
    printf '%s\n' "Invalid GitHub tree URL: $url" >&2
    printf '%s\n' "$usage" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  url="${url#"$prefix"}"
  url="${url%%\?*}"
  url="${url%%\#*}"
  url="${url%/}"

  # Portable split-on-/: `tr / \n | while read` (mirrors the svibe pattern
  # in dot_config/shell/22_sesh.sh — zsh disables word-splitting on
  # unquoted parameters by default, so the original `${(s:/:)url}` flag is
  # rewritten via tr + read).
  local -a parts
  parts=()
  local tok
  while IFS= read -r tok; do
    parts+=( "$tok" )
  done < <(printf '%s\n' "$url" | tr '/' '\n')

  if [ "${#parts[@]}" -lt 5 ]; then
    printf '%s\n' "Invalid GitHub tree URL: $1" >&2
    printf '%s\n' "$usage" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  local owner repo tree_marker branch
  owner=""
  repo=""
  tree_marker=""
  branch=""
  local -a subdir_parts
  subdir_parts=()
  local idx=0
  for tok in "${parts[@]}"; do
    idx=$((idx + 1))
    case "$idx" in
      1) owner="$tok" ;;
      2) repo="$tok" ;;
      3) tree_marker="$tok" ;;
      4) branch="$tok" ;;
      *) subdir_parts+=( "$tok" ) ;;
    esac
  done

  if [ "$tree_marker" != "tree" ]; then
    printf '%s\n' "Invalid GitHub tree URL: $1" >&2
    printf '%s\n' "$usage" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  # Subdir path = parts from index 4 onwards, joined with `/`.
  local subdir_path
  subdir_path=""
  for tok in "${subdir_parts[@]}"; do
    if [ -z "$subdir_path" ]; then
      subdir_path="$tok"
    else
      subdir_path="$subdir_path/$tok"
    fi
  done

  # Leaf basename via parameter expansion (replaces zsh's `${var:t}` modifier).
  local leaf="${subdir_path##*/}"

  if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$branch" ] || [ -z "$subdir_path" ] || [ -z "$leaf" ]; then
    printf '%s\n' "Invalid GitHub tree URL: $1" >&2
    printf '%s\n' "$usage" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  if [ -e "$leaf" ]; then
    printf '%s\n' "Destination already exists: $PWD/$leaf" >&2
    return 1
  fi

  # Count path components (subdir depth) for `tar --strip-components=N`.
  local strip="${#subdir_parts[@]}"

  local archive_root="${repo}-${branch}"
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ghget.XXXXXX")" || {
    printf '%s\n' "Failed to create temporary directory" >&2
    return 1
  }

  printf '%s\n' "Downloading $owner/$repo/$subdir_path (branch: $branch) ..."
  if ! command curl -fsSL "https://github.com/$owner/$repo/archive/refs/heads/$branch.tar.gz" \
    | command tar -xz -C "$tmpdir" --strip-components="$strip" -f - "$archive_root/$subdir_path"; then
    command rm -rf -- "$tmpdir"
    printf '%s\n' "Failed to download or extract '$subdir_path' from '$owner/$repo' on branch '$branch'" >&2
    printf '%s\n' "$branch_note" >&2
    return 1
  fi

  if [ ! -d "$tmpdir/$leaf" ]; then
    command rm -rf -- "$tmpdir"
    printf '%s\n' "Expected extracted directory was not found: $leaf" >&2
    return 1
  fi

  if ! command mv -- "$tmpdir/$leaf" .; then
    command rm -rf -- "$tmpdir"
    printf '%s\n' "Failed to move extracted directory into: $PWD" >&2
    return 1
  fi

  command rm -rf -- "$tmpdir"
}

# Fuzzy-find your GitHub repos (name + description), preview the README, then
# clone+cd / open in browser / copy the URL. Needs: gh (authenticated) + fzf.
#
# Usage: ghrepo [owner] [extra `gh repo list` flags]
#   ghrepo                     # your repos (owner defaults to the authed user)
#   ghrepo some-org --source   # an org's repos, non-forks only
#
# Keys inside the picker:
#   Enter    clone into ${GHREPO_ROOT:-$PWD}/<repo>, then cd into it
#   Alt-O    open the repo on github.com
#   Ctrl-Y   copy the repo URL to the clipboard
#
# `--limit 4000` lists *all* your repos (plain `gh repo list` stops at 30). The
# clone+cd happens in the enclosing function (not an fzf `become`/`execute`
# child) because only the interactive shell can cd the caller. Set GHREPO_ROOT
# to clone into a fixed repo root instead of the current dir (see docs/tools/gh-cli.md).
ghrepo() {
  command -v gh  >/dev/null 2>&1 || { printf '%s\n' "ghrepo: gh not found"  >&2; return 1; }
  command -v fzf >/dev/null 2>&1 || { printf '%s\n' "ghrepo: fzf not found" >&2; return 1; }

  local sel repo dest
  sel=$(
    gh repo list "$@" --limit 4000 --no-archived \
       --json nameWithOwner,description,primaryLanguage,visibility \
       --jq '.[] | [.nameWithOwner, (.description // ""), (.primaryLanguage.name // ""), .visibility] | @tsv' \
    | fzf --ansi --delimiter='\t' --with-nth=1,2,3,4 \
          --preview 'gh repo view {1}' --preview-window='right,60%,wrap' \
          --header 'enter=clone+cd  alt-o=open  ctrl-y=copy-url' \
          --bind 'alt-o:execute-silent(gh repo view {1} --web)' \
          --bind 'ctrl-y:execute-silent(gh browse -R {1} -n | (pbcopy 2>/dev/null || wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null))' \
    | cut -f1
  )

  [ -n "$sel" ] || return 0
  repo="${sel##*/}"
  dest="${GHREPO_ROOT:-$PWD}"
  gh repo clone "$sel" "$dest/$repo" && cd "$dest/$repo"
}
