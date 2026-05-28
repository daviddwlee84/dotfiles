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
