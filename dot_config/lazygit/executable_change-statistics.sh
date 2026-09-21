#!/bin/sh
# Read-only, repository-wide line statistics for Lazygit's Files popup.

set -eu

# Keep Git's summary predictable and avoid optional index refresh writes.
LC_ALL=C
GIT_OPTIONAL_LOCKS=0
export LC_ALL GIT_OPTIONAL_LOCKS

repo_root=$(git rev-parse --show-toplevel) || exit 1
cd "$repo_root"

base=HEAD
overall_label='Overall vs HEAD'
if ! git rev-parse --verify --quiet HEAD >/dev/null; then
	# A symbolic HEAD without a commit is an unborn branch. Derive the empty
	# tree hash for this repo's object format without writing an object (-w).
	git symbolic-ref --quiet HEAD >/dev/null || exit 1
	base=$(git hash-object -t tree --stdin </dev/null) || exit 1
	overall_label='Overall vs empty tree (no commits yet)'
fi

shortstat() {
	git --no-pager diff --no-ext-diff --no-textconv --no-color --shortstat "$@" --
}

# Collect all results before printing: a failed diff must never look like zero.
staged=$(shortstat --cached) || exit 1
unstaged=$(shortstat) || exit 1
overall=$(shortstat "$base") || exit 1

print_stat() {
	printf '%s\n  %s\n\n' "$1" "${2:-0 files changed, 0 insertions(+), 0 deletions(-)}"
}

print_stat 'Staged' "${staged# }"
print_stat 'Unstaged' "${unstaged# }"
print_stat "$overall_label" "${overall# }"
printf '%s\n' \
	'Entire repository; untracked files excluded.' \
	'Binary files count as files, not text lines.' \
	'Overall compares the worktree with the base; changes can cancel out.'
