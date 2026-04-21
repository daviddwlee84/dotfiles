# Shared helpers for bats tests. Source from each .bats file:
#   load "../test_helper.bash"   # or the equivalent relative path
#
# Keep this file tiny. No bats-assert / bats-file / bats-support — plain
# bats built-ins ([ ], run, $status, $output) are enough.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
if [ "$(basename "$REPO_ROOT")" = "tests" ]; then
  REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
fi
export REPO_ROOT

_BATS_STUB_DIRS=()

# Create a temp directory and prepend it to PATH. Exposes the path via
# $BATS_STUB_DIR (not via stdout) so the PATH export actually sticks — using
# command substitution would run this in a subshell and discard the export.
setup_path_stub() {
  BATS_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bats-stub.XXXXXX")"
  _BATS_STUB_DIRS+=("$BATS_STUB_DIR")
  PATH="$BATS_STUB_DIR:$PATH"
  export PATH BATS_STUB_DIR
}

# Cleanup function. Call from your own teardown() if you override it:
#   teardown() { your_cleanup; cleanup_path_stubs; }
cleanup_path_stubs() {
  local dir
  for dir in "${_BATS_STUB_DIRS[@]:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
  done
  _BATS_STUB_DIRS=()
}

# Default teardown — fires only if the .bats file does not define its own.
teardown() { cleanup_path_stubs; }
