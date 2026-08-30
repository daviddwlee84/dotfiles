#!/usr/bin/env sh
# ~/.config/herdr/edit-config.sh
# Source: dot_config/herdr/executable_edit-config.sh (managed by chezmoi)
#
# Edit Herdr's active runtime config, validate that exact file, then reload the
# current server. Bound to prefix+alt+e in .chezmoitemplates/herdr/config.toml.
#
# $EDITOR must name one blocking executable or wrapper path. Command strings are
# deliberately not parsed or evaluated; wrap editors that need arguments (for
# example, a wrapper that runs `code --wait`). An unset/empty $EDITOR falls back
# to vi.
set -u
umask 077

backup=""
candidate=""

hold_failure() {
	rc=$1
	if [ -t 0 ]; then
		printf '\n[exit %s] press Enter to close…' "$rc" >&2
		IFS= read -r _ || :
	fi
}

fail() {
	rc=$1
	shift
	printf 'edit-config: %s\n' "$*" >&2
	hold_failure "$rc"
	exit "$rc"
}

restore_rejected_edit() {
	cause_rc=$1
	reason=$2
	candidate_rc=0

	candidate=$(mktemp "$target.invalid-XXXXXX")
	candidate_rc=$?
	if [ "$candidate_rc" -eq 0 ] && [ -n "$candidate" ]; then
		cp "$target" "$candidate"
		candidate_rc=$?
		if [ "$candidate_rc" -eq 0 ]; then
			chmod 600 "$candidate"
			candidate_rc=$?
		fi
	elif [ "$candidate_rc" -eq 0 ]; then
		candidate_rc=1
	fi

	backup_path=$backup
	mv -f "$backup" "$target"
	rollback_rc=$?
	if [ "$rollback_rc" -eq 0 ]; then
		backup=""
		printf 'edit-config: %s\n' "$reason" >&2
		printf 'edit-config: restored target: %s\n' "$target" >&2
		printf 'edit-config: backup restored from: %s\n' "$backup_path" >&2
		if [ "$candidate_rc" -eq 0 ]; then
			printf 'edit-config: rejected candidate retained: %s\n' "$candidate" >&2
			hold_failure "$cause_rc"
			exit "$cause_rc"
		fi

		if [ -n "$candidate" ]; then
			printf 'edit-config: rejected candidate preservation failed; partial artifact: %s\n' "$candidate" >&2
		else
			printf 'edit-config: rejected candidate preservation failed; no candidate path was created\n' >&2
		fi
		hold_failure "$candidate_rc"
		exit "$candidate_rc"
	fi

	printf 'edit-config: %s\n' "$reason" >&2
	printf 'edit-config: rollback failed; active target may still contain the rejected edit: %s\n' "$target" >&2
	if [ -n "$candidate" ]; then
		if [ "$candidate_rc" -eq 0 ]; then
			printf 'edit-config: rejected candidate retained: %s\n' "$candidate" >&2
		else
			printf 'edit-config: rejected candidate preservation failed; partial artifact: %s\n' "$candidate" >&2
		fi
	else
		printf 'edit-config: rejected candidate preservation failed; no candidate path was created\n' >&2
	fi
	printf 'edit-config: original backup retained: %s\n' "$backup" >&2
	hold_failure "$rollback_rc"
	exit "$rollback_rc"
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${HERDR_CONFIG_PATH:-}" ]; then
	target=$HERDR_CONFIG_PATH
elif [ -n "${HOME:-}" ]; then
	target=$HOME/.config/herdr/config.toml
else
	fail 1 'HOME is unset and HERDR_CONFIG_PATH is empty; cannot resolve target config'
fi

if [ -L "$target" ]; then
	fail 1 "target config must not be a symlink: $target"
fi
if [ ! -f "$target" ]; then
	fail 1 "target config must be an existing regular file: $target"
fi

original_mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$original_mode" ]; then
	[ "$rc" -ne 0 ] || rc=1
	fail "$rc" "could not read target mode before editing: $target"
fi

editor=${EDITOR:-vi}
case "$editor" in
-* | *[![:print:]]*)
	editor_path=""
	;;
*/*)
	editor_path=$editor
	;;
*)
	editor_path=$(command -v "$editor" 2>/dev/null)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		editor_path=""
	fi
	;;
esac
if [ -z "$editor_path" ] || [ ! -f "$editor_path" ] || [ ! -x "$editor_path" ]; then
	fail 127 "editor must name one blocking executable or wrapper path; use a wrapper for arguments such as 'code --wait': $editor"
fi

backup=$(mktemp "$target.backup-XXXXXX")
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$backup" ]; then
	[ "$rc" -ne 0 ] || rc=1
	fail "$rc" "could not create a same-directory backup for: $target"
fi

cp -p "$target" "$backup"
rc=$?
if [ "$rc" -ne 0 ]; then
	rm -f "$backup"
	cleanup_rc=$?
	if [ "$cleanup_rc" -ne 0 ]; then
		printf 'edit-config: incomplete backup could not be removed: %s\n' "$backup" >&2
	fi
	fail "$rc" "could not copy target metadata into backup: $backup"
fi

"$editor_path" "$target"
rc=$?
if [ "$rc" -ne 0 ]; then
	restore_rejected_edit "$rc" "editor failed while editing: $target"
fi

chmod "$original_mode" "$target"
rc=$?
if [ "$rc" -ne 0 ]; then
	restore_rejected_edit "$rc" "could not restore target mode after editing: $target"
fi

HERDR_CONFIG_PATH="$target" herdr config check
rc=$?
if [ "$rc" -ne 0 ]; then
	restore_rejected_edit "$rc" "edited target failed herdr config check: $target"
fi

herdr server reload-config
rc=$?
if [ "$rc" -ne 0 ]; then
	printf 'edit-config: Herdr server reload-config failed; valid edited target retained: %s\n' "$target" >&2
	printf 'edit-config: original backup retained: %s\n' "$backup" >&2
	hold_failure "$rc"
	exit "$rc"
fi

rm -f "$backup"
rc=$?
if [ "$rc" -ne 0 ]; then
	printf 'edit-config: reload succeeded but backup cleanup failed; valid edited target retained: %s\n' "$target" >&2
	printf 'edit-config: original backup retained: %s\n' "$backup" >&2
	hold_failure "$rc"
	exit "$rc"
fi
backup=""

exit 0
