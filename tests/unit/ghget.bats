#!/usr/bin/env bats
# Unit tests for `ghget` in dot_config/zsh/tools/41_github.zsh.
#
# ghget parses GitHub tree URLs and downloads a subdirectory. The parsing path
# is pure string manipulation in zsh — high silent-regression risk (wrong
# owner/repo/branch slice → downloads the wrong thing, or a confusing failure
# half-way through). Tests stub `curl` and `tar` via PATH so no network runs.

load "../test_helper.bash"

GH_FILE="$REPO_ROOT/dot_config/zsh/tools/41_github.zsh"

# Stub curl + tar that just echo the args they were called with into a log
# file, so tests can assert on what URL curl was asked to fetch / what tar
# was asked to extract.
_install_curl_tar_stubs() {
  setup_path_stub
  : "${CAPTURE_LOG:=$BATS_STUB_DIR/capture.log}"
  export CAPTURE_LOG

  cat > "$BATS_STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CAPTURE_LOG"
# Emit minimal bytes so the pipe to tar has something — tar stub ignores input.
printf 'fakearchive'
EOF
  cat > "$BATS_STUB_DIR/tar" <<'EOF'
#!/usr/bin/env bash
echo "tar $*" >> "$CAPTURE_LOG"
# Drain stdin so curl doesn't get EPIPE.
cat > /dev/null
# Create the expected extracted directory so ghget's post-check passes.
# Args contain `--strip-components=N` and an archive path like
# `<repo>-<branch>/<subdir>`. The last positional arg (after --strip and -C)
# ends with the subdir we need to create under -C target.
#
# We extract:
#   -C <tmpdir>  → tmpdir is the flag-value right after -C
#   last positional → "<archive_root>/<subdir_path>" — we want the *leaf* of
#   subdir_path as the dir under tmpdir (because --strip-components drops
#   archive_root and any intermediate path components).
tmpdir=""
archive_entry=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) tmpdir="$2"; shift 2 ;;
    -*) shift ;;
    *)  archive_entry="$1"; shift ;;
  esac
done
leaf="${archive_entry##*/}"
mkdir -p "$tmpdir/$leaf"
: > "$tmpdir/$leaf/marker"
EOF
  chmod +x "$BATS_STUB_DIR/curl" "$BATS_STUB_DIR/tar"
}

# Run ghget under a temp $PWD so downloads land in an isolated dir that
# teardown will wipe.
_in_tmp_pwd() {
  _BATS_TMPPWD="$(mktemp -d "${TMPDIR:-/tmp}/bats-ghget.XXXXXX")"
  _BATS_STUB_DIRS+=("$_BATS_TMPPWD")
  cd "$_BATS_TMPPWD"
}

@test "ghget: missing arg prints usage and returns 1" {
  run zsh -f -c "source '$GH_FILE'; ghget"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: ghget"* ]]
}

@test "ghget: non-GitHub URL is rejected" {
  run zsh -f -c "source '$GH_FILE'; ghget https://gitlab.com/foo/bar/tree/main/dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid GitHub tree URL"* ]]
}

@test "ghget: URL without /tree/ segment is rejected" {
  run zsh -f -c "source '$GH_FILE'; ghget https://github.com/owner/repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid GitHub tree URL"* ]]
}

@test "ghget: URL with /blob/ (file, not tree) is rejected" {
  # parts[3] would be "blob", not "tree" — should fail validation.
  run zsh -f -c "source '$GH_FILE'; ghget https://github.com/owner/repo/blob/main/README.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid GitHub tree URL"* ]]
}

@test "ghget: valid URL feeds correct owner/repo/branch/path to curl and tar" {
  _install_curl_tar_stubs
  _in_tmp_pwd

  run zsh -f -c "
    source '$GH_FILE'
    ghget https://github.com/microsoft/qlib/tree/high-freq-execution/examples/trade
  "
  [ "$status" -eq 0 ]

  # curl must be asked for the branch tarball — regression guard for URL slicing.
  grep -F "archive/refs/heads/high-freq-execution.tar.gz" "$CAPTURE_LOG"
  grep -F "github.com/microsoft/qlib/" "$CAPTURE_LOG"

  # tar must be asked to extract the correct archive entry under <repo>-<branch>/.
  grep -F "qlib-high-freq-execution/examples/trade" "$CAPTURE_LOG"
  # And --strip-components must match the depth of subdir_path (2 levels here).
  grep -E "strip-components=2" "$CAPTURE_LOG"

  # The extracted leaf should have been moved into PWD.
  [ -d "trade" ]
  [ -f "trade/marker" ]
}

@test "ghget: strips query string and trailing slash from URL" {
  _install_curl_tar_stubs
  _in_tmp_pwd

  run zsh -f -c "
    source '$GH_FILE'
    ghget 'https://github.com/owner/repo/tree/main/pkg/?ref=abc'
  "
  [ "$status" -eq 0 ]
  # Branch must be 'main', not 'main/' and not 'main?ref=abc'.
  grep -F "archive/refs/heads/main.tar.gz" "$CAPTURE_LOG"
  grep -F "repo-main/pkg" "$CAPTURE_LOG"
  [ -d "pkg" ]
}

@test "ghget: refuses to overwrite an existing destination" {
  _install_curl_tar_stubs
  _in_tmp_pwd
  mkdir existing_dir  # will collide with leaf of the URL below

  run zsh -f -c "
    source '$GH_FILE'
    ghget https://github.com/owner/repo/tree/main/path/to/existing_dir
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"Destination already exists"* ]]
  # curl/tar must NOT have been called — we bail before network.
  [ ! -f "$CAPTURE_LOG" ] || ! grep -q "curl" "$CAPTURE_LOG"
}
