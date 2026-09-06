#!/bin/sh
# Linux user-level fallback. apply installs only; --upgrade is explicit and
# restricted to a binary installed by this script. Brew/apt/Scoop own their own.
set -eu
micro_target=$HOME/.local/bin/micro
micro_receipt=$HOME/.local/share/dotfiles/micro-release
micro_version=2.0.15
case ${1:-} in
    '') command -v micro >/dev/null 2>&1 && exit 0 ;;
    --upgrade)
        [ -f "$micro_receipt" ] && [ "$(command -v micro)" = "$micro_target" ] || {
            printf 'micro: no active managed release installation; upgrade with its package manager\n' >&2
            exit 1
        }
        micro_version=$(curl -fsSL https://api.github.com/repos/micro-editor/micro/releases/latest | jq -er '.tag_name | ltrimstr("v")')
        ;;
    *) printf 'usage: install-micro.sh [--upgrade]\n' >&2; exit 2 ;;
esac
case $micro_version in ''|*[!0-9.]*) printf 'micro: invalid release version\n' >&2; exit 2 ;; esac
case $(uname -m) in
    x86_64|amd64) micro_arch=linux64-static ;;
    aarch64|arm64) micro_arch=linux-arm64 ;;
    *) printf 'micro: unsupported Linux architecture\n' >&2; exit 2 ;;
esac
[ "$(uname -s)" = Linux ] || exit 2
micro_tmp=$(mktemp -d)
trap 'rm -rf "$micro_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
micro_archive=micro-$micro_version-$micro_arch.tar.gz
micro_url=https://github.com/micro-editor/micro/releases/download/v$micro_version/$micro_archive
curl -fL --retry 2 --connect-timeout 20 --max-time 180 "$micro_url" -o "$micro_tmp/$micro_archive"
curl -fsSL --retry 2 --max-time 45 "$micro_url.sha" -o "$micro_tmp/checksum"
read -r micro_expected micro_rest < "$micro_tmp/checksum"
[ "$micro_rest" = "$micro_archive" ] || { printf 'micro: checksum names unexpected archive\n' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    micro_actual=$(sha256sum "$micro_tmp/$micro_archive")
else
    micro_actual=$(shasum -a 256 "$micro_tmp/$micro_archive")
fi
[ "${micro_actual%% *}" = "$micro_expected" ] || { printf 'micro: checksum mismatch\n' >&2; exit 1; }
tar -xzf "$micro_tmp/$micro_archive" -C "$micro_tmp"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/dotfiles"
# Stage beside the destination for atomic replacement during explicit upgrades.
micro_stage=$(mktemp "$HOME/.local/bin/.micro.XXXXXX")
trap 'rm -rf "$micro_tmp"; rm -f "$micro_stage"' EXIT
install -m 755 "$micro_tmp/micro-$micro_version/micro" "$micro_stage"
mv -f "$micro_stage" "$micro_target"
printf '%s\n' "$micro_version" > "$micro_receipt"
