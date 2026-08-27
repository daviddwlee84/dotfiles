# 96_ssh_setup.sh - Interactive SSH key setup for remote machines (shared).
# Moved from dot_config/zsh/tools/96_ssh_setup.zsh. Zsh-isms replaced:
#   emulate -L zsh                  → gated on $ZSH_VERSION
#   setopt localoptions pipefail    → gated on $ZSH_VERSION (bash: set -o pipefail)
#   ~/.ssh/*.pub(N)  (nullglob)     → shopt -s nullglob / setopt nullglob dispatch
#   print -u2 --                    → printf >&2
#   print "..."                     → printf
#   print -n "..."                  → printf '%s' (no newline)
#   ${key_path:t}    (basename)     → ${key_path##*/}
#   ${#existing_keys}               → ${#existing_keys[@]}
#
# Usage: ssh-setup-remote [user@]host
#   SSH_SETUP_ASSUME_YES=1  take every prompt's default (scripted re-runs, tests)
#   SSH_SETUP_KEY=~/.ssh/x  skip the key picker and use this key
#   SSH_SETUP_NO_MUX=1      do not open a ControlMaster per host
#   SSH_SETUP_NO_GUM=1      plain prompts even where gum is installed
#
# Walks through: pick/create key → install the public key → copy the key pair to
# the remote → add SSH config entries. It resolves the target's FULL ProxyJump
# chain first and repeats the flow for every jump host, outermost first, so a
# multi-hop target ends up passwordless at every hop rather than only the last.
# Remotes running Windows OpenSSH sshd (no ssh-copy-id, and admin accounts read
# only administrators_authorized_keys) get an equivalent PowerShell path.
# See docs/tutorials/setup_ssh_key_on_remote.md for the full tutorial.

# _ssh_cfg_py — python3-backed SSH-config parse/edit helper used by ssh-setup-remote.
# Operates on the config tree rooted at ${SSH_CFG_ROOT:-~/.ssh/config}, following
# `Include` directives RECURSIVELY (glob + ~/relative/absolute), so a Host defined in a
# config.d/ drop-in is found and edited in the file it actually lives in. Returns 127 when
# python3 is absent so callers can fall back to a plain append.
#
# Subcommands:
#   find <alias> [keypath]                 stdout: kv lines, then "---BLOCK---", then the
#                                          matched block. rc 0 = found, 3 = not found.
#   insert <file> <alias> <key> <action> [--identities-only]
#                                          action: insert | replace | add. Edits the block
#                                          in <file> in place (atomic, mode 0600).
#   ensure-include                         rc 0 if ~/.ssh/config.d is reachable via Include,
#                                          else rc 1.
#   add-include                            prepend `Include ~/.ssh/config.d/*` to the root
#                                          config (idempotent).
_ssh_cfg_py() {
  command -v python3 >/dev/null 2>&1 || return 127
  python3 - "$@" <<'PY'
import os, re, sys, glob, pathlib, tempfile

ROOT = pathlib.Path(os.environ.get("SSH_CFG_ROOT") or os.path.expanduser("~/.ssh/config"))
SSH_DIR = ROOT.parent
HOME = os.path.expanduser("~")

HOST_RE  = re.compile(r"(?i)^(\s*)host\s+(.+?)\s*$")
BREAK_RE = re.compile(r"(?i)^\s*(host|match)\b")
IDF_RE   = re.compile(r"(?i)^(\s*)identityfile\s+(.+?)\s*$")
IDO_RE   = re.compile(r"(?i)^\s*identitiesonly\b")
INC_RE   = re.compile(r"(?i)^\s*include\s+(.+?)\s*$")


def expand(pat):
    pat = os.path.expanduser(pat)
    if not os.path.isabs(pat):
        pat = os.path.join(str(SSH_DIR), pat)
    return pat


def resolve_includes(start):
    seen, files = set(), []

    def walk(path):
        rp = os.path.realpath(path)
        if rp in seen:
            return
        seen.add(rp)
        p = pathlib.Path(path)
        if not p.is_file():
            return
        files.append(p)
        for line in p.read_text(errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = INC_RE.match(line)
            if not m:
                continue
            for pat in m.group(1).split():
                for f in sorted(glob.glob(expand(pat))):
                    walk(f)

    walk(str(start))
    return files


def norm(path):
    return os.path.realpath(os.path.expanduser(path.strip().strip('"')))


def host_patterns(line):
    m = HOST_RE.match(line)
    return m.group(2).split() if m else None


def block_matches(line, alias):
    pats = host_patterns(line)
    if not pats:
        return False
    return any(p == alias and not re.search(r"[*?!]", p) for p in pats)


def find_block(alias, files):
    for f in files:
        lines = f.read_text(errors="replace").splitlines()
        i = 0
        while i < len(lines):
            if block_matches(lines[i], alias):
                j = i + 1
                while j < len(lines) and not BREAK_RE.match(lines[j]):
                    j += 1
                return f, lines, i, j
            i += 1
    return None


def tildify(path):
    ap = os.path.abspath(os.path.expanduser(path))
    rel = os.path.relpath(ap, HOME)
    if not rel.startswith(".."):
        return "~/" + rel
    return path


def write_atomic(f, lines):
    fd, tmp = tempfile.mkstemp(dir=str(f.parent))
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, str(f))
        os.chmod(str(f), 0o600)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def configd_reachable():
    target = os.path.realpath(str(SSH_DIR / "config.d"))
    for f in resolve_includes(ROOT):
        for line in f.read_text(errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            m = INC_RE.match(line)
            if not m:
                continue
            for pat in m.group(1).split():
                if os.path.realpath(os.path.dirname(expand(pat))) == target:
                    return True
    return False


def cmd_find(alias, keypath):
    res = find_block(alias, resolve_includes(ROOT))
    if not res:
        print("found=0")
        return 3
    f, lines, i, j = res
    block = lines[i:j]
    idf = [m for m in (IDF_RE.match(b) for b in block) if m]
    keyn = norm(keypath) if keypath else ""
    present = bool(keyn) and any(norm(m.group(2)) == keyn for m in idf)
    print("found=1")
    print("file=%s" % f)
    print("has_identityfile=%d" % (1 if idf else 0))
    print("has_identitiesonly=%d" % (1 if any(IDO_RE.match(b) for b in block) else 0))
    print("key_present=%d" % (1 if present else 0))
    print("---BLOCK---")
    sys.stdout.write("\n".join(block) + "\n")
    return 0


def cmd_insert(file, alias, keypath, action, identities_only):
    f = pathlib.Path(file)
    lines = f.read_text(errors="replace").splitlines()
    res = find_block(alias, [f])
    if not res:
        sys.stderr.write("block for %s not found in %s\n" % (alias, file))
        return 2
    _, _, i, j = res
    block = lines[i:j]

    indent = "    "
    for b in block[1:]:
        if b.strip() and b[0] in " \t":
            indent = b[: len(b) - len(b.lstrip())]
            break

    idf_line = "%sIdentityFile %s" % (indent, tildify(keypath))
    idf_idx = [k for k, b in enumerate(block) if IDF_RE.match(b)]

    if action == "replace" and idf_idx:
        block[idf_idx[0]] = idf_line
    elif action == "add" or not idf_idx:
        ins = len(block)
        while ins > 1 and not block[ins - 1].strip():
            ins -= 1
        block.insert(ins, idf_line)
    else:  # action == insert but an IdentityFile already exists -> replace first
        block[idf_idx[0]] = idf_line

    if identities_only and not any(IDO_RE.match(b) for b in block):
        pos = next((k for k, b in enumerate(block) if IDF_RE.match(b)), len(block) - 1)
        block.insert(pos + 1, "%sIdentitiesOnly yes" % indent)

    write_atomic(f, lines[:i] + block + lines[j:])
    return 0


def cmd_add_include():
    if configd_reachable():
        return 0
    target = tildify(str(SSH_DIR / "config.d"))
    inc = ["# Load drop-in host configs from %s/" % target, "Include %s/*" % target, ""]
    lines = ROOT.read_text(errors="replace").splitlines() if ROOT.is_file() else []
    k = 0
    while k < len(lines) and (not lines[k].strip() or lines[k].lstrip().startswith("#")):
        k += 1
    ROOT.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(ROOT, lines[:k] + inc + lines[k:])
    return 0


def main(argv):
    if not argv:
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "find":
        return cmd_find(rest[0], rest[1] if len(rest) > 1 else "")
    if cmd == "insert":
        return cmd_insert(rest[0], rest[1], rest[2], rest[3], "--identities-only" in rest[4:])
    if cmd == "ensure-include":
        return 0 if configd_reachable() else 1
    if cmd == "add-include":
        return cmd_add_include()
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


sys.exit(main(sys.argv[1:]))
PY
}

# ── ProxyJump-aware driver ─────────────────────────────────────────────────
#
# `ssh-setup-remote zr`, where zr is reached via `ProxyJump zr-windows`, used to
# set up ONLY zr: ssh(1) tunnels through the jump host transparently, so the
# wizard never saw it and every later connection still asked for the jump host's
# password. The public entry point is now a driver that resolves the whole chain
# first -- recursively, because a jump host can have its own ProxyJump -- and
# runs the same per-host flow outermost-first.
#
# Jump detection goes through `ssh -G`, deliberately NOT through _ssh_cfg_py:
# only ssh itself applies the real Host/Match precedence, and it simply omits
# the `proxyjump` line when there is none (an explicit `ProxyJump none` renders
# as the literal "none"). _ssh_cfg_py stays what it always was, a block editor.

# Read one answer into $_SSH_SETUP_REPLY. With SSH_SETUP_ASSUME_YES=1 every
# prompt takes its own default (an empty answer) without blocking -- that is what
# the bats tests drive, and it makes a re-run scriptable.
_ssh_setup_read() {
  if [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ]; then
    _SSH_SETUP_REPLY=""
    printf '(default)\n'
    return 0
  fi
  IFS= read -r _SSH_SETUP_REPLY || _SSH_SETUP_REPLY=""
}

# ── Prompting ──────────────────────────────────────────────────────────────
#
# A bare `read -r` gives no line editing: pressing Left inserts a literal ^[[D
# instead of moving the cursor, which makes fixing a typo in a long key path
# impossible. Three layers, best first:
#
#   1. gum        -- arrow keys, editable defaults, a real picker for the key
#                    list. Already installed and repo-managed here (ansible
#                    devtools role, docs/tools/gum.md); strictly optional.
#   2. readline / ZLE -- bash `read -e` (readline; works in a NON-interactive
#                    bash as long as stdin is a tty, which is exactly how
#                    `tsnet --setup-remote` invokes this file) or zsh `vared`
#                    (needs an interactive shell for ZLE, hence the guard).
#   3. plain `read` -- pipes, SSH_SETUP_ASSUME_YES, no tty.
#
# Opt out of gum with SSH_SETUP_NO_GUM=1.

_ssh_setup_have_tty() { [ -t 0 ] && [ -t 1 ]; }

_ssh_setup_use_gum() {
  [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ] && return 1
  [ "${SSH_SETUP_NO_GUM:-0}" = "1" ] && return 1
  _ssh_setup_have_tty || return 1
  command -v gum >/dev/null 2>&1
}

# Read one line into $_SSH_SETUP_REPLY with editing when available.
# $1 prompt, $2 optional default (pre-filled and editable under gum/ZLE/bash>=4,
# shown in brackets otherwise).
_ssh_setup_edit_read() {
  local prompt="$1" default="${2:-}"

  if _ssh_setup_use_gum; then
    _SSH_SETUP_REPLY="$(gum input --prompt "$prompt " --value "$default")" \
      || _SSH_SETUP_REPLY="$default"
    return 0
  fi

  if _ssh_setup_have_tty; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      # vared drives ZLE, which only exists in an interactive zsh.
      if [[ -o interactive ]]; then
        _SSH_SETUP_REPLY="$default"
        vared -p "$prompt " -c _SSH_SETUP_REPLY || _SSH_SETUP_REPLY="$default"
        return 0
      fi
    elif [ -n "${BASH_VERSION:-}" ]; then
      # `read -i` is bash >= 4; macOS still ships bash 3.2 as /bin/bash, where
      # -i is a hard "invalid option" error, so fall back to a bracketed hint.
      if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [ -n "$default" ]; then
        IFS= read -e -r -p "$prompt " -i "$default" _SSH_SETUP_REPLY \
          || _SSH_SETUP_REPLY="$default"
        return 0
      fi
      local hint="$prompt "
      [ -n "$default" ] && hint="$prompt [$default] "
      IFS= read -e -r -p "$hint" _SSH_SETUP_REPLY || _SSH_SETUP_REPLY=""
      [ -n "$_SSH_SETUP_REPLY" ] || _SSH_SETUP_REPLY="$default"
      return 0
    fi
  fi

  printf '%s ' "$prompt"
  [ -n "$default" ] && printf '[%s] ' "$default"
  _ssh_setup_read
  [ -n "$_SSH_SETUP_REPLY" ] || _SSH_SETUP_REPLY="$default"
}

# Yes/no. $1 question, $2 default (yes|no, default yes). Returns 0 for yes.
_ssh_setup_confirm() {
  local q="$1" def="${2:-yes}"

  if [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ]; then
    printf '%s (%s)\n' "$q" "$def"
    [ "$def" = "yes" ]
    return
  fi

  if _ssh_setup_use_gum; then
    if [ "$def" = "yes" ]; then
      gum confirm --default "$q"
    else
      gum confirm --default=false "$q"
    fi
    return
  fi

  local hint="[Y/n]"
  [ "$def" = "yes" ] || hint="[y/N]"
  _ssh_setup_edit_read "$q $hint"
  case "$_SSH_SETUP_REPLY" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *)     [ "$def" = "yes" ] ;;
  esac
}

# Free text with a default. $1 label, $2 default. Result in $_SSH_SETUP_REPLY.
_ssh_setup_input() {
  local label="$1" default="${2:-}"
  if [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ]; then
    _SSH_SETUP_REPLY="$default"
    printf '%s: %s (default)\n' "$label" "$default"
    return 0
  fi
  _ssh_setup_edit_read "$label:" "$default"
}

# Pick one of a list. $1 header, $2 default value, rest are the options.
# Result in $_SSH_SETUP_REPLY.
_ssh_setup_choose() {
  local header="$1" default="$2"
  shift 2

  if [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ]; then
    _SSH_SETUP_REPLY="$default"
    printf '%s: %s (default)\n' "$header" "$default"
    return 0
  fi

  if _ssh_setup_use_gum; then
    local sel
    sel="$(printf '%s\n' "$@" | gum choose --header "$header" --height 12 \
             ${default:+--selected "$default"})" || sel=""
    _SSH_SETUP_REPLY="${sel:-$default}"
    return 0
  fi

  printf '%s\n' "$header"
  local i=1 o
  for o in "$@"; do
    printf '  %d) %s\n' "$i" "$o"
    i=$((i + 1))
  done
  _ssh_setup_edit_read "Choice [1-$#]"
  case "$_SSH_SETUP_REPLY" in
    ''|*[!0-9]*) _SSH_SETUP_REPLY="$default" ;;
    *)
      if [ "$_SSH_SETUP_REPLY" -ge 1 ] && [ "$_SSH_SETUP_REPLY" -le "$#" ]; then
        # Index into the positional parameters -- uniform across bash (0-based
        # arrays) and zsh (1-based arrays), which $@ indexing is not.
        eval "_SSH_SETUP_REPLY=\${$_SSH_SETUP_REPLY}"
      else
        _SSH_SETUP_REPLY="$default"
      fi
      ;;
  esac
}

# Split a ProxyJump hop spec ([user@]host[:port], possibly an [IPv6] literal)
# into $_SSH_HOP_DEST + $_SSH_HOP_PORT. ssh-copy-id and scp reject "host:port",
# so the port has to travel as a separate -p/-P flag.
_ssh_setup_split_hop() {
  local spec="$1"
  _SSH_HOP_DEST="$spec"
  _SSH_HOP_PORT=""
  case "$spec" in
    *']:'*) _SSH_HOP_PORT="${spec##*]:}"; _SSH_HOP_DEST="${spec%:*}" ;;
    *']')   ;;
    *:*)    _SSH_HOP_PORT="${spec##*:}";  _SSH_HOP_DEST="${spec%:*}" ;;
  esac
  case "$_SSH_HOP_PORT" in
    ''|*[!0-9]*) _SSH_HOP_PORT=""; _SSH_HOP_DEST="$spec" ;;
  esac
}

# The ProxyJump hops declared for one host, one per line, "none" treated as
# empty. `ssh -G` prints at most one proxyjump line; its value may be a
# comma-separated chain (`ssh -J a,b`).
_ssh_setup_jump_hops() {
  ssh -G "$1" 2>/dev/null | awk '
    tolower($1) == "proxyjump" {
      v = $2
      for (i = 3; i <= NF; i++) v = v " " $i
      if (tolower(v) == "none") exit
      n = split(v, parts, ",")
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      exit
    }'
}

# Depth-first walk feeding _ssh_setup_chain. $_SSH_CHAIN_SEEN breaks cycles
# (a config that jumps back to an ancestor would otherwise recurse forever);
# $_SSH_CHAIN_ADDED de-duplicates a hop shared by two branches.
_ssh_setup_walk() {
  local host="$1" hop hops
  case " $_SSH_CHAIN_SEEN " in
    *" $host "*) return 0 ;;
  esac
  _SSH_CHAIN_SEEN="$_SSH_CHAIN_SEEN $host"
  hops="$(_ssh_setup_jump_hops "$host")"
  while IFS= read -r hop; do
    [ -n "$hop" ] || continue
    _ssh_setup_walk "$hop"
    # A cycle back to the requested target must not list the target as its own
    # jump host; _SSH_CHAIN_SEEN already stopped the recursion.
    [ "$hop" = "$_SSH_CHAIN_ROOT" ] && continue
    case " $_SSH_CHAIN_ADDED " in
      *" $hop "*) ;;
      *) _SSH_CHAIN_ADDED="$_SSH_CHAIN_ADDED $hop"
         _SSH_CHAIN_OUT="${_SSH_CHAIN_OUT}${hop}
" ;;
    esac
  done <<EOF
$hops
EOF
}

# Every jump host needed to reach $1, outermost first, one per line.
# The target itself is NOT included.
_ssh_setup_chain() {
  _SSH_CHAIN_SEEN=""
  _SSH_CHAIN_ADDED=""
  _SSH_CHAIN_OUT=""
  _SSH_CHAIN_ROOT="$1"
  _ssh_setup_walk "$1"
  printf '%s' "$_SSH_CHAIN_OUT"
}

# ── Connection multiplexing ────────────────────────────────────────────────
#
# Walking a chain multiplies password prompts: probe + ssh-copy-id + scp +
# chmod + config append is up to six connections PER HOP, and none of them can
# use a key yet -- that is the whole point of the exercise. One ControlMaster
# per host collapses that to a single password.
#
# The socket path is bounded, and that bound is load-bearing: it goes into a
# sockaddr_un, which holds 104 bytes on macOS/BSD and 108 on Linux. %C expands
# to a 40-char hash, and $TMPDIR on macOS is already ~49 bytes
# (/var/folders/<2>/<26>/T/), so the obvious "$TMPDIR/ssh-setup.XXXXXX/%C" is
# 107 bytes -- over the limit. ssh then fails EVERY connection with
# `ControlPath too long` before it opens a socket, which reads downstream as
# "the remote is unreachable/unidentifiable". See
# pitfalls/ssh-controlpath-too-long-macos-tmpdir.md.
#
# So: try short bases first and verify the length rather than assuming it.
# Opt out with SSH_SETUP_NO_MUX=1.

# Longest directory we accept: dir + "/" + 40-char %C must stay under 104.
_SSH_SETUP_MUX_MAXDIR=55

_ssh_setup_mux_start() {
  _SSH_SETUP_MUX_PATH=""
  _SSH_SETUP_MUX_DIR=""
  _SSH_SETUP_MUX_HOSTS=""
  [ "${SSH_SETUP_NO_MUX:-0}" = "1" ] && return 0
  [ "${SSH_SETUP_ASSUME_YES:-0}" = "1" ] && return 0

  local base dir
  for base in /tmp "${TMPDIR:-/tmp}" "$HOME/.ssh"; do
    [ -d "$base" ] && [ -w "$base" ] || continue
    # Cheap pre-check so we do not create a directory we are going to reject.
    [ "${#base}" -le "$_SSH_SETUP_MUX_MAXDIR" ] || continue
    dir="$(mktemp -d "${base%/}/sshmux.XXXXXX" 2>/dev/null)" || continue
    if [ "${#dir}" -le "$_SSH_SETUP_MUX_MAXDIR" ]; then
      _SSH_SETUP_MUX_DIR="$dir"
      _SSH_SETUP_MUX_PATH="$dir/%C"
      return 0
    fi
    rmdir "$dir" 2>/dev/null
  done

  # Degrade rather than break: without a mux every step asks for the password
  # again, which is annoying but works. A too-long ControlPath does not.
  printf '%s\n' "Note: no short enough ControlPath under 104 bytes; running without" >&2
  printf '%s\n' "connection multiplexing (expect a password prompt per step)." >&2
  return 0
}

_ssh_setup_mux_stop() {
  [ -n "${_SSH_SETUP_MUX_DIR:-}" ] || return 0
  local h
  for h in ${_SSH_SETUP_MUX_HOSTS}; do
    ssh -O exit -o "ControlPath=$_SSH_SETUP_MUX_PATH" "$h" >/dev/null 2>&1
  done
  rm -rf "$_SSH_SETUP_MUX_DIR"
  _SSH_SETUP_MUX_DIR=""
  _SSH_SETUP_MUX_PATH=""
}

# Populate $_SSH_HOP_OPTS for the hop currently split into $_SSH_HOP_DEST /
# $_SSH_HOP_PORT: the -p flag if there is one, plus the shared mux options.
_ssh_setup_hop_opts() {
  _SSH_HOP_OPTS=()
  [ -n "${_SSH_HOP_PORT:-}" ] && _SSH_HOP_OPTS+=(-p "$_SSH_HOP_PORT")
  if [ -n "${_SSH_SETUP_MUX_PATH:-}" ]; then
    _SSH_HOP_OPTS+=(-o ControlMaster=auto -o "ControlPath=$_SSH_SETUP_MUX_PATH" -o ControlPersist=120)
    case " $_SSH_SETUP_MUX_HOSTS " in
      *" $_SSH_HOP_DEST "*) ;;
      *) _SSH_SETUP_MUX_HOSTS="$_SSH_SETUP_MUX_HOSTS $_SSH_HOP_DEST" ;;
    esac
  fi
}

# ── Key discovery and repair ───────────────────────────────────────────────

# Is $1 an OpenSSH/PEM private key file?
_ssh_setup_is_private_key() {
  [ -f "$1" ] || return 1
  case "$(head -n 1 "$1" 2>/dev/null)" in
    *'-----BEGIN '*'PRIVATE KEY-----'*) return 0 ;;
  esac
  return 1
}

# List usable keys in ~/.ssh, one path per line, marking the ones whose public
# half is missing. The old listing globbed *.pub, so a private key with no .pub
# was invisible here AND still passed the (OR-semantics) existence check below,
# only to blow up inside ssh-copy-id. ~/.ssh also holds sockets, known_hosts and
# .DS_Store, so the private-key header is the only reliable filter.
_ssh_setup_list_keys() {
  if [ -n "$ZSH_VERSION" ]; then
    setopt localoptions nullglob
  else
    local _had_nullglob; _had_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob
  fi

  local f
  for f in "$HOME"/.ssh/*; do
    case "${f##*/}" in
      *.pub|config|known_hosts|known_hosts.old|authorized_keys|.DS_Store) continue ;;
    esac
    [ -d "$f" ] && continue
    _ssh_setup_is_private_key "$f" || continue
    if [ -f "${f}.pub" ]; then
      printf '%s\n' "$f"
    else
      printf '%s  (no .pub)\n' "$f"
    fi
  done

  if [ -n "$BASH_VERSION" ]; then
    eval "$_had_nullglob"
  fi
}

# Make sure ${1}.pub exists, regenerating it from the private key when it does
# not. The public half is always derivable -- `ssh-keygen -y` prompts for the
# passphrase if the key has one. Returns non-zero if there is still no .pub.
_ssh_setup_ensure_pubkey() {
  local key="$1"
  [ -f "${key}.pub" ] && return 0
  if [ ! -f "$key" ]; then
    printf '%s\n' "Key not found: $key" >&2
    return 1
  fi

  printf '\nNo public key next to %s.\n' "$key"
  if ! _ssh_setup_confirm 'Regenerate it with `ssh-keygen -y`?' yes; then
    printf '%s\n' "ssh-copy-id needs ${key}.pub — aborting." >&2
    return 1
  fi

  if ssh-keygen -y -f "$key" > "${key}.pub"; then
    chmod 644 "${key}.pub"
    printf 'Wrote %s.pub\n' "$key"
    return 0
  fi

  rm -f "${key}.pub"
  printf '%s\n' "ssh-keygen -y failed for $key" >&2
  return 1
}

# ── Windows remotes ────────────────────────────────────────────────────────
#
# Windows OpenSSH ships no ssh-copy-id, and for an account in the local
# Administrators group sshd's default `Match Group administrators` block reads
# ONLY C:\ProgramData\ssh\administrators_authorized_keys -- a key appended to
# ~/.ssh/authorized_keys is silently ignored there. So the far end gets a small
# PowerShell program instead, shipped as -EncodedCommand (base64 UTF-16LE) so
# that neither the local shell, ssh's own command concatenation, nor the remote
# DefaultShell (cmd or pwsh) can mangle the quoting.

# stdin: PowerShell source -> stdout: base64 UTF-16LE for -EncodedCommand.
_ssh_setup_ps_encode() {
  if command -v iconv >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,base64; sys.stdout.write(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())'
  else
    return 127
  fi
}

# Run a command, keeping its stderr instead of throwing it away: stdout is
# echoed (CR-stripped), stderr lands in $_SSH_SETUP_LAST_ERR, and the real exit
# status is returned. Every ssh in this wizard used to 2>/dev/null, which is
# how a hard transport failure (rc=255, e.g. `ControlPath too long`) came out
# looking like "the remote said nothing" -- see
# pitfalls/ssh-controlpath-too-long-macos-tmpdir.md.
#
# The stderr sink is a FILE keyed on $$, not a variable: callers use
# `out="$(_ssh_setup_capture ssh ...)"`, and a command substitution runs in a
# subshell, so any variable this set there would be discarded before the caller
# could read it. $$ stays the main shell's pid inside $( ) in both bash and zsh.
_ssh_setup_errfile() {
  printf '%s\n' "${TMPDIR:-/tmp}/sshsetup-err.$$"
}

# Start a fresh error record. Capture APPENDS, so a sequence of attempts
# (uname probe, then PowerShell probe, then the install) accumulates into one
# diagnosis instead of each attempt erasing the last one's reason.
_ssh_setup_err_reset() {
  local errf
  errf="$(_ssh_setup_errfile)"
  : >"$errf" 2>/dev/null || return 0
}

_ssh_setup_capture() {
  local errf out rc
  errf="$(_ssh_setup_errfile)"
  [ -e "$errf" ] || : >"$errf" 2>/dev/null || errf="/dev/null"
  out="$("$@" 2>>"$errf")"; rc=$?
  printf '%s\n' "${out//$'\r'/}"
  return "$rc"
}

# Print whatever the last captured command wrote to stderr, indented, if any.
_ssh_setup_show_err() {
  local errf
  errf="$(_ssh_setup_errfile)"
  [ -s "$errf" ] || return 0
  sed 's/^/    /' <"$errf" >&2
}

# First non-empty line of the last captured stderr, for one-line messages.
_ssh_setup_err_summary() {
  local errf
  errf="$(_ssh_setup_errfile)"
  [ -s "$errf" ] || return 0
  grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | head -n 1
}

_ssh_setup_err_cleanup() {
  local errf
  errf="$(_ssh_setup_errfile)"
  [ "$errf" = "/dev/null" ] || rm -f "$errf" 2>/dev/null
}

# stdin: PowerShell source. $1: destination, rest: ssh options.
# Returns the ssh exit status; stderr is kept in $_SSH_SETUP_LAST_ERR.
_ssh_setup_ps_run() {
  local dest="$1"; shift
  local enc
  enc="$(_ssh_setup_ps_encode)" || return 127
  # </dev/null: stdin is the (already drained) heredoc pipe; ssh must not try
  # to forward it to the remote.
  _ssh_setup_capture ssh "$@" "$dest" \
    "powershell -NoProfile -NonInteractive -EncodedCommand $enc" </dev/null
}

# Escape a value for embedding in a PowerShell single-quoted string.
_ssh_setup_ps_quote() {
  local v="$1"
  printf "%s" "${v//\'/\'\'}"
}

# What is at the far end? Echoes "posix", "windows admin=0", "windows admin=1",
# "unreachable", or "unknown". `uname -s` is the cheap probe; it fails on a
# pwsh/cmd DefaultShell, and only then do we pay for the PowerShell round trip.
# whoami /groups rather than IsInRole(): a non-elevated admin token carries the
# Administrators SID as deny-only, which IsInRole reports as false, while sshd
# still routes that session through the administrators_authorized_keys rule.
#
# "unreachable" (ssh exited 255 -- it never reached a remote shell) is kept
# distinct from "unknown" (we got a shell, it just did not identify itself).
# Conflating them is what produced the misleading "Is this a Windows machine?"
# question in front of a connection that was never going to work.
_ssh_setup_probe_kind() {
  local dest="$1"; shift
  local out rc
  _ssh_setup_err_reset
  out="$(_ssh_setup_capture ssh "$@" -o ConnectTimeout=15 "$dest" 'uname -s' </dev/null)"
  case "$out" in
    Linux*|Darwin*|*BSD*|SunOS*|AIX*|CYGWIN*|MINGW*|MSYS*) printf 'posix\n'; return 0 ;;
  esac

  # Deliberately NOT short-circuiting on rc 255 here: a Windows box can fail
  # `uname` that way too (it depends on the sshd DefaultShell), and calling
  # such a host unreachable is the very confusion this function exists to
  # avoid. Only give up once the PowerShell probe has also failed.
  out="$(_ssh_setup_ps_run "$dest" "$@" <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
$g = (whoami /groups | Out-String)
$a = if ($g -match 'S-1-5-32-544') { '1' } else { '0' }
Write-Output ("windows admin=" + $a + " user=" + $env:USERNAME)
PS
)"
  rc=$?
  case "$out" in
    *windows*) printf '%s\n' "$out"; return 0 ;;
  esac
  [ "$rc" -eq 255 ] && { printf 'unreachable\n'; return 0; }
  printf 'unknown\n'
}

# Append the public key to the right authorized_keys on a Windows remote.
# $1 public key line, $2 "1" to use administrators_authorized_keys.
_ssh_setup_ps_install_src() {
  local key tpl
  key="$(_ssh_setup_ps_quote "$1")"
  tpl="$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$key = '@@KEY@@'
if ('@@ADMIN@@' -eq '1') {
    $dir  = Join-Path $env:ProgramData 'ssh'
    $path = Join-Path $dir 'administrators_authorized_keys'
} else {
    $dir  = Join-Path $env:USERPROFILE '.ssh'
    $path = Join-Path $dir 'authorized_keys'
}
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }
$lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
if ($lines -notcontains $key) {
    Add-Content -LiteralPath $path -Value $key
    Write-Output "added:$path"
} else {
    Write-Output "present:$path"
}
if ('@@ADMIN@@' -eq '1') {
    # sshd refuses the file unless it is owned by Administrators/SYSTEM only.
    icacls $path /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    Write-Output "acl:$path"
}
PS
)"
  tpl="${tpl//@@KEY@@/$key}"
  tpl="${tpl//@@ADMIN@@/$2}"
  printf '%s\n' "$tpl"
}

# Lock down a key pair that was just scp'd to a Windows remote. $1 = basename.
_ssh_setup_ps_keyperm_src() {
  local tpl
  tpl="$(cat <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $env:USERPROFILE '.ssh'
$k   = Join-Path $dir '@@NAME@@'
if (Test-Path -LiteralPath $k) {
    icacls $k /inheritance:r /grant ("{0}:F" -f $env:USERNAME) | Out-Null
    Write-Output "perm:$k"
}
PS
)"
  printf '%s\n' "${tpl//@@NAME@@/$1}"
}

# Add the github.com IdentityFile block to a Windows remote's ~/.ssh/config.
_ssh_setup_ps_github_src() {
  local tpl
  tpl="$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$cfg = Join-Path $dir 'config'
if (-not (Test-Path -LiteralPath $cfg)) { New-Item -ItemType File -Path $cfg -Force | Out-Null }
if (-not (Select-String -LiteralPath $cfg -SimpleMatch 'Host github.com' -Quiet)) {
    Add-Content -LiteralPath $cfg -Value ""
    Add-Content -LiteralPath $cfg -Value "Host github.com"
    Add-Content -LiteralPath $cfg -Value "    IdentityFile ~/.ssh/@@NAME@@"
    Write-Output "github:added"
} else {
    Write-Output "github:present"
}
PS
)"
  printf '%s\n' "${tpl//@@NAME@@/$1}"
}

# Make sure ~/.ssh exists on a Windows remote before scp writes into it.
_ssh_setup_ps_mkssh_src() {
  cat <<'PS'
$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Write-Output "dir:$dir"
PS
}

# scp speaks -P for the port; everything else is the same as $_SSH_HOP_OPTS.
_ssh_setup_scp_opts() {
  _SSH_SCP_OPTS=()
  [ -n "${_SSH_HOP_PORT:-}" ] && _SSH_SCP_OPTS+=(-P "$_SSH_HOP_PORT")
  [ -n "${_SSH_SETUP_MUX_PATH:-}" ] && _SSH_SCP_OPTS+=(
    -o ControlMaster=auto -o "ControlPath=$_SSH_SETUP_MUX_PATH" -o ControlPersist=120
  )
}

# ── Step 0: pick or create the key (once per run, not once per hop) ────────
# Sets $_SSH_SETUP_KEY. $1 is only used to name a freshly created key.
_ssh_setup_pick_key() {
  local host_hint="$1"
  local key_path="" create_new=""

  if [ -n "${SSH_SETUP_KEY:-}" ]; then
    key_path="${SSH_SETUP_KEY/#\~/$HOME}"
    _ssh_setup_ensure_pubkey "$key_path" || return 1
    _SSH_SETUP_KEY="$key_path"
    return 0
  fi

  local listing
  listing="$(_ssh_setup_list_keys)"

  if [ -z "$listing" ]; then
    printf '\nNo usable keys in ~/.ssh/.\n'
    create_new="yes"
  else
    # The picker is a menu, not a "now type the full path" prompt: under gum
    # this is an arrow-key list, and the listing already flags keys whose
    # public half is missing so a repair is a deliberate choice.
    local -a menu
    menu=()
    local line first=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ -n "$first" ] || first="$line"   # bash/zsh disagree on array index 1
      menu+=("$line")
    done <<EOF
$listing
EOF
    local opt_new="+ create a new key"
    local opt_path="+ enter a path manually"
    menu+=("$opt_new" "$opt_path")

    _ssh_setup_choose 'Which SSH key?' "$first" "${menu[@]}"
    local picked="$_SSH_SETUP_REPLY"

    case "$picked" in
      "$opt_new")
        create_new="yes"
        ;;
      "$opt_path")
        _ssh_setup_input 'Key path (without .pub)' "$HOME/.ssh/"
        key_path="${_SSH_SETUP_REPLY/#\~/$HOME}"
        ;;
      *)
        # Strip the "  (no .pub)" annotation the listing adds. The paren is
        # escaped because zsh treats it as a pattern metacharacter here.
        key_path="${picked%%  \(*}"
        ;;
    esac

    if [ "$create_new" != "yes" ]; then
      if [ ! -f "$key_path" ] && [ ! -f "${key_path}.pub" ]; then
        printf '%s\n' "Key not found: $key_path" >&2
        return 1
      fi
    fi
  fi

  # ── Step 0b: create a new key ────────────────────────────────────────────
  if [ "$create_new" = "yes" ]; then
    printf '\n--- Create new SSH key ---\n'

    local algo="ed25519"
    _ssh_setup_choose 'Algorithm' 'ed25519' 'ed25519' 'ed25519-sk' 'rsa'
    [ -n "$_SSH_SETUP_REPLY" ] && algo="$_SSH_SETUP_REPLY"

    local key_name="id_${algo}_${host_hint}"
    _ssh_setup_input 'Key name' "$key_name"
    [ -n "$_SSH_SETUP_REPLY" ] && key_name="$_SSH_SETUP_REPLY"
    key_path="$HOME/.ssh/$key_name"

    if [ -f "$key_path" ]; then
      printf '%s\n' "Key already exists: $key_path" >&2
      return 1
    fi

    local comment="${USER}@$(hostname -s) -> ${host_hint}"
    _ssh_setup_input 'Comment' "$comment"
    [ -n "$_SSH_SETUP_REPLY" ] && comment="$_SSH_SETUP_REPLY"

    local -a passphrase_flag
    passphrase_flag=()
    if _ssh_setup_confirm 'Set a passphrase?' no; then
      # Let ssh-keygen prompt for it
      passphrase_flag=()
    else
      passphrase_flag=(-N "")
    fi

    local -a keygen_args
    keygen_args=(-t "$algo" -f "$key_path" -C "$comment" "${passphrase_flag[@]}")
    [ "$algo" = "rsa" ] && keygen_args+=(-b 4096)

    printf '\n> ssh-keygen %s\n' "${keygen_args[*]}"
    ssh-keygen "${keygen_args[@]}" || return 1
    printf '\nKey created: %s\n' "$key_path"
  fi

  # A key selected from disk may have lost its public half (agent-only import,
  # a partial copy from another machine). ssh-copy-id needs the .pub file, and
  # the old code only noticed at that point, with a confusing errno message.
  _ssh_setup_ensure_pubkey "$key_path" || return 1
  _SSH_SETUP_KEY="$key_path"
}

# ── Per-host worker ────────────────────────────────────────────────────────
# $1 hop spec ([user@]host[:port]), $2 key path, $3 role (jump|target).
#
# A jump host only needs steps 1 and 3: ProxyJump authenticates end-to-end from
# THIS machine, so the jump never handles the private key and copying it there
# would be a gratuitous secret spill.
# The wrapper exists so a failed step 1 can still run step 3 and STILL report
# failure: step 3 is full of `return 0` early exits, so the status has to
# travel in a variable rather than in the worker's exit code.
_ssh_setup_one() {
  _SSH_SETUP_STEP1_OK=1
  _ssh_setup_one_impl "$@" || return 1
  [ "$_SSH_SETUP_STEP1_OK" = "1" ]
}

_ssh_setup_one_impl() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  local hop="$1" key_path="$2" role="${3:-target}"

  _ssh_setup_split_hop "$hop"
  _ssh_setup_hop_opts
  local dest="$_SSH_HOP_DEST"

  local remote_user remote_host
  if [[ "$dest" == *@* ]]; then
    remote_user="${dest%%@*}"
    remote_host="${dest#*@}"
  else
    remote_host="$dest"
    remote_user=""
  fi

  # ── Step 1: install the public key ─────────────────────────────────────
  #
  # A failure here is recorded, not fatal. Step 2 is skipped (there is no point
  # pushing a key pair to a host we could not authenticate to) but step 3 still
  # runs: the local ~/.ssh/config edit is purely local, it is useful even when
  # the remote is unreachable, and silently skipping it was the most confusing
  # part of the original failure.
  printf '\n--- Copy public key to %s ---\n' "$hop"
  local step1_ok=1
  local kind="posix" admin="0"
  if _ssh_setup_confirm "Install the key for passwordless login?" yes; then
    printf 'Probing %s ...\n' "$dest"
    local probe
    probe="$(_ssh_setup_probe_kind "$dest" "${_SSH_HOP_OPTS[@]}")"
    case "$probe" in
      windows*)
        kind="windows"
        case "$probe" in *admin=1*) admin="1" ;; esac
        case "$probe" in *user=*) remote_user="${probe##*user=}" ;; esac
        ;;
      unreachable)
        # ssh never reached a remote shell. Say why instead of asking a
        # question the user has no way to answer usefully.
        printf '%s\n' "Cannot connect to $dest:" >&2
        _ssh_setup_show_err
        step1_ok=0
        ;;
      unknown)
        printf 'Connected, but could not identify the remote OS.\n'
        if _ssh_setup_confirm "Is $dest a Windows (OpenSSH sshd) machine?" no; then
          kind="windows"
        fi
        ;;
    esac

    if [ "$step1_ok" = "1" ] && [ "$kind" = "windows" ]; then
      local use_admin="0"
      if [ "$admin" = "1" ]; then
        printf '\n%s is in the remote Administrators group.\n' "${remote_user:-The remote account}"
        printf '%s\n' "sshd's default \`Match Group administrators\` rule reads ONLY"
        printf 'C:\\ProgramData\\ssh\\administrators_authorized_keys for such accounts —\n'
        printf 'a key in ~/.ssh/authorized_keys would be ignored. That file is shared\n'
        printf 'by every administrator on the box.\n'
        _ssh_setup_confirm "Use administrators_authorized_keys?" yes && use_admin="1"
      fi
      local pub_line
      pub_line="$(cat "${key_path}.pub")"
      printf '\n> ssh %s (PowerShell: append to %s)\n' "$dest" \
        "$([ "$use_admin" = "1" ] && printf 'administrators_authorized_keys' || printf '~/.ssh/authorized_keys')"
      local out ins_rc
      _ssh_setup_err_reset
      out="$(_ssh_setup_ps_install_src "$pub_line" "$use_admin" | _ssh_setup_ps_run "$dest" "${_SSH_HOP_OPTS[@]}")"
      ins_rc=$?
      # Decide on the exit status plus the markers the payload emits, not on
      # "was stdout empty" -- empty stdout is what a dead transport looks like.
      if [ "$ins_rc" -eq 0 ] && [[ "$out" == *added:* || "$out" == *present:* ]]; then
        printf '%s\n' "$out"
      else
        printf '%s\n' "Key install on $dest failed (ssh exit $ins_rc)." >&2
        _ssh_setup_show_err
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        step1_ok=0
      fi
    elif [ "$step1_ok" = "1" ]; then
      printf '\n> ssh-copy-id -i %s.pub %s\n' "$key_path" "$dest"
      ssh-copy-id "${_SSH_HOP_OPTS[@]}" -i "${key_path}.pub" "$dest" || {
        printf '%s\n' "ssh-copy-id failed. You may need to enter the remote password." >&2
        step1_ok=0
      }
    fi
  fi

  if [ "$step1_ok" != "1" ]; then
    _SSH_SETUP_STEP1_OK=0
    printf '\nCould not install the key on %s.\n' "$hop" >&2
    if ! _ssh_setup_confirm "Still update the LOCAL ~/.ssh/config for $hop?" yes; then
      return 1
    fi
    role="localonly"
  fi

  # ── Step 2: copy the key pair (final target only) ──────────────────────
  local do_scp=""
  if [ "$role" = "target" ]; then
    printf '\n--- Copy key pair to remote ---\n'
    printf 'This lets the remote machine use the same key (e.g. for GitHub).\n'
    if _ssh_setup_confirm "Copy private+public key to $dest:~/.ssh/?" no; then
      do_scp="yes"
      local key_basename="${key_path##*/}"
      _ssh_setup_scp_opts
      printf '\n> scp %s %s.pub %s:~/.ssh/\n' "$key_path" "$key_path" "$dest"
      if [ "$kind" = "windows" ]; then
        _ssh_setup_ps_mkssh_src | _ssh_setup_ps_run "$dest" "${_SSH_HOP_OPTS[@]}" >/dev/null
        scp "${_SSH_SCP_OPTS[@]}" "$key_path" "${key_path}.pub" "$dest:.ssh/" || return 1
        _ssh_setup_ps_keyperm_src "$key_basename" | _ssh_setup_ps_run "$dest" "${_SSH_HOP_OPTS[@]}"
      else
        scp "${_SSH_SCP_OPTS[@]}" "$key_path" "${key_path}.pub" "$dest:~/.ssh/" || return 1
        ssh "${_SSH_HOP_OPTS[@]}" "$dest" "chmod 600 ~/.ssh/$key_basename && chmod 644 ~/.ssh/${key_basename}.pub"
      fi
      printf 'Key copied and permissions set.\n'

      if _ssh_setup_confirm 'Add GitHub SSH config on remote?' no; then
        if [ "$kind" = "windows" ]; then
          _ssh_setup_ps_github_src "$key_basename" | _ssh_setup_ps_run "$dest" "${_SSH_HOP_OPTS[@]}"
        else
          # SC2087 on purpose: $key_basename must expand LOCALLY, before the
          # heredoc is fed to the remote shell.
          ssh "${_SSH_HOP_OPTS[@]}" "$dest" "mkdir -p ~/.ssh && cat >> ~/.ssh/config" <<EOF

Host github.com
    IdentityFile ~/.ssh/$key_basename
EOF
          ssh "${_SSH_HOP_OPTS[@]}" "$dest" "chmod 600 ~/.ssh/config"
        fi
        printf 'GitHub SSH config added on remote.\n'
      fi
    fi
  fi
  _SSH_SETUP_DID_SCP="$do_scp"

  # ── Step 3: local SSH config ───────────────────────────────────────────
  printf '\n--- Local SSH config ---\n'
  _SSH_SETUP_HOST_ALIAS=""
  if ! _ssh_setup_confirm 'Add/update host alias in local ~/.ssh/config?' yes; then
    return 0
  fi

  # Detect whether the target alias is ALREADY a configured Host, following
  # `Include` recursively into config.d/. rc 0 = found (edit in place);
  # rc 3 = not found; rc 127 = no python3 (fall back to append).
  local alias="$remote_host"
  local find_out find_rc
  find_out="$(_ssh_cfg_py find "$alias" "$key_path")"
  find_rc=$?

  if [ "$find_rc" -eq 0 ]; then
    # ── Mode B: alias already configured — add key to the existing block ──
    _SSH_SETUP_HOST_ALIAS="$alias"
    local kv block cfg_file="" has_idf=0 has_ido=0 key_present=0
    kv="${find_out%%---BLOCK---*}"
    block="${find_out#*---BLOCK---}"
    local _k _v
    while IFS='=' read -r _k _v; do
      case "$_k" in
        file)               cfg_file="$_v" ;;
        has_identityfile)   has_idf="$_v" ;;
        has_identitiesonly) has_ido="$_v" ;;
        key_present)        key_present="$_v" ;;
      esac
    done <<EOF
$kv
EOF

    printf '\nHost "%s" is already configured in %s:\n' "$alias" "$cfg_file"
    printf '%s\n' "$block"

    if [ "$key_present" = "1" ]; then
      printf '\nThis key (%s) is already set for %s — nothing to do.\n' "$key_path" "$alias"
      return 0
    fi

    local action="insert"
    if [ "$has_idf" = "1" ]; then
      _ssh_setup_choose 'This host already has an IdentityFile.' \
        'replace' 'replace' 'add another' 'skip'
      case "$_SSH_SETUP_REPLY" in
        add*)  action="add" ;;
        skip*) action="" ;;
        *)     action="replace" ;;
      esac
    fi

    [ -n "$action" ] || return 0

    local ido_flag=""
    if [ "$has_ido" != "1" ]; then
      _ssh_setup_confirm 'Also add `IdentitiesOnly yes` so only this key is offered?' no \
        && ido_flag="--identities-only"
    fi
    if _ssh_cfg_py insert "$cfg_file" "$alias" "$key_path" "$action" $ido_flag; then
      printf 'Updated %s.\n' "$cfg_file"
      if ssh -G "$alias" >/dev/null 2>&1; then
        printf 'Config parses OK (ssh -G %s).\n' "$alias"
      else
        printf 'Warning: `ssh -G %s` reported a problem — please review %s.\n' "$alias" "$cfg_file" >&2
      fi
    else
      printf 'Failed to update %s.\n' "$cfg_file" >&2
    fi
    return 0
  fi

  # ── Mode A: new host (not found, or no python3) — append a fresh block ──
  local host_alias="$remote_host"
  _ssh_setup_input 'Host alias' "$host_alias"
  [ -n "$_SSH_SETUP_REPLY" ] && host_alias="$_SSH_SETUP_REPLY"
  _SSH_SETUP_HOST_ALIAS="$host_alias"

  local hostname="$remote_host"
  _ssh_setup_input 'HostName (IP or FQDN)' "$hostname"
  [ -n "$_SSH_SETUP_REPLY" ] && hostname="$_SSH_SETUP_REPLY"

  local config_user="${remote_user:-$USER}"
  _ssh_setup_input 'User' "$config_user"
  [ -n "$_SSH_SETUP_REPLY" ] && config_user="$_SSH_SETUP_REPLY"

  local identonly_line=""
  _ssh_setup_confirm 'Add IdentitiesOnly yes?' no \
    && identonly_line=$'\n    IdentitiesOnly yes'

  local port_line=""
  [ -n "${_SSH_HOP_PORT:-}" ] && port_line=$'\n    Port '"$_SSH_HOP_PORT"

  # Determine config file (prefer a config.d/ drop-in if that dir exists)
  local config_file="$HOME/.ssh/config"
  local wrote_configd=0
  if [ -d "$HOME/.ssh/config.d" ]; then
    if _ssh_setup_confirm 'Write to ~/.ssh/config.d/ instead of ~/.ssh/config?' yes; then
      config_file="$HOME/.ssh/config.d/host_${host_alias}"
      _ssh_setup_input 'Config file' "$config_file"
      [ -n "$_SSH_SETUP_REPLY" ] && config_file="$_SSH_SETUP_REPLY"
      wrote_configd=1
    fi
  fi

  local config_block="
Host $host_alias
    HostName $hostname
    User $config_user${port_line}
    IdentityFile $key_path${identonly_line}"

  printf '\nWill append to %s:\n' "$config_file"
  printf '%s\n' "$config_block"
  if ! _ssh_setup_confirm 'Confirm?' yes; then
    return 0
  fi

  printf '%s\n' "$config_block" >> "$config_file"
  chmod 600 "$config_file"
  printf 'Config written.\n'

  # If we wrote into config.d/ but the entry-point config never Includes it,
  # the drop-in silently won't load. Offer to wire it up.
  if [ "$wrote_configd" = "1" ] && command -v python3 >/dev/null 2>&1; then
    if ! _ssh_cfg_py ensure-include; then
      printf '\nNote: ~/.ssh/config has no `Include` for config.d/* — this entry will not load.\n'
      if _ssh_setup_confirm 'Add `Include ~/.ssh/config.d/*` to ~/.ssh/config now?' yes; then
        _ssh_cfg_py add-include && printf 'Include directive added.\n'
      fi
    fi
  fi
}

# ── Public entry point ─────────────────────────────────────────────────────
#
# Signature is load-bearing: `tsnet --setup-remote` execvp's
#   bash -c 'source ~/.config/shell/96_ssh_setup.sh; ssh-setup-remote "$1"'
# with exactly one alias, so keep it to one positional argument and keep the
# file sourceable with no rc files loaded.
ssh-setup-remote() {
  if [ -n "$ZSH_VERSION" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  local usage="Usage: ssh-setup-remote [user@]host"
  if [ $# -ne 1 ]; then
    printf '%s\n' "$usage" >&2
    return 1
  fi

  local target="$1"
  local host_hint="${target#*@}"
  host_hint="${host_hint%%:*}"

  printf '\n%s\n' "=== SSH Key Setup for $target ==="

  # The jump chain is resolved BEFORE anything else so the run can be described
  # up front — the old behaviour silently set up the last hop only.
  local chain
  chain="$(_ssh_setup_chain "$target")"

  local -a hosts
  hosts=()
  local h
  while IFS= read -r h; do
    [ -n "$h" ] && hosts+=("$h")
  done <<EOF
$chain
EOF
  hosts+=("$target")

  local total="${#hosts[@]}"
  if [ "$total" -gt 1 ]; then
    printf '\nProxyJump chain detected: %s\n' "$(printf '%s -> ' "${hosts[@]}" | sed 's/ -> $//')"
    printf 'Each hop needs its own key on its own authorized_keys — ProxyJump only\n'
    printf 'forwards TCP, so the jump host never sees your private key.\n'
  fi

  _ssh_setup_pick_key "$host_hint" || return 1
  local key_path="$_SSH_SETUP_KEY"

  _ssh_setup_mux_start

  local i=0 rc=0 role
  local last_alias="" did_scp=""
  for h in "${hosts[@]}"; do
    i=$((i + 1))
    if [ "$i" -eq "$total" ]; then role="target"; else role="jump"; fi

    if [ "$total" -gt 1 ]; then
      printf '\n========================================\n'
      printf '[%d/%d] %s (%s)\n' "$i" "$total" "$h" "$role"
      printf '========================================\n'
    fi

    # Skip hops that already work without a password. BatchMode makes this a
    # non-blocking probe: it fails immediately rather than prompting.
    #
    # The question is "did ssh AUTHENTICATE", not "did the remote command
    # succeed": ssh reserves 255 for its own failures (auth, DNS, refused) and
    # passes anything else through from the remote. `true` is not a cmd.exe
    # builtin, so a working Windows hop answers 1 -- treating that as failure
    # meant a Windows jump host could never be recognised as already set up.
    _ssh_setup_split_hop "$h"
    _ssh_setup_hop_opts
    ssh "${_SSH_HOP_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 \
      "$_SSH_HOP_DEST" true >/dev/null 2>&1
    if [ "$?" -ne 255 ]; then
      printf '%s already accepts key-based login.\n' "$h"
      if ! _ssh_setup_confirm 'Set it up anyway?' no; then
        printf 'Skipped.\n'
        continue
      fi
    fi

    _ssh_setup_one "$h" "$key_path" "$role" || rc=1

    # Capture the alias/scp answers even on failure: step 3 may well have run
    # and written the local config, and the closing hint should reflect that.
    if [ "$role" = "target" ]; then
      last_alias="$_SSH_SETUP_HOST_ALIAS"
      did_scp="$_SSH_SETUP_DID_SCP"
    fi

    if [ "$rc" = "1" ] && [ "${_SSH_SETUP_STEP1_OK:-1}" != "1" ]; then
      printf '\n%s\n' "Key install for $h did not succeed." >&2
      if [ "$role" = "jump" ]; then
        _ssh_setup_confirm 'Continue with the rest of the chain?' no || break
      fi
    fi
  done

  _ssh_setup_mux_stop
  _ssh_setup_err_cleanup

  if [ "$rc" = "0" ]; then
    printf '\n=== Done! ===\n'
  else
    printf '\n=== Done, with errors ===\n'
  fi
  printf 'Test with: ssh %s\n' "${last_alias:-$target}"
  if [[ "$did_scp" =~ ^[Yy] ]]; then
    printf "Test GitHub: ssh %s 'ssh -T git@github.com'\n" "${last_alias:-$target}"
  fi
  return "$rc"
}
