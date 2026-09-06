#!/bin/sh
printf '%s\n' "$@" > "$EDITOR_TEST_LOG"
printf '%s\n' "${SUDO_EDITOR:-}" > "$EDITOR_TEST_LOG.editor"
if [ -n "${EDITOR_TEST_DELAY:-}" ]; then /bin/sleep "$EDITOR_TEST_DELAY"; fi
printf 'closed\n' > "$EDITOR_TEST_CLOSED"
exit "${EDITOR_TEST_EXIT:-0}"
