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
#
# Walks through: create key → ssh-copy-id → copy key to remote → add SSH config entries.
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
  local remote_user remote_host
  if [[ "$target" == *@* ]]; then
    remote_user="${target%%@*}"
    remote_host="${target#*@}"
  else
    remote_host="$target"
    remote_user=""
  fi

  # ── Step 0: Key selection ──────────────────────────────────────────────
  printf '\n%s\n' "=== SSH Key Setup for $target ==="

  local key_path=""
  local create_new=""

  printf '\nExisting keys in ~/.ssh/:\n'

  # Portable nullglob: in zsh, `*.pub(N)` made the glob expand to nothing
  # when nothing matched. shopt -s nullglob (bash) / setopt nullglob (zsh)
  # is the equivalent.
  local -a existing_keys
  existing_keys=()
  if [ -n "$ZSH_VERSION" ]; then
    setopt localoptions nullglob
  else
    local _had_nullglob; _had_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob
  fi

  local f
  for f in ~/.ssh/*.pub; do
    existing_keys+=("${f%.pub}")
    printf '  %s\n' "${f%.pub}"
  done

  # Restore bash nullglob; zsh is already locally scoped via setopt localoptions.
  if [ -n "$BASH_VERSION" ]; then
    eval "$_had_nullglob"
  fi

  if (( ${#existing_keys[@]} > 0 )); then
    printf '\nUse an existing key? [Y/n] '
    read -r create_new
    if [[ "$create_new" =~ ^[Nn] ]]; then
      create_new="yes"
    else
      printf 'Enter key path (without .pub): '
      read -r key_path
      # Expand ~ manually
      key_path="${key_path/#\~/$HOME}"
      if [ ! -f "$key_path" ] && [ ! -f "${key_path}.pub" ]; then
        printf '%s\n' "Key not found: $key_path" >&2
        return 1
      fi
    fi
  else
    printf '  (none found)\n'
    create_new="yes"
  fi

  # ── Step 0b: Create new key ────────────────────────────────────────────
  if [ "$create_new" = "yes" ]; then
    printf '\n--- Create new SSH key ---\n'

    # Algorithm
    local algo="ed25519"
    printf 'Algorithm [ed25519] (ed25519/ed25519-sk/rsa): '
    local algo_input
    read -r algo_input
    [ -n "$algo_input" ] && algo="$algo_input"

    # Key name
    local key_name="id_${algo}_${remote_host}"
    printf 'Key name [%s]: ' "$key_name"
    local name_input
    read -r name_input
    [ -n "$name_input" ] && key_name="$name_input"
    key_path="$HOME/.ssh/$key_name"

    if [ -f "$key_path" ]; then
      printf '%s\n' "Key already exists: $key_path" >&2
      return 1
    fi

    # Comment
    local comment="${USER}@$(hostname -s) -> ${remote_host}"
    printf 'Comment [%s]: ' "$comment"
    local comment_input
    read -r comment_input
    [ -n "$comment_input" ] && comment="$comment_input"

    # Passphrase
    local -a passphrase_flag
    passphrase_flag=()
    printf 'Set a passphrase? [y/N] '
    local use_pass
    read -r use_pass
    if [[ "$use_pass" =~ ^[Yy] ]]; then
      # Let ssh-keygen prompt for it
      passphrase_flag=()
    else
      passphrase_flag=(-N "")
    fi

    # Generate
    local -a keygen_args
    keygen_args=(-t "$algo" -f "$key_path" -C "$comment" "${passphrase_flag[@]}")
    [ "$algo" = "rsa" ] && keygen_args+=(-b 4096)

    printf '\n> ssh-keygen %s\n' "${keygen_args[*]}"
    ssh-keygen "${keygen_args[@]}" || return 1
    printf '\nKey created: %s\n' "$key_path"
  fi

  # ── Step 1: ssh-copy-id ────────────────────────────────────────────────
  printf '\n--- Copy public key to %s ---\n' "$target"
  printf 'Run ssh-copy-id to enable passwordless login? [Y/n] '
  local do_copy
  read -r do_copy
  if [[ ! "$do_copy" =~ ^[Nn] ]]; then
    printf '\n> ssh-copy-id -i %s.pub %s\n' "$key_path" "$target"
    ssh-copy-id -i "${key_path}.pub" "$target" || {
      printf '%s\n' "ssh-copy-id failed. You may need to enter the remote password." >&2
      return 1
    }
  fi

  # ── Step 2: Copy key pair to remote ────────────────────────────────────
  printf '\n--- Copy key pair to remote ---\n'
  printf 'This lets the remote machine use the same key (e.g. for GitHub).\n'
  printf 'Copy private+public key to %s:~/.ssh/? [y/N] ' "$target"
  local do_scp
  read -r do_scp
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    local key_basename="${key_path##*/}"
    printf '\n> scp %s %s.pub %s:~/.ssh/\n' "$key_path" "$key_path" "$target"
    scp "$key_path" "${key_path}.pub" "$target:~/.ssh/" || return 1
    ssh "$target" "chmod 600 ~/.ssh/$key_basename && chmod 644 ~/.ssh/${key_basename}.pub"
    printf 'Key copied and permissions set.\n'

    # Configure GitHub on remote
    printf '\nAdd GitHub SSH config on remote? [y/N] '
    local do_github
    read -r do_github
    if [[ "$do_github" =~ ^[Yy] ]]; then
      ssh "$target" "mkdir -p ~/.ssh && cat >> ~/.ssh/config" <<EOF

Host github.com
    IdentityFile ~/.ssh/$key_basename
EOF
      ssh "$target" "chmod 600 ~/.ssh/config"
      printf 'GitHub SSH config added on remote.\n'
    fi
  fi

  # ── Step 3: Local SSH config ───────────────────────────────────────────
  printf '\n--- Local SSH config ---\n'
  local host_alias=""
  printf 'Add/update host alias in local ~/.ssh/config? [Y/n] '
  local do_config
  read -r do_config
  if [[ ! "$do_config" =~ ^[Nn] ]]; then
    # Detect whether the target alias is ALREADY a configured Host, following
    # `Include` recursively into config.d/. rc 0 = found (edit in place);
    # rc 3 = not found; rc 127 = no python3 (fall back to append).
    local alias="$remote_host"
    local find_out find_rc
    find_out="$(_ssh_cfg_py find "$alias" "$key_path")"
    find_rc=$?

    if [ "$find_rc" -eq 0 ]; then
      # ── Mode B: alias already configured — add key to the existing block ──
      host_alias="$alias"
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
      else
        local action="insert"
        if [ "$has_idf" = "1" ]; then
          printf '\nThis host already has an IdentityFile. [r]eplace / [a]dd another / [s]kip? [r] '
          local idf_choice
          read -r idf_choice
          case "$idf_choice" in
            [Aa]*) action="add" ;;
            [Ss]*) action="" ;;
            *)     action="replace" ;;
          esac
        fi

        if [ -n "$action" ]; then
          local ido_flag=""
          if [ "$has_ido" != "1" ]; then
            printf 'Also add `IdentitiesOnly yes` so only this key is offered? [y/N] '
            local do_ido
            read -r do_ido
            [[ "$do_ido" =~ ^[Yy] ]] && ido_flag="--identities-only"
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
        fi
      fi
    else
      # ── Mode A: new host (not found, or no python3) — append a fresh block ──
      host_alias="$remote_host"
      printf 'Host alias [%s]: ' "$host_alias"
      local alias_input
      read -r alias_input
      [ -n "$alias_input" ] && host_alias="$alias_input"

      local hostname="$remote_host"
      printf 'HostName (IP or FQDN) [%s]: ' "$hostname"
      local hostname_input
      read -r hostname_input
      [ -n "$hostname_input" ] && hostname="$hostname_input"

      local config_user="${remote_user:-$USER}"
      printf 'User [%s]: ' "$config_user"
      local user_input
      read -r user_input
      [ -n "$user_input" ] && config_user="$user_input"

      printf 'Add IdentitiesOnly yes? [y/N] '
      local do_identonly
      read -r do_identonly
      local identonly_line=""
      [[ "$do_identonly" =~ ^[Yy] ]] && identonly_line=$'\n    IdentitiesOnly yes'

      # Determine config file (prefer a config.d/ drop-in if that dir exists)
      local config_file="$HOME/.ssh/config"
      local wrote_configd=0
      if [ -d "$HOME/.ssh/config.d" ]; then
        printf 'Write to ~/.ssh/config.d/ instead of ~/.ssh/config? [Y/n] '
        local use_configd
        read -r use_configd
        if [[ ! "$use_configd" =~ ^[Nn] ]]; then
          config_file="$HOME/.ssh/config.d/host_${host_alias}"
          printf 'Config file [%s]: ' "$config_file"
          local cf_input
          read -r cf_input
          [ -n "$cf_input" ] && config_file="$cf_input"
          wrote_configd=1
        fi
      fi

      local config_block="
Host $host_alias
    HostName $hostname
    User $config_user
    IdentityFile $key_path${identonly_line}"

      printf '\nWill append to %s:\n' "$config_file"
      printf '%s\n' "$config_block"
      printf '\nConfirm? [Y/n] '
      local confirm
      read -r confirm
      if [[ ! "$confirm" =~ ^[Nn] ]]; then
        printf '%s\n' "$config_block" >> "$config_file"
        chmod 600 "$config_file"
        printf 'Config written.\n'

        # If we wrote into config.d/ but the entry-point config never Includes
        # it, the drop-in silently won't load. Offer to wire it up.
        if [ "$wrote_configd" = "1" ] && command -v python3 >/dev/null 2>&1; then
          if ! _ssh_cfg_py ensure-include; then
            printf '\nNote: ~/.ssh/config has no `Include` for config.d/* — this entry will not load.\n'
            printf 'Add `Include ~/.ssh/config.d/*` to ~/.ssh/config now? [Y/n] '
            local do_inc
            read -r do_inc
            if [[ ! "$do_inc" =~ ^[Nn] ]]; then
              _ssh_cfg_py add-include && printf 'Include directive added.\n'
            fi
          fi
        fi
      fi
    fi
  fi

  # ── Done ───────────────────────────────────────────────────────────────
  printf '\n=== Done! ===\n'
  printf 'Test with: ssh %s\n' "${host_alias:-$target}"
  if [[ "$do_scp" =~ ^[Yy] ]]; then
    printf "Test GitHub: ssh %s 'ssh -T git@github.com'\n" "${host_alias:-$target}"
  fi
}
