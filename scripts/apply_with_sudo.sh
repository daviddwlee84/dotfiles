#!/usr/bin/env bash
# apply_with_sudo.sh — run `chezmoi apply` (or `chezmoi init --apply`) with
# sudo password injected via `CHEZMOI_SUDO_PASSWORD_FILE`, for environments
# where the chezmoi-spawned run-script subprocess can't open /dev/tty
# (CentOS 7 + AD/LDAP user, missing pam_systemd, etc).
#
# Why this exists:
#   The shared sudo helper (scripts/lib/sudo_shared.sh) prompts on /dev/tty
#   when sudo isn't passwordless. Some Linux configurations break that path
#   — see pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md for the full
#   diagnosis. This wrapper bypasses the broken path by pre-staging the
#   password in a 0600 tmpfile and pointing the helper at it.
#
# Usage:
#   bash scripts/apply_with_sudo.sh                          # chezmoi apply
#   bash scripts/apply_with_sudo.sh --init <repo-url>        # chezmoi init --apply
#   bash scripts/apply_with_sudo.sh --pass-from-file FILE    # don't prompt; read from FILE
#   bash scripts/apply_with_sudo.sh --pass-from-env          # read $SUDO_PASSWORD env var
#   bash scripts/apply_with_sudo.sh --keep-file              # don't shred (debugging)
#
# Exit code: chezmoi's exit code (after shredding the password file).
#
# Security:
#   - tmpfile is created with umask 077 (mode 0600) under $TMPDIR.
#   - shredded on EXIT (any signal) unless --keep-file given.
#   - password is never put on the command line or in env after handoff.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

mode="apply"
repo_url=""
pass_source="prompt"
pass_file_in=""
keep_file=0

while (($#)); do
  case "$1" in
    --init)
      mode="init"
      shift
      [[ $# -eq 0 || "$1" == --* ]] && {
        echo "ERROR: --init requires a repo URL" >&2
        exit 2
      }
      repo_url="$1"
      shift
      ;;
    --pass-from-file)
      pass_source="file"
      shift
      [[ $# -eq 0 ]] && {
        echo "ERROR: --pass-from-file requires FILE" >&2
        exit 2
      }
      pass_file_in="$1"
      shift
      ;;
    --pass-from-env)
      pass_source="env"
      shift
      ;;
    --keep-file)
      keep_file=1
      shift
      ;;
    -h | --help)
      usage 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage 2
      ;;
  esac
done

# 1. Acquire password into a 0600 tmpfile under $TMPDIR.
tmp_pw_file="$(mktemp -t cz_sudo.XXXXXXXX)"
chmod 600 "$tmp_pw_file"

cleanup() {
  if ((keep_file)); then
    echo "[apply_with_sudo] --keep-file given; password stays at $tmp_pw_file" >&2
  elif command -v shred >/dev/null 2>&1; then
    shred -u "$tmp_pw_file" 2>/dev/null || rm -f "$tmp_pw_file"
  else
    # macOS / minimal containers: shred not always available.
    rm -f "$tmp_pw_file"
  fi
}
trap cleanup EXIT INT TERM HUP

case "$pass_source" in
  file)
    [[ -r "$pass_file_in" ]] || {
      echo "ERROR: cannot read $pass_file_in" >&2
      exit 2
    }
    cat "$pass_file_in" >"$tmp_pw_file"
    ;;
  env)
    [[ -n "${SUDO_PASSWORD:-}" ]] || {
      echo "ERROR: \$SUDO_PASSWORD is empty" >&2
      exit 2
    }
    printf '%s\n' "$SUDO_PASSWORD" >"$tmp_pw_file"
    unset SUDO_PASSWORD
    ;;
  prompt)
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
      echo "ERROR: no /dev/tty for password prompt; use --pass-from-file or --pass-from-env" >&2
      exit 2
    fi
    printf '[apply_with_sudo] sudo password for %s: ' "$USER" >/dev/tty
    IFS= read -rs pw </dev/tty
    echo >/dev/tty
    [[ -n "$pw" ]] || {
      echo "ERROR: empty password" >&2
      exit 2
    }
    printf '%s\n' "$pw" >"$tmp_pw_file"
    unset pw
    ;;
esac

# Validate against sudo before invoking chezmoi — saves a long apply that
# would otherwise hit the password-file branch and abort with "rejected".
if ! sudo -S -v -p '' <"$tmp_pw_file" 2>/dev/null; then
  echo "ERROR: sudo rejected the supplied password" >&2
  exit 1
fi

export CHEZMOI_SUDO_PASSWORD_FILE="$tmp_pw_file"

# 2. Locate chezmoi: prefer ~/.local/bin (where get.chezmoi.io drops it),
#    fall back to PATH lookup.
chezmoi_bin="${CHEZMOI:-}"
if [[ -z "$chezmoi_bin" ]]; then
  if [[ -x "$HOME/.local/bin/chezmoi" ]]; then
    chezmoi_bin="$HOME/.local/bin/chezmoi"
  elif command -v chezmoi >/dev/null 2>&1; then
    chezmoi_bin="$(command -v chezmoi)"
  else
    echo "ERROR: chezmoi not found. Install first:" >&2
    echo "    sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- -b \"\$HOME/.local/bin\"" >&2
    exit 127
  fi
fi

# 3. Run chezmoi. The helper inside the run-script will adopt the password
#    file, validate, move it into the shared state dir, spawn the watchdog,
#    and unset CHEZMOI_SUDO_PASSWORD_FILE in the subprocess.
case "$mode" in
  init)
    echo "[apply_with_sudo] $chezmoi_bin init --apply $repo_url" >&2
    "$chezmoi_bin" init --apply "$repo_url"
    ;;
  apply)
    echo "[apply_with_sudo] $chezmoi_bin apply" >&2
    "$chezmoi_bin" apply
    ;;
esac
