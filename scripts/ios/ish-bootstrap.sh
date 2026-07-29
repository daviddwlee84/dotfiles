#!/bin/sh
# ish-bootstrap.sh — set up iSH (iOS) as a notes-sync + SSH-client appliance.
#
# Run ON THE iPad/iPhone, inside iSH:
#
#   wget -qO- https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/scripts/ios/ish-bootstrap.sh | sh
#
# This is NOT `chezmoi apply`. The main dotfiles cannot be installed on iSH at
# all — `bootstrap.sh` dies before writing a single file because
# `dotfiles_init.py` needs Python >= 3.11 and python-build-standalone publishes
# no i686-Linux target, so `uv python install` can never bootstrap. Even if you
# hand-placed the shell layer, an interactive zsh sources ~110 files, which is
# 1.9 s on native Apple Silicon and minutes under iSH's x86 interpreter.
#
# So this script deliberately installs a SMALL, hand-picked set: the few things
# that are genuinely useful on a phone, and nothing that would make the shell
# slow. See docs/playbooks/ios-terminals.md for the full reasoning.
#
# POSIX sh on purpose — iSH's default shell is BusyBox ash, and `bootstrap.sh`
# in this repo is bash-only (arrays), so it cannot be reused here.

set -eu

INFO() { printf '\033[1;34m[ish]\033[0m %s\n' "$*"; }
WARN() { printf '\033[1;33m[ish]\033[0m %s\n' "$*" >&2; }
DIE() {
    printf '\033[1;31m[ish]\033[0m %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 0. Sanity
# ---------------------------------------------------------------------------

[ "$(uname -m)" = "i686" ] || WARN "uname -m is '$(uname -m)', expected i686 — is this really iSH?"
command -v apk >/dev/null 2>&1 || DIE "no apk — this script is for iSH (Alpine), nothing else."

# ---------------------------------------------------------------------------
# 1. Alpine branch
# ---------------------------------------------------------------------------
#
# The App Store build of iSH pins Alpine v3.14, which went EOL 2023-05-01 and
# ships OpenSSH 8.6_p1. Moving forward is worth it, but NOT to the newest
# branch:
#
#   3.19  `sudo` crashes on launch; `procps` makes `uptime` segfault
#   3.20  installing `coreutils` breaks /dev
#   edge  Alpine formally raised the x86 baseline to SSE2 and builds with
#         -march=pentium-m. iSH's emulator has unimplemented gadgets in that
#         range, so a large fraction of the userland becomes unrunnable.
#
# 3.18 is the community's "last known sane" branch. We only *offer* the switch:
# repository surgery on someone's only copy of their notes should be opt-in.

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.18}"

current_branch() { sed -n '1s|.*/alpine/\([^/]*\)/.*|\1|p' /etc/apk/repositories 2>/dev/null; }

INFO "Alpine repositories currently: $(current_branch || echo unknown)"
if [ "${ISH_SWITCH_BRANCH:-0}" = "1" ]; then
    INFO "Switching to ${ALPINE_BRANCH} (ISH_SWITCH_BRANCH=1)"
    cp /etc/apk/repositories /etc/apk/repositories.bak
    cat >/etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community
EOF
    INFO "Backed up the old list to /etc/apk/repositories.bak"
else
    INFO "Keeping the current branch. To move to ${ALPINE_BRANCH}, re-run with:"
    INFO "    ISH_SWITCH_BRANCH=1 sh ish-bootstrap.sh"
    INFO "Do NOT switch to edge — see the comment block in this script."
fi

apk update || WARN "apk update failed — continuing with the cached index"

# ---------------------------------------------------------------------------
# 2. Packages
# ---------------------------------------------------------------------------
#
# Deliberately excluded, with reasons:
#   coreutils  breaks /dev on 3.20
#   sudo       crashes on launch on 3.19; you are already root in iSH
#   nodejs     installs fine and then SIGILLs — V8 emits instructions whose
#              gadgets iSH has not implemented. No agent CLI can run here.
#   ripgrep    Rust's i686 target assumes SSE2; reported illegal-instruction
#   zsh        works, but this repo's zsh layer is what makes it slow; ash is
#              the right shell on a phone

PKGS="git openssh-client tmux nano vim curl ca-certificates"

INFO "Installing: ${PKGS}"
# shellcheck disable=SC2086 # deliberate word splitting — apk takes a list
apk add ${PKGS} || DIE "apk add failed"

# ---------------------------------------------------------------------------
# 3. The Obsidian mount helper
# ---------------------------------------------------------------------------
#
# iSH reaches iOS Files through `mount -t ios null <dir>`, which pops the iOS
# folder picker and stores a security-scoped bookmark. The mount does NOT
# survive an app restart — you must re-issue it every session, which is why
# `mount -t ios` tends to appear a dozen times in anyone's shell history.
#
# Two more things bite every time:
#   - The mounted tree reports a different owner than root, so git refuses it
#     with "detected dubious ownership". `safe.directory` fixes it permanently
#     (it lands in ~/.gitconfig, inside the Alpine rootfs, so it persists).
#   - Re-running `mount` on an already-mounted point stacks another mount
#     instead of erroring, so the helper checks first.

MOUNT_POINT="${OBSIDIAN_MNT:-/mnt/dq/Obsidian}"
PROFILE="${HOME}/.profile"
MARKER_BEGIN="# >>> ish-bootstrap (obsidian) >>>"
MARKER_END="# <<< ish-bootstrap (obsidian) <<<"

mkdir -p "$MOUNT_POINT"

if [ -f "$PROFILE" ] && grep -qF "$MARKER_BEGIN" "$PROFILE"; then
    INFO "Obsidian helpers already present in ${PROFILE} — leaving them alone."
    INFO "Delete the block between the >>> / <<< markers to have them rewritten."
else
    INFO "Adding Obsidian helpers to ${PROFILE}"
    cat >>"$PROFILE" <<EOF

${MARKER_BEGIN}
# Managed by scripts/ios/ish-bootstrap.sh in daviddwlee84/dotfiles.
# Edit freely — re-running the bootstrap will not overwrite this block.
OBSIDIAN_MNT="${MOUNT_POINT}"
export OBSIDIAN_MNT

# An unmounted mount point is empty; that is the cheapest reliable probe here
# (iSH has no /proc/mounts entry for the ios fs, and mountpoint(1) is absent).
_ovault_mounted() {
    [ -d "\$OBSIDIAN_MNT" ] && [ -n "\$(ls -A "\$OBSIDIAN_MNT" 2>/dev/null)" ]
}

# ovault [SUBDIR] — ensure the vault is mounted, then cd into it.
# The mount is lost on every iSH restart, so this is the first thing to run.
ovault() {
    mkdir -p "\$OBSIDIAN_MNT" 2>/dev/null
    if ! _ovault_mounted; then
        echo "mounting \$OBSIDIAN_MNT — pick your Obsidian folder in the iOS dialog"
        mount -t ios null "\$OBSIDIAN_MNT" || {
            echo "mount failed (dialog cancelled?)" >&2
            return 1
        }
    fi
    cd "\$OBSIDIAN_MNT\${1:+/\$1}" || return 1
    # git refuses a tree it thinks someone else owns; the iOS fs always looks
    # that way. Register it once per repo — persists in ~/.gitconfig.
    if [ -d .git ]; then
        _repo="\$(pwd)"
        git config --global --get-all safe.directory 2>/dev/null \\
            | grep -qxF "\$_repo" \\
            || git config --global --add safe.directory "\$_repo"
        unset _repo
    fi
}

# ovsync [REPO] [MESSAGE] — commit local edits, rebase onto the remote, push.
# --autostash so an in-progress Obsidian write does not abort the rebase.
ovsync() {
    ovault "\${1:-}" || return 1
    [ -d .git ] || {
        echo "no git repo at \$(pwd)" >&2
        return 1
    }
    git add -A
    git diff --cached --quiet || git commit -m "\${2:-notes: sync from iOS \$(date +%F\\ %H:%M)}"
    # A branch with no upstream makes \`git pull --rebase\` bail with a wall of
    # text and never reach the push. Detect it and set the upstream instead.
    if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        git pull --rebase --autostash || return 1
        git push
    else
        echo "no upstream for '\$(git branch --show-current)' — pushing and setting it"
        git push -u origin HEAD
    fi
}
${MARKER_END}
EOF
fi

# ---------------------------------------------------------------------------
# 4. SSH
# ---------------------------------------------------------------------------

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
if [ ! -e "${HOME}/.ssh/config" ]; then
    INFO "Seeding ~/.ssh/config"
    cat >"${HOME}/.ssh/config" <<'EOF'
# iSH is suspended by iOS the moment it leaves the foreground, which drops
# idle connections without a clean FIN. Short keepalives surface that fast
# instead of leaving a wedged terminal.
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 2
    # Deliberately NOT ControlMaster: the master would die with the app on
    # every backgrounding and leave stale sockets behind.

# github over 443 — survives networks that block 22.
Host github.com
    HostName ssh.github.com
    Port 443
    User git
EOF
    chmod 600 "${HOME}/.ssh/config"
else
    INFO "Found an existing ~/.ssh/config — not touching it"
fi

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------

cat <<EOF

$(INFO "Done.")

  Next:
    1. Restart the shell (or: . ~/.profile)
    2. ovault              mount the vault and cd in
       ovault Jingle.AI    ...and descend into a repo
       ovsync Jingle.AI    commit + rebase + push
    3. Private key: put it at ~/.ssh/<name> and chmod 400

  iOS-side settings that matter more than anything in here:
    Settings > Display & Brightness > Auto-Lock > Never   (locking freezes iSH)
    Guided Access, locked to iSH, if you SSH INTO this device

  Not installed, on purpose: nodejs (SIGILLs), ripgrep (SIGILLs), sudo
  (crashes on 3.19), coreutils (breaks /dev on 3.20). No agent CLI can run
  here — see docs/playbooks/ios-terminals.md.
EOF
