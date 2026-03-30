# 41_github.zsh - GitHub URL helpers

# Download a subdirectory from a GitHub repository tree URL.
# Example:
#   ghget https://github.com/microsoft/qlib/tree/high-freq-execution/examples/trade/
ghget() {
  emulate -L zsh
  setopt localoptions pipefail

  local usage="Usage: ghget https://github.com/<owner>/<repo>/tree/<branch>/<path>"
  local branch_note="ghget currently supports only GitHub tree URLs with a single-segment branch name (no '/' in branch)."

  if (( $# != 1 )); then
    print -u2 -- "$usage"
    print -u2 -- "$branch_note"
    return 1
  fi

  local url="$1"
  local prefix="https://github.com/"
  if [[ "$url" != ${prefix}* ]]; then
    print -u2 -- "Invalid GitHub tree URL: $url"
    print -u2 -- "$usage"
    print -u2 -- "$branch_note"
    return 1
  fi

  url="${url#$prefix}"
  url="${url%%\?*}"
  url="${url%%\#*}"
  url="${url%/}"

  local -a parts
  parts=(${(s:/:)url})
  if (( ${#parts} < 5 )) || [[ "${parts[3]}" != "tree" ]]; then
    print -u2 -- "Invalid GitHub tree URL: $1"
    print -u2 -- "$usage"
    print -u2 -- "$branch_note"
    return 1
  fi

  local owner="${parts[1]}"
  local repo="${parts[2]}"
  local branch="${parts[4]}"
  local subdir_path="${(j:/:)parts[5,-1]}"
  local leaf="${subdir_path:t}"

  if [[ -z "$owner" || -z "$repo" || -z "$branch" || -z "$subdir_path" || -z "$leaf" ]]; then
    print -u2 -- "Invalid GitHub tree URL: $1"
    print -u2 -- "$usage"
    print -u2 -- "$branch_note"
    return 1
  fi

  if [[ -e "$leaf" ]]; then
    print -u2 -- "Destination already exists: $PWD/$leaf"
    return 1
  fi

  local -a path_parts
  path_parts=(${(s:/:)subdir_path})
  local strip="${#path_parts}"
  local archive_root="${repo}-${branch}"
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ghget.XXXXXX")" || {
    print -u2 -- "Failed to create temporary directory"
    return 1
  }

  print -- "Downloading $owner/$repo/$subdir_path (branch: $branch) ..."
  if ! command curl -fsSL "https://github.com/$owner/$repo/archive/refs/heads/$branch.tar.gz" \
    | command tar -xz -C "$tmpdir" --strip-components="$strip" -f - "$archive_root/$subdir_path"; then
    command rm -rf -- "$tmpdir"
    print -u2 -- "Failed to download or extract '$subdir_path' from '$owner/$repo' on branch '$branch'"
    print -u2 -- "$branch_note"
    return 1
  fi

  if [[ ! -d "$tmpdir/$leaf" ]]; then
    command rm -rf -- "$tmpdir"
    print -u2 -- "Expected extracted directory was not found: $leaf"
    return 1
  fi

  if ! command mv -- "$tmpdir/$leaf" .; then
    command rm -rf -- "$tmpdir"
    print -u2 -- "Failed to move extracted directory into: $PWD"
    return 1
  fi

  command rm -rf -- "$tmpdir"
}
