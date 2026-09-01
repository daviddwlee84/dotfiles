#!/bin/sh
# Read-only branch containment report for Lazygit. This intentionally does not
# fetch: the report describes the remote-tracking refs currently on disk.

set -u

mode=git
selected=

while [ "$#" -gt 0 ]; do
	case "$1" in
	--mode)
		[ "$#" -ge 2 ] || {
			printf '%s\n' 'branch-insights: --mode needs a value' >&2
			exit 2
		}
		mode=$2
		shift 2
		;;
	--selected)
		[ "$#" -ge 2 ] || {
			printf '%s\n' 'branch-insights: --selected needs a value' >&2
			exit 2
		}
		selected=$2
		shift 2
		;;
	*)
		printf 'branch-insights: unknown argument: %s\n' "$1" >&2
		exit 2
		;;
	esac
done

case "$mode" in
git | pr) ;;
*)
	printf 'branch-insights: unsupported mode: %s\n' "$mode" >&2
	exit 2
	;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	printf '%s\n' 'Branch insights: not inside a Git repository.'
	exit 0
fi

ref_exists() {
	git show-ref --verify --quiet "$1"
}

short_remote_branch() {
	printf '%s\n' "${1#*/}"
}

base_name=
local_base=
remote_base=
base_override=$(git config --get lazygit.branchBase 2>/dev/null || true)

if [ -n "$base_override" ]; then
	case "$base_override" in
	refs/heads/*)
		base_name=${base_override#refs/heads/}
		;;
	refs/remotes/*)
		remote_base=${base_override#refs/remotes/}
		base_name=$(short_remote_branch "$remote_base")
		;;
	*)
		if ref_exists "refs/heads/$base_override"; then
			base_name=$base_override
		elif ref_exists "refs/remotes/$base_override"; then
			remote_base=$base_override
			base_name=$(short_remote_branch "$remote_base")
		else
			base_name=$base_override
		fi
		;;
	esac
fi

if [ -z "$base_name" ]; then
	remote_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [ -n "$remote_head" ]; then
		remote_base=$remote_head
		base_name=$(short_remote_branch "$remote_head")
	elif ref_exists refs/heads/main; then
		base_name=main
	elif ref_exists refs/heads/master; then
		base_name=master
	elif ref_exists refs/remotes/origin/main; then
		base_name=main
		remote_base=origin/main
	elif ref_exists refs/remotes/origin/master; then
		base_name=master
		remote_base=origin/master
	fi
fi

if [ -z "$base_name" ]; then
	printf '%s\n' 'Branch insights: no base branch found.'
	printf '%s\n' 'Set one for this repository with:'
	printf '%s\n' '  git config lazygit.branchBase <branch>'
	exit 0
fi

if ref_exists "refs/heads/$base_name"; then
	local_base=$base_name
	local_upstream=$(git rev-parse --abbrev-ref "$local_base@{upstream}" 2>/dev/null || true)
	if [ -n "$local_upstream" ]; then
		remote_base=$local_upstream
	fi
fi

if [ -z "$remote_base" ]; then
	if ref_exists "refs/remotes/origin/$base_name"; then
		remote_base=origin/$base_name
	fi
fi

if [ -z "$selected" ]; then
	selected=$(git branch --show-current 2>/dev/null || true)
fi

contains_mark() {
	branch=$1
	base=$2
	if [ -z "$base" ]; then
		printf '%s' '-'
	elif git merge-base --is-ancestor "$branch" "$base" >/dev/null 2>&1; then
		printf '%s' 'Y'
	else
		rc=$?
		if [ "$rc" -eq 1 ]; then printf '%s' 'N'; else printf '%s' '?'; fi
	fi
}

ahead_behind() {
	left=$1
	right=$2
	git rev-list --left-right --count "$left...$right" 2>/dev/null || printf '%s\n' '? ?'
}

upstream_state() {
	branch=$1
	upstream=$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch")
	if [ -z "$upstream" ]; then
		printf '%s' '-'
		return
	fi
	if ! ref_exists "refs/remotes/$upstream" && ! ref_exists "refs/heads/$upstream"; then
		printf '%s' 'gone'
		return
	fi
	counts=$(ahead_behind "$upstream" "$branch")
	behind=$(printf '%s\n' "$counts" | awk '{print $1}')
	ahead=$(printf '%s\n' "$counts" | awk '{print $2}')
	if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
		printf '%s' '='
	elif [ "$behind" = 0 ]; then
		printf 'up%s' "$ahead"
	elif [ "$ahead" = 0 ]; then
		printf 'down%s' "$behind"
	else
		printf 'down%s/up%s' "$behind" "$ahead"
	fi
}

pr_file=
pr_status=disabled
if [ "$mode" = pr ]; then
	pr_status=unavailable
	remote_name=origin
	if [ -n "$remote_base" ]; then remote_name=${remote_base%%/*}; fi
	remote_url=$(git remote get-url "$remote_name" 2>/dev/null || true)
	case "$remote_url" in
	*github.com*)
		if command -v gh >/dev/null 2>&1; then
			pr_file=$(mktemp "${TMPDIR:-/tmp}/lazygit-branch-pr.XXXXXX") || pr_file=
			if [ -n "$pr_file" ]; then
				trap 'rm -f "$pr_file"' EXIT HUP INT TERM
				if gh pr list --state all --limit 200 \
					--json headRefName,baseRefName,state,isDraft,isCrossRepository,number,createdAt \
					--jq '.[] | select(.isCrossRepository | not) | [.headRefName, (if .isDraft then "DRAFT" else .state end), .baseRefName, (.number|tostring), .createdAt] | @tsv' \
					>"$pr_file" 2>/dev/null; then
					pr_status=loaded
				fi
			fi
		fi
		;;
	*) pr_status=not-github ;;
	esac
fi

printf '%s\n' 'Branch insights (read-only; remote refs are not fetched)'
printf 'Local base:  %s\n' "${local_base:--}"
printf 'Remote base: %s\n' "${remote_base:--}"

if [ -n "$local_base" ] && [ -n "$remote_base" ]; then
	base_counts=$(ahead_behind "$local_base" "$remote_base")
	local_ahead=$(printf '%s\n' "$base_counts" | awk '{print $1}')
	local_behind=$(printf '%s\n' "$base_counts" | awk '{print $2}')
	printf 'Local %s vs %s: ahead %s, behind %s\n' "$local_base" "$remote_base" "$local_ahead" "$local_behind"
fi

if [ "$mode" = pr ]; then
	printf 'GitHub PR data: %s\n' "$pr_status"
fi

count_base=$remote_base
[ -n "$count_base" ] || count_base=$local_base
printf '\n%-3s %-3s %-3s %6s %6s %-13s %-12s %-10s %s' 'SEL' 'LOC' 'REM' 'BASE-' 'BASE+' 'UPSTREAM' 'WORKTREE' 'DATE' 'BRANCH'
if [ "$mode" = pr ]; then printf '  %s' 'PR'; fi
printf '\n'

git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads | while IFS= read -r branch; do
	[ -n "$branch" ] || continue
	marker=
	[ "$branch" = "$selected" ] && marker='>'
	local_mark=$(contains_mark "$branch" "$local_base")
	remote_mark=$(contains_mark "$branch" "$remote_base")
	counts=$(ahead_behind "$count_base" "$branch")
	base_only=$(printf '%s\n' "$counts" | awk '{print $1}')
	branch_only=$(printf '%s\n' "$counts" | awk '{print $2}')
	upstream=$(upstream_state "$branch")
	worktree=$(git for-each-ref --format='%(worktreepath)' "refs/heads/$branch")
	if [ -n "$worktree" ]; then worktree=$(basename "$worktree"); else worktree=-; fi
	commit_date=$(git log -1 --format='%cs' "$branch" 2>/dev/null || printf '%s' '-')

	printf '%-3s %-3s %-3s %6s %6s %-13s %-12s %-10s %s' \
		"$marker" "$local_mark" "$remote_mark" "$base_only" "$branch_only" "$upstream" "$worktree" "$commit_date" "$branch"

	if [ "$mode" = pr ]; then
		pr=-
		if [ "$pr_status" = unavailable ]; then
			pr='?'
		elif [ "$pr_status" = loaded ] && [ "$branch" != "$base_name" ]; then
			pr_line=$(awk -F '\t' -v branch="$branch" '$1 == branch { print; exit }' "$pr_file")
			if [ -n "$pr_line" ]; then
				pr_state=$(printf '%s\n' "$pr_line" | awk -F '\t' '{print $2}')
				pr_base=$(printf '%s\n' "$pr_line" | awk -F '\t' '{print $3}')
				pr_number=$(printf '%s\n' "$pr_line" | awk -F '\t' '{print $4}')
				pr="${pr_state}->${pr_base}#${pr_number}"
			fi
		fi
		printf '  %s' "$pr"
	fi
	printf '\n'
done

printf '\n%s\n' 'LOC/REM: branch tip is an ancestor of local/remote base (Y/N).'
printf '%s\n' 'BASE-/BASE+: commits only on the comparison base / only on the branch.'
printf '%s\n' 'A merged PR can still show REM=N after squash or rebase merge.'
